import 'dart:async';
import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_api_client.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const purchases = '/api/billing/v1/purchases';
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

/// SharedPreferences whose writes wait for [gate] and then report [result].
class GatedPrefs implements SharedPreferences {
  final SharedPreferences inner;
  Completer<void> gate = Completer<void>();
  bool result = true;

  GatedPrefs(this.inner);

  @override
  String? getString(String key) => inner.getString(key);

  @override
  Future<bool> setString(String key, String value) async {
    await inner.setString(key, value);
    await gate.future;
    return result;
  }

  @override
  Future<bool> remove(String key) async {
    await inner.remove(key);
    await gate.future;
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PendingPurchase entry(String id, {String user = 'u1'}) => PendingPurchase(
  transactionId: id,
  productId: 'p',
  appUserId: user,
  appreferId: null,
  storeFields: const {'store': 'app_store', 'signedTransaction': 'j'},
  enqueuedAt: now,
);

void main() {
  group('retryUnfinished does not wait on itself', () {
    test(
      'processing inside a pass that drains a queued consumable completes',
      () async {
        final h = await Harness.create();
        h.store.store = BillingStore.playStore;
        purchasesFail(h, 503);
        final coins = h.store.googlePurchase(
          'tok_c',
          'coins',
          kind: StoreProductKind.consumable,
        );
        await h.engine.process(coins);
        expect(h.queue.isDurable('tok_c'), isTrue);
        expect(h.store.completed, isEmpty);

        h.server.online();
        h.store.unfinishedList = [
          h.store.googlePurchase('tok_n', 'pro_yearly'),
          h.store.googlePurchase(
            'tok_c',
            'coins',
            kind: StoreProductKind.consumable,
            isAcknowledged: true,
          ),
        ];
        await h.engine.retryUnfinished().timeout(const Duration(seconds: 2));
        expect(h.queue.isEmpty, isTrue);
        expect(h.store.completed, containsAll(['tok_n', 'tok_c']));
      },
    );
  });

  group('completed only once the retry copy is on disk', () {
    test(
      'Apple: left open while unsaved, finished once saved on foreground',
      () async {
        late FlakyPrefs flaky;
        final h = await Harness.create(wrapPrefs: (p) => flaky = FlakyPrefs(p));
        h.engine.currentAppUserId;
        await h.storage.flush();
        flaky.failWrites = true;
        await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        expect(h.queue.contains('t1'), isTrue, reason: 'provisional');
        expect(h.queue.isDurable('t1'), isFalse);
        expect(h.store.completed, isEmpty);

        // Foreground, disk still failing: still not finished.
        h.store.unfinishedList = [h.store.applePurchase('t1', 'pro_yearly')];
        await h.engine.retryUnfinished();
        expect(h.store.completed, isEmpty);

        flaky.failWrites = false;
        await h.engine.retryUnfinished();
        expect(h.queue.isDurable('t1'), isTrue);
        expect(h.store.completed, ['t1']);
        expect(
          PendingPurchaseQueue(
            h.prefs,
            BillingStorage.pendingPurchasesKey,
          ).contains('t1'),
          isTrue,
        );
      },
    );

    test('unreadable identity: Google purchase is not acknowledged', () async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        wrapPrefs: (p) =>
            FlakyPrefs(p)..unreadable.add('apprefer_billing_app_user_id'),
      );
      h.store.store = BillingStore.playStore;
      await h.engine.process(h.store.googlePurchase('tok_1', 'pro_yearly'));
      expect(h.store.acknowledged, isEmpty);
      expect(h.store.completed, isEmpty);
    });

    test(
      'identity not on disk: purchase not sent, bound or finished',
      () async {
        late FlakyPrefs flaky;
        final h = await Harness.create(
          server: FakeServer()..online(),
          wrapPrefs: (p) => flaky = FlakyPrefs(p)..failWrites = true,
        );
        await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        expect(h.server.requests, isEmpty);
        expect(h.queue.isEmpty, isTrue);
        expect(h.store.completed, isEmpty);
        flaky.failWrites = false;
        await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        expect(h.store.completed, ['t1']);
      },
    );
  });

