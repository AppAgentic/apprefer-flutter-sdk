import 'dart:async';
import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_api_client.dart';
import 'package:apprefer/src/billing/billing_engine.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/in_app_purchase_store.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:apprefer/src/services/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const purchases = '/api/billing/v1/purchases';
const identify = '/api/billing/v1/identify';
const otherToken = '99999999-2222-4333-8444-555555555555';

/// Customers answer 200; /purchases answers [purchaseStatus].
void purchasesFail(Harness h, int purchaseStatus) {
  h.server.handler = (r) {
    if (r.url.path == purchases) return (purchaseStatus, {'error': 'nope'});
    final user = r.method == 'GET'
        ? r.url.queryParameters['appUserId']!
        : (jsonDecode(r.body) as Map)['appUserId'] as String;
    return (200, customerJson(user));
  };
}

void main() {
  group('verified store purchases always reach the answer', () {
    test('no account token: merged even when nothing is queued', () async {
      final h = await Harness.create(server: FakeServer()..online());
      h.store.entitlements = [activeSub('pro_yearly')];
      final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.queue.isEmpty, isTrue);
      expect(info.source, CustomerInfoSource.server);
      expect(info.entitlements['premium']?.isActive, isTrue);
    });

    test('own token merged, another user\'s token left out', () async {
      final h = await Harness.create(server: FakeServer()..online());
      h.store.entitlements = [activeSub('pro_yearly', accountToken: token)];
      final mine = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(mine.entitlements['premium']?.isActive, isTrue);

      h.store.entitlements = [
        activeSub('pro_yearly', accountToken: otherToken),
      ];
      final other = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(other.source, CustomerInfoSource.server);
      expect(other.entitlements['premium'], isNull);
    });

    test('another token still counts while queued for this user', () async {
      final h = await Harness.create();
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      h.server.online();
      purchasesFail(h, 503);
      h.store.entitlements = [
        activeSub('pro_yearly', accountToken: otherToken, transactionId: 't1'),
      ];
      final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.queue.entries, hasLength(1));
      expect(info.entitlements['premium']?.isActive, isTrue);
    });

    test('a permanently rejected upload does not lock the payer out', () async {
      final h = await Harness.create(server: FakeServer()..status(400));
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.queue.isEmpty, isTrue);
      h.server.online();
      h.store.entitlements = [activeSub('pro_yearly')];
      final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(info.source, CustomerInfoSource.server);
      expect(info.entitlements['premium']?.isActive, isTrue);
    });

    test(
      'total outage unlocks every verified purchase on the device',
      () async {
        final h = await Harness.create();
        h.store.entitlements = [
          activeSub('pro_yearly', accountToken: otherToken),
        ];
        final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
        expect(info.source, CustomerInfoSource.localFallback);
        expect(info.entitlements['premium']?.isActive, isTrue);
      },
    );
  });

  group('retry queue back-off', () {
    for (final status in [401, 403, 404, 409, 429]) {
      test('$status pauses without counting an attempt', () async {
        final h = await Harness.create(server: FakeServer()..status(status));
        await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        expect(h.queue.entries.single.attempts, 0);
        expect(h.store.completed, ['t1'], reason: 'queued on disk, finished');

        h.server.requests.clear();
        await h.engine.drainQueue();
        expect(h.server.bodiesFor(purchases), isEmpty, reason: 'paused');
        expect(h.queue.entries.single.attempts, 0);
      });
    }

    test('backs off 30 s doubling to 1 h, then delivers', () async {
      final h = await Harness.create(server: FakeServer()..status(429));
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      h.server.requests.clear();

      h.time = now.add(const Duration(seconds: 29));
      await h.engine.drainQueue();
      expect(h.server.requests, isEmpty);

      h.time = now.add(const Duration(seconds: 30));
      await h.engine.drainQueue();
      expect(h.server.bodiesFor(purchases), hasLength(1));

      // Second failure: 60 s from now.
      h.server.requests.clear();
      final second = h.time;
      h.time = second.add(const Duration(seconds: 59));
      await h.engine.drainQueue();
      expect(h.server.requests, isEmpty);
      h.server.online();
      h.time = second.add(const Duration(seconds: 60));
      await h.engine.drainQueue();
      expect(h.queue.isEmpty, isTrue);
      expect(h.queue.entries, isEmpty);
    });

    test('caps the back-off at one hour', () async {
      final h = await Harness.create(server: FakeServer()..status(401));
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      for (var i = 0; i < 10; i++) {
        h.time = h.time.add(const Duration(hours: 1));
        await h.engine.drainQueue();
      }
      h.server.requests.clear();
      h.time = h.time.add(const Duration(minutes: 59));
      await h.engine.drainQueue();
      expect(h.server.requests, isEmpty);
      h.time = h.time.add(const Duration(minutes: 1));
      await h.engine.drainQueue();
      expect(h.server.bodiesFor(purchases), hasLength(1));
    });

    test('honours Retry-After', () async {
      final h = await Harness.create(server: FakeServer()..status(429));
      h.server.responseHeaders = {'retry-after': '120'};
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      h.server.requests.clear();
      h.time = now.add(const Duration(seconds: 119));
      await h.engine.drainQueue();
      expect(h.server.requests, isEmpty);
      h.time = now.add(const Duration(seconds: 120));
      await h.engine.drainQueue();
      expect(h.server.bodiesFor(purchases), hasLength(1));
    });

    for (final status in [400, 413, 422]) {
      test('$status is final for a queued purchase', () async {
        final h = await Harness.create();
        await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        h.server.status(status);
        await h.engine.drainQueue();
        expect(h.queue.isEmpty, isTrue);
      });
    }

    test('other errors retry and count an attempt', () async {
      final h = await Harness.create();
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      h.server.status(500);
      await h.engine.drainQueue();
      expect(h.queue.entries.single.attempts, 2);
    });
  });

  group('503: verified but not recorded', () {
    test(
      'Google consumable stays queued, is acknowledged, never consumed',
      () async {
        final h = await Harness.create();
        h.store.store = BillingStore.playStore;
        purchasesFail(h, 503);
        h.server.responseHeaders = {'retry-after': '30'};
        final coins = h.store.googlePurchase(
          'tok_1',
          'coins',
          kind: StoreProductKind.consumable,
        );
        await h.engine.process(coins);
        expect(h.queue.entries.single.transactionId, 'tok_1');
        expect(h.store.acknowledged, ['tok_1']);
        expect(h.store.completed, isEmpty, reason: 'not consumed');

        // Foreground while still queued: secured again, still not consumed.
        h.store.unfinishedList = [
          h.store.googlePurchase(
            'tok_1',
            'coins',
            kind: StoreProductKind.consumable,
            isAcknowledged: true,
          ),
        ];
        await h.engine.retryUnfinished();
        expect(h.store.completed, isEmpty);

        // Recorded later: consumed then, without sending it again.
        h.server.requests.clear();
        h.server.online();
        h.time = now.add(const Duration(seconds: 30));
        await h.engine.drainQueue();
        expect(h.queue.isEmpty, isTrue);
        expect(h.store.completed, ['tok_1']);
        expect(h.server.bodiesFor(purchases), hasLength(1));
      },
    );

    test('Apple purchase stays queued until recorded', () async {
      final h = await Harness.create();
      purchasesFail(h, 503);
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.queue.entries, hasLength(1));
      h.server.online();
      await h.engine.drainQueue();
      expect(h.queue.isEmpty, isTrue);
    });
  });

  group('Google acknowledgement', () {
    test('acknowledged on device at once when the upload fails', () async {
      final h = await Harness.create();
      h.store.store = BillingStore.playStore;
      await h.engine.process(h.store.googlePurchase('tok_1', 'pro_yearly'));
      expect(h.queue.entries, hasLength(1));
      expect(h.store.acknowledged, ['tok_1']);
    });

    test('not acknowledged until the queue entry is saved', () async {
      late FlakyPrefs flaky;
      final h = await Harness.create(wrapPrefs: (p) => flaky = FlakyPrefs(p));
      h.store.store = BillingStore.playStore;
      h.engine.currentAppUserId; // identity saved before writes fail
      expect(await h.storage.flush(), isTrue);
      flaky.failWrites = true;
      await h.engine.process(h.store.googlePurchase('tok_1', 'pro_yearly'));
      expect(h.store.acknowledged, isEmpty);

      flaky.failWrites = false;
      h.store.unfinishedList = [h.store.googlePurchase('tok_1', 'pro_yearly')];
      await h.engine.retryUnfinished();
      expect(h.store.acknowledged, ['tok_1']);
      expect(h.queue.isDurable('tok_1'), isTrue);
    });

    test('a failed acknowledge is retried on foreground', () async {
      final h = await Harness.create(server: FakeServer()..online());
      h.store.store = BillingStore.playStore;
      h.store.failNextCompletion.add('tok_1');
      await h.engine.process(h.store.googlePurchase('tok_1', 'pro_yearly'));
      expect(h.store.completed, isEmpty);

      h.store.unfinishedList = [h.store.googlePurchase('tok_1', 'pro_yearly')];
      await h.engine.resume();
      expect(h.store.completed, ['tok_1']);
    });

    test('a failed consume is retried on foreground', () async {
      final h = await Harness.create(server: FakeServer()..online());
      h.store.store = BillingStore.playStore;
      h.store.failNextCompletion.add('tok_1');
      final coins = h.store.googlePurchase(
        'tok_1',
        'coins',
        kind: StoreProductKind.consumable,
      );
      await h.engine.process(coins);
      expect(h.store.completed, isEmpty);
      h.store.unfinishedList = [coins];
      await h.engine.resume();
      expect(h.store.completed, ['tok_1']);
    });
  });

  group('restore flag', () {
    test(
      'only restorePurchases sends restore: true (a JSON boolean)',
      () async {
        final h = await Harness.create(server: FakeServer()..online());
        await h.engine.process(h.store.applePurchase('p1', 'pro_yearly'));
        h.store.restoreList = [
          h.store.applePurchase(
            'r1',
            'pro_yearly',
            status: StorePurchaseStatus.restored,
          ),
        ];
        await h.engine.restore();
        final bodies = h.server.bodiesFor(purchases);
        expect(bodies.first.containsKey('restore'), isFalse);
        expect(bodies.last['restore'], isTrue);
        expect(bodies.last['restore'], isA<bool>());
      },
    );

    test('purchase() and store updates never send it', () async {
      final h = await Harness.create(server: FakeServer()..online());
      h.engine.listen();
      h.store.onBuy = (product, _) =>
          h.store.updates.add([h.store.applePurchase('t9', product.id)]);
      await h.engine.purchase(
        FakeProduct('pro_yearly'),
        const StorePurchaseOptions(),
      );
      h.store.updates.add([h.store.applePurchase('renewal', 'pro_yearly')]);
      await pumpEventQueue();
      final bodies = h.server.bodiesFor(purchases);
      expect(bodies, hasLength(2));
      expect(bodies.every((b) => !b.containsKey('restore')), isTrue);
    });

    test('a queued restore is retried as a restore', () async {
      final h = await Harness.create();
      h.store.restoreList = [
        h.store.applePurchase(
          'r1',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
        ),
        h.store.applePurchase('r2', 'x', status: StorePurchaseStatus.restored),
      ];
      await h.engine.restore();
      expect(h.queue.entries.every((e) => e.restore), isTrue);
      // Survives a relaunch.
      final reloaded = PendingPurchaseQueue(
        h.prefs,
        BillingStorage.pendingPurchasesKey,
      );
      expect(reloaded.entries.every((e) => e.restore), isTrue);

      h.server.requests.clear();
      h.server.online();
      await h.engine.drainQueue();
      final bodies = h.server.bodiesFor(purchases);
      expect(bodies, hasLength(2));
      expect(bodies.every((b) => b['restore'] == true), isTrue);
    });

    test('a later normal upload does not clear a queued restore', () async {
      final h = await Harness.create();
      h.store.restoreList = [
        h.store.applePurchase(
          'r1',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
        ),
      ];
      await h.engine.restore();
      await h.engine.process(h.store.applePurchase('r1', 'pro_yearly'));
      expect(h.queue.entries.single.restore, isTrue);
    });
  });

  group('purchases bound to the user who made them', () {
    test('logIn during the purchase sheet does not move it', () async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        appUserId: 'u1',
      );
      h.engine.listen();
      final result = h.engine.purchase(
        FakeProduct('pro_yearly'),
        const StorePurchaseOptions(),
      );
      await pumpEventQueue();
      expect(h.store.bought, hasLength(1));
      await h.engine.logIn('u2');
      h.store.updates.add([h.store.applePurchase('t1', 'pro_yearly')]);
      await result;
      expect(h.server.bodiesFor(purchases).single['appUserId'], 'u1');
    });

    test(
      'a renewal tagged with an earlier user\'s token goes to them',
      () async {
        final h = await Harness.create(
          server: FakeServer()..online(),
          appUserId: 'u2',
        );
        h.storage.setAccountToken(otherToken, 'u1');
        await h.engine.process(
          h.store.applePurchase('t1', 'pro_yearly', accountToken: otherToken),
        );
        expect(h.server.bodiesFor(purchases).single['appUserId'], 'u1');
      },
    );

    test('an untagged update goes to the current user', () async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        appUserId: 'u2',
      );
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.server.bodiesFor(purchases).single['appUserId'], 'u2');
    });
  });

  group('pending identifies', () {
    test('survive logOut and are sent in order', () async {
      final h = await Harness.create();
      final anon1 = h.engine.currentAppUserId;
      await h.engine.logIn('u1');
      await h.engine.logOut();
      final anon2 = h.engine.currentAppUserId;
      await h.engine.logIn('u2');
      expect(h.storage.pendingIdentifies, [
        (anonymousId: anon1, appUserId: 'u1'),
        (anonymousId: anon2, appUserId: 'u2'),
      ]);

      h.server.requests.clear();
      h.server.online();
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.server.bodiesFor(identify), [
        {'anonymousId': anon1, 'appUserId': 'u1'},
        {'anonymousId': anon2, 'appUserId': 'u2'},
      ]);
      expect(h.storage.pendingIdentifies, isEmpty);
    });

    test('stop at the first one to retry, keeping order', () async {
      final h = await Harness.create();
      await h.engine.logIn('u1');
      await h.engine.logOut();
      await h.engine.logIn('u2');
      h.server.requests.clear();
      h.server.status(500);
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      // One identify (tried on both hosts), never the second.
      expect(h.server.bodiesFor(identify).map((b) => b['appUserId']).toSet(), {
        'u1',
      });
      expect(h.storage.pendingIdentifies.map((e) => e.appUserId), ['u1', 'u2']);
    });

    test('completion clears only the entry that was sent', () async {
      final h = await Harness.create();
      await h.engine.logIn('u1');
      final server = h.server;
      server.handler = (r) {
        if (r.url.path == identify) {
          // A newer login queued while this identify was in flight.
          h.storage.addPendingIdentify((
            anonymousId: r'$ARAnon:NEW',
            appUserId: 'u9',
          ));
          server.handler = null; // offline afterwards
          return (200, customerJson('u1'));
        }
        return (200, customerJson('u1'));
      };
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.storage.pendingIdentifies.single.appUserId, 'u9');
    });

    test('reads the single entry earlier builds saved', () async {
      final h = await Harness.create(
        prefs: {
          'apprefer_billing_pending_identify': jsonEncode({
            'anonymousId': r'$ARAnon:OLD',
            'appUserId': 'u1',
          }),
        },
      );
      expect(h.storage.pendingIdentifies, [
        (anonymousId: r'$ARAnon:OLD', appUserId: 'u1'),
      ]);
    });
  });

  group('storage safety', () {
    test('unreadable identity: nothing sent, nothing minted', () async {
      late FlakyPrefs flaky;
      final h = await Harness.create(
        server: FakeServer()..online(),
        prefs: {'apprefer_billing_anonymous_id': r'$ARAnon:KEEP'},
        wrapPrefs: (p) =>
            flaky = FlakyPrefs(p)
              ..unreadable.add('apprefer_billing_anonymous_id'),
      );
      h.store.entitlements = [activeSub('pro_yearly')];
      final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.server.requests, isEmpty);
      expect(info.source, CustomerInfoSource.localFallback);
      expect(info.entitlements['premium']?.isActive, isTrue);
      expect(
        flaky.inner.getString('apprefer_billing_anonymous_id'),
        r'$ARAnon:KEEP',
      );
      await expectLater(
        h.engine.logIn('u1'),
        throwsA(
          isA<AppReferBillingException>().having(
            (e) => e.code,
            'code',
            AppReferBillingErrorCode.storage,
          ),
        ),
      );

      // Readable again: the same id is used.
      flaky.unreadable.clear();
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.server.requests.first.body, contains(r'$ARAnon:KEEP'));
    });

    test('unreadable identity: purchases are not finished', () async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        wrapPrefs: (p) =>
            FlakyPrefs(p)..unreadable.add('apprefer_billing_app_user_id'),
      );
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.server.requests, isEmpty);
      expect(h.store.completed, isEmpty);
    });

    test('identity not saved: waits, then sends the same id', () async {
      late FlakyPrefs flaky;
      final h = await Harness.create(
        server: FakeServer()..online(),
        wrapPrefs: (p) => flaky = FlakyPrefs(p)..failWrites = true,
      );
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.server.requests, isEmpty);
      final id = h.engine.currentAppUserId;

      flaky.failWrites = false;
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.server.bodiesFor('/api/billing/v1/customers').single, {
        'appUserId': id,
        'appreferId': 'device-1',
      });
    });

    test('Apple purchase stays unfinished if the queue is not saved', () async {
      late FlakyPrefs flaky;
      final h = await Harness.create(wrapPrefs: (p) => flaky = FlakyPrefs(p));
      h.engine.currentAppUserId;
      await h.storage.flush();
      flaky.failWrites = true;
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.store.completed, isEmpty);
    });

    test('an unreadable queue is never overwritten', () async {
      SharedPreferences.setMockInitialValues({
        BillingStorage.pendingPurchasesKey: 'stored',
      });
      final real = await SharedPreferences.getInstance();
      final flaky = FlakyPrefs(real)
        ..unreadable.add(BillingStorage.pendingPurchasesKey);
      final q = PendingPurchaseQueue(flaky, BillingStorage.pendingPurchasesKey);
      expect(q.isUnreadable, isTrue);
      final saved = await q.add(
        PendingPurchase(
          transactionId: 't1',
          productId: 'p',
          appUserId: 'u1',
          appreferId: null,
          storeFields: const {'store': 'app_store', 'signedTransaction': 'j'},
          enqueuedAt: now,
        ),
      );
      expect(saved, isFalse);
      expect(real.getString(BillingStorage.pendingPurchasesKey), 'stored');
    });

    test(
      'billing reads the attribution device id but never mints it',
      () async {
        SharedPreferences.setMockInitialValues({});
        final storage = AppReferStorage();
        await storage.init();
        expect(storage.existingDeviceId(), isNull);
        final id = await storage.getDeviceId();
        expect(storage.existingDeviceId(), id);
      },
    );
  });

  group('iOS restore collection', () {
    PurchaseDetails restored(String id) => PurchaseDetails(
      purchaseID: id,
      productID: 'pro_yearly',
      verificationData: PurchaseVerificationData(
        localVerificationData: '{}',
        serverVerificationData: 'jws',
        source: 'app_store',
      ),
      transactionDate: null,
      status: PurchaseStatus.restored,
    );

    test('returns the restored batch', () async {
      final stream = StreamController<List<PurchaseDetails>>.broadcast();
      final result = InAppPurchaseBillingStore.collectAppleRestore(
        stream: stream.stream,
        restore: () async {
          Timer(
            const Duration(milliseconds: 20),
            () => stream.add([restored('a')]),
          );
        },
        hasCurrentEntitlements: () async => true,
        timeout: const Duration(seconds: 1),
      );
      expect((await result).single.purchaseID, 'a');
    });

    test('an empty batch is a definitive empty restore', () async {
      final stream = StreamController<List<PurchaseDetails>>.broadcast();
      final result = await InAppPurchaseBillingStore.collectAppleRestore(
        stream: stream.stream,
        restore: () async => stream.add([]),
        hasCurrentEntitlements: () async => true,
        timeout: const Duration(seconds: 1),
      );
      expect(result, isEmpty);
    });

    test(
      'timeout with active entitlements fails instead of returning empty',
      () async {
        final stream = StreamController<List<PurchaseDetails>>.broadcast();
        await expectLater(
          InAppPurchaseBillingStore.collectAppleRestore(
            stream: stream.stream,
            restore: () async {},
            hasCurrentEntitlements: () async => true,
            timeout: const Duration(milliseconds: 20),
          ),
          throwsA(
            isA<AppReferBillingException>().having(
              (e) => e.code,
              'code',
              AppReferBillingErrorCode.store,
            ),
          ),
        );
      },
    );

    test('timeout with nothing active is an empty restore', () async {
      final stream = StreamController<List<PurchaseDetails>>.broadcast();
      final result = await InAppPurchaseBillingStore.collectAppleRestore(
        stream: stream.stream,
        restore: () async {},
        hasCurrentEntitlements: () async => false,
        timeout: const Duration(milliseconds: 20),
      );
      expect(result, isEmpty);
    });

    test('engine surfaces a restore failure', () async {
      final h = await Harness.create(server: FakeServer()..online());
      final store = _ThrowingRestoreStore();
      final engine = BillingEngine(
        api: BillingApiClient(
          baseUrls: const ['https://trk.example.com'],
          apiKey: () => 'pk',
          client: h.server.client,
          keyWaitAttempts: 0,
        ),
        storage: h.storage,
        queue: h.queue,
        store: store,
        appreferId: () async => null,
      );
      await expectLater(
        engine.restore(),
        throwsA(isA<AppReferBillingException>()),
      );
    });
  });

  group('wire format', () {
    test('Retry-After seconds and HTTP date', () {
      expect(
        BillingApiClient.parseRetryAfter('30'),
        const Duration(seconds: 30),
      );
      expect(
        BillingApiClient.parseRetryAfter(
          'Wed, 21 Oct 2015 07:28:30 GMT',
          now: DateTime.utc(2015, 10, 21, 7, 28),
        ),
        const Duration(seconds: 30),
      );
      expect(BillingApiClient.parseRetryAfter(null), isNull);
      expect(BillingApiClient.parseRetryAfter('soon'), isNull);
    });

    test('503 carries its Retry-After', () async {
      final server = FakeServer()..status(503);
      server.responseHeaders = {'retry-after': '30'};
      final api = BillingApiClient(
        baseUrls: const ['https://example.com'],
        apiKey: () => 'pk',
        client: server.client,
        keyWaitAttempts: 0,
      );
      await expectLater(
        api.send(const GetCustomer('u1')),
        throwsA(
          isA<AppReferBillingException>()
              .having((e) => e.status, 'status', 503)
              .having((e) => e.isRetryable, 'retryable', isTrue)
              .having((e) => e.isBackoff, 'backoff', isFalse)
              .having(
                (e) => e.retryAfter,
                'retryAfter',
                const Duration(seconds: 30),
              ),
        ),
      );
    });
  });
}

class _ThrowingRestoreStore extends FakeStore {
  @override
  Future<List<StorePurchase>> restore() async =>
      throw const AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: 'timed out',
      );
}