  group('unreadable queue recovers', () {
    test('re-read later and merged with what was queued meanwhile', () async {
      SharedPreferences.setMockInitialValues({
        BillingStorage.pendingPurchasesKey: jsonEncode([entry('old').toJson()]),
      });
      final real = await SharedPreferences.getInstance();
      final flaky = FlakyPrefs(real)
        ..unreadable.add(BillingStorage.pendingPurchasesKey);
      final q = PendingPurchaseQueue(flaky, BillingStorage.pendingPurchasesKey);
      expect(await q.add(entry('new')), isFalse);
      expect(q.isDurable('new'), isFalse);

      flaky.unreadable.clear();
      expect(q.entries.map((e) => e.transactionId), ['new', 'old']);
      expect(await q.persist(), isTrue);
      expect(q.isDurable('new'), isTrue);
      final reloaded = PendingPurchaseQueue(
        real,
        BillingStorage.pendingPurchasesKey,
      );
      expect(
        reloaded.entries.map((e) => e.transactionId),
        unorderedEquals(['new', 'old']),
      );
    });

    test('an entry removed while unreadable does not come back', () async {
      SharedPreferences.setMockInitialValues({
        BillingStorage.pendingPurchasesKey: jsonEncode([entry('a').toJson()]),
      });
      final real = await SharedPreferences.getInstance();
      final flaky = FlakyPrefs(real)
        ..unreadable.add(BillingStorage.pendingPurchasesKey);
      final q = PendingPurchaseQueue(flaky, BillingStorage.pendingPurchasesKey);
      await q.add(entry('a'));
      await q.remove('a');
      flaky.unreadable.clear();
      expect(q.isEmpty, isTrue);
    });
  });

  group('upload failure while the customer endpoint works', () {
    for (final status in [400, 409, 503]) {
      test('$status: another user\'s tagged purchase stays locked', () async {
        final h = await Harness.create(appUserId: 'u2');
        purchasesFail(h, status);
        h.storage.setAccountToken(otherToken, 'u1');
        h.store.entitlements = [
          activeSub(
            'pro_yearly',
            accountToken: otherToken,
            transactionId: 'tA',
          ),
        ];
        final info = await h.engine.process(
          h.store.applePurchase('t1', 'x'),
          appUserId: 'u2',
        );
        expect(info.source, CustomerInfoSource.server);
        expect(info.entitlements['premium'], isNull);
      });
    }

    test('the payer\'s own queued purchase still unlocks', () async {
      final h = await Harness.create(appUserId: 'u2');
      purchasesFail(h, 503);
      h.store.entitlements = [
        activeSub('pro_yearly', accountToken: otherToken, transactionId: 't1'),
      ];
      final info = await h.engine.process(
        h.store.applePurchase('t1', 'pro_yearly'),
      );
      expect(info.source, CustomerInfoSource.server);
      expect(info.entitlements['premium']?.isActive, isTrue);
    });

    test('restore failure is filtered too', () async {
      final h = await Harness.create(appUserId: 'u2');
      purchasesFail(h, 500);
      h.store.entitlements = [
        activeSub('pro_yearly', accountToken: otherToken, transactionId: 'tA'),
      ];
      h.store.restoreList = [
        h.store.applePurchase('r1', 'x', status: StorePurchaseStatus.restored),
      ];
      final info = await h.engine.restore();
      expect(info.source, CustomerInfoSource.server);
      expect(info.entitlements['premium'], isNull);
    });

    test('total outage still unlocks every verified purchase', () async {
      final h = await Harness.create(appUserId: 'u2');
      h.store.entitlements = [
        activeSub('pro_yearly', accountToken: otherToken, transactionId: 'tA'),
      ];
      final info = await h.engine.process(h.store.applePurchase('t1', 'x'));
      expect(info.source, CustomerInfoSource.localFallback);
      expect(info.entitlements['premium']?.isActive, isTrue);
    });
  });

  group('initiating identity', () {
    test(
      'logIn while the account token is fetched does not move the purchase',
      () async {
        final h = await Harness.create(appUserId: 'u1');
        var loggedIn = false;
        h.server.handler = (r) {
          if (!loggedIn && r.url.path == '/api/billing/v1/customers') {
            loggedIn = true;
            unawaited(h.engine.logIn('u2'));
          }
          final user = r.method == 'GET'
              ? r.url.queryParameters['appUserId']!
              : (jsonDecode(r.body) as Map)['appUserId'] as String;
          return (200, customerJson(user));
        };
        h.engine.listen();
        h.store.onBuy = (product, _) =>
            h.store.updates.add([h.store.applePurchase('t1', product.id)]);
        await h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        );
        expect(h.engine.currentAppUserId, 'u2');
        expect(h.server.bodiesFor(purchases).single['appUserId'], 'u1');
      },
    );
  });

  group('restore ownership', () {
    test('explicit restore takes over a queued entry; redelivery does not '
        'take it back', () async {
      final h = await Harness.create(appUserId: 'u1');
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.queue.entries.single.appUserId, 'u1');

      await h.engine.logIn('u2');
      h.store.restoreList = [
        h.store.applePurchase(
          't1',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
        ),
      ];
      await h.engine.restore();
      expect(h.queue.entries.single.appUserId, 'u2');
      expect(h.queue.entries.single.restore, isTrue);

      // An ordinary redelivery bound to u1 keeps the restore's owner.
      await h.engine.process(
        h.store.applePurchase('t1', 'pro_yearly'),
        appUserId: 'u1',
      );
      expect(h.queue.entries.single.appUserId, 'u2');
      expect(h.queue.entries.single.restore, isTrue);

      h.server.requests.clear();
      h.server.online();
      await h.engine.drainQueue();
      final body = h.server.bodiesFor(purchases).single;
      expect(body['appUserId'], 'u2');
      expect(body['restore'], isTrue);
    });

    test('a paused restore queues the rest without sending them', () async {
      final h = await Harness.create();
      purchasesFail(h, 429);
      h.store.restoreList = [
        for (final id in ['r1', 'r2', 'r3'])
          h.store.applePurchase(
            id,
            'pro_yearly',
            status: StorePurchaseStatus.restored,
          ),
      ];
      // Restored Apple transactions need no finish; make them need one so
      // securing is visible.
      h.store.restoreList = [
        for (final p in h.store.restoreList)
          StorePurchase(
            id: p.id,
            productId: p.productId,
            store: p.store,
            status: p.status,
            signedTransaction: 'jws',
            kind: p.kind,
            complete: () async => h.store.completed.add(p.id),
          ),
      ];
      await h.engine.restore();
      expect(h.server.bodiesFor(purchases), hasLength(1));
      expect(h.queue.entries.map((e) => e.transactionId), ['r1', 'r2', 'r3']);
      expect(h.queue.entries.every((e) => e.restore), isTrue);
      expect(h.queue.entries.every((e) => e.attempts == 0), isTrue);
      expect(h.store.completed, ['r1', 'r2', 'r3']);
    });
  });

  group('identity persistence', () {
    test('concurrent flushes share one result', () async {
      SharedPreferences.setMockInitialValues({});
      final gated = GatedPrefs(await SharedPreferences.getInstance());
      final storage = BillingStorage(gated);
      storage.loggedInAppUserId = 'u1';
      final first = storage.flush();
      storage.loggedInAppUserId = 'u2';
      final second = storage.flush();
      var secondDone = false;
      unawaited(second.then((_) => secondDone = true));
      await pumpEventQueue();
      expect(secondDone, isFalse, reason: 'waits for the write in flight');
      gated.result = false;
      gated.gate.complete();
      expect(await first, isFalse);
      expect(await second, isFalse);
    });

    test('a flush includes writes made while it waits', () async {
      SharedPreferences.setMockInitialValues({});
      final gated = GatedPrefs(await SharedPreferences.getInstance());
      final storage = BillingStorage(gated);
      final firstGate = gated.gate;
      storage.loggedInAppUserId = 'u1';
      final flush = storage.flush();
      await pumpEventQueue();
      final secondGate = gated.gate = Completer<void>();
      storage.loggedInAppUserId = 'u2';
      var done = false;
      unawaited(flush.then((_) => done = true));
      firstGate.complete();
      await pumpEventQueue();
      expect(done, isFalse, reason: 'the u2 write is still unconfirmed');
      secondGate.complete();
      expect(await flush, isTrue);
    });

    test('a failed older write is never redone over a newer one', () async {
      late FlakyPrefs flaky;
      SharedPreferences.setMockInitialValues({});
      flaky = FlakyPrefs(await SharedPreferences.getInstance())
        ..failWrites = true;
      final storage = BillingStorage(flaky);
      storage.loggedInAppUserId = 'u1';
      flaky.failWrites = false;
      storage.loggedInAppUserId = 'u2';
      expect(await storage.flush(), isTrue);
      expect(flaky.inner.getString('apprefer_billing_app_user_id'), 'u2');
    });
  });

  group('Retry-After', () {
    test('kept when the next host cannot be reached', () async {
      final server = FakeServer((r) {
        if (r.url.host == 'trk.example.com') return (503, {'error': 'busy'});
        throw http.ClientException('offline');
      });
      server.responseHeaders = {'retry-after': '120'};
      final api = BillingApiClient(
        baseUrls: const ['https://trk.example.com', 'https://example.com'],
        apiKey: () => 'pk',
        client: server.client,
        keyWaitAttempts: 0,
      );
      await expectLater(
        api.send(const GetCustomer('u1')),
        throwsA(
          isA<AppReferBillingException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            const Duration(seconds: 120),
          ),
        ),
      );
    });

    test('503 pauses the queue that long without counting attempts', () async {
      final h = await Harness.create();
      purchasesFail(h, 503);
      h.server.responseHeaders = {'retry-after': '120'};
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.queue.entries.single.attempts, 0);
      h.server.requests.clear();
      h.time = now.add(const Duration(seconds: 119));
      await h.engine.drainQueue();
      expect(h.server.bodiesFor(purchases), isEmpty);
      h.time = now.add(const Duration(seconds: 120));
      await h.engine.drainQueue();
      expect(h.server.bodiesFor(purchases), isNotEmpty);
      expect(h.queue.entries.single.attempts, 0);
    });
  });

  group('legacy 200 with conversion "failed"', () {
    Map<String, dynamic> failedAnswer(http.Request r) => {
      ...customerJson((jsonDecode(r.body) as Map)['appUserId'] as String),
      'purchase': {'conversion': 'failed'},
    };

    test('the client treats it as a retryable 503', () async {
      final server = FakeServer((r) => (200, failedAnswer(r)));
      final api = BillingApiClient(
        baseUrls: const ['https://example.com'],
        apiKey: () => 'pk',
        client: server.client,
        keyWaitAttempts: 0,
      );
      await expectLater(
        api.send(const RecordPurchase('u1', null, {'store': 'app_store'}, {})),
        throwsA(
          isA<AppReferBillingException>()
              .having((e) => e.status, 'status', 503)
              .having((e) => e.isRetryable, 'retryable', isTrue),
        ),
      );
      // Other answers are unaffected.
      server.handler = (r) => (
        200,
        {
          ...customerJson('u1'),
          'purchase': {'conversion': 'forwarded'},
        },
      );
      await api.send(const RecordPurchase('u1', null, {}, {}));
    });

    test('a Google consumable stays queued and is not consumed', () async {
      final h = await Harness.create();
      h.store.store = BillingStore.playStore;
      h.server.handler = (r) => r.url.path == purchases
          ? (200, failedAnswer(r))
          : (200, customerJson(r.url.queryParameters['appUserId'] ?? 'x'));
      await h.engine.process(
        h.store.googlePurchase(
          'tok_1',
          'coins',
          kind: StoreProductKind.consumable,
        ),
      );
      expect(h.queue.entries.single.transactionId, 'tok_1');
      expect(h.store.completed, isEmpty);
      expect(h.store.acknowledged, ['tok_1']);
    });
  });
}
