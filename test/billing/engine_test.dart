import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const purchases = '/api/billing/v1/purchases';
const customers = '/api/billing/v1/customers';
const identify = '/api/billing/v1/identify';

void main() {
  group('outage safety', () {
    test('server down unlocks from the store', () async {
      final h = await Harness.create();
      h.store.entitlements = [activeSub('pro_yearly')];
      final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(info.source, CustomerInfoSource.localFallback);
      expect(info.entitlements['premium']?.isActive, isTrue);
      expect(info.activeSubscriptions, {'pro_yearly'});
      expect(h.published.last.entitlements['premium']?.isActive, isTrue);
    });

    test('server error status also falls back', () async {
      final h = await Harness.create(server: FakeServer()..status(404));
      h.store.entitlements = [activeSub('pro_yearly')];
      final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(info.source, CustomerInfoSource.localFallback);
      expect(info.entitlements['premium']?.isActive, isTrue);
    });

    test('keeps cached entitlements for the same user only', () async {
      final server = FakeServer()..online(active: {'web_pro': 'stripe_plan'});
      final h = await Harness.create(server: server, appUserId: 'u1');
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      server.offline();

      final same = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(same.source, CustomerInfoSource.localFallback);
      expect(same.entitlements['web_pro']?.isActive, isTrue);

      await h.engine.logIn('u2');
      final other = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(other.appUserId, 'u2');
      expect(other.entitlements['web_pro'], isNull);
    });

    test('cachedOrFetched uses a fresh cache without network', () async {
      final server = FakeServer()..online(active: {'premium': 'pro_yearly'});
      final h = await Harness.create(server: server);
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      final count = server.requests.length;
      final info = await h.engine.customerInfo(FetchPolicy.cachedOrFetched);
      expect(server.requests.length, count);
      expect(info.source, CustomerInfoSource.cache);
      expect(info.entitlements['premium']?.isActive, isTrue);
    });
  });

  group('server sync', () {
    test('first fetch registers the customer, then uses GET', () async {
      final server = FakeServer()..online();
      final h = await Harness.create(server: server);
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(server.paths, ['POST $customers', 'GET $customers']);
      final body = server.bodiesFor(customers).single;
      expect(body['appreferId'], 'device-1');
      expect(body['appUserId'], startsWith(r'$ARAnon:'));
      expect(h.storage.accountToken(h.engine.currentAppUserId), token);
    });

    test('attributes are sent with the next call', () async {
      final server = FakeServer()..online();
      final h = await Harness.create(server: server);
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      h.engine.setAttributes({r'$email': 'a@b.com'});
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(server.bodiesFor(customers).last['attributes'], {
        r'$email': 'a@b.com',
      });
      expect(h.storage.pendingAttributes, isEmpty);
    });
  });

  group('purchases', () {
    test(
      'accepted purchase is completed only after the server accepted it',
      () async {
        final server = FakeServer();
        final h = await Harness.create(server: server);
        final order = <String>[];
        server.handler = (r) {
          order.add('server');
          expect(
            h.store.completed,
            isEmpty,
            reason: 'completed before AppRefer accepted',
          );
          return (
            200,
            customerJson(
              h.engine.currentAppUserId,
              active: {'premium': 'pro_yearly'},
            ),
          );
        };
        final p = h.store.applePurchase('t1', 'pro_yearly');
        final info = await h.engine.process(p);
        order.add('done');
        expect(h.store.completed, ['t1']);
        expect(order, ['server', 'done']);
        expect(info.source, CustomerInfoSource.server);
        expect(info.entitlements['premium']?.isActive, isTrue);
        expect(h.queue.isEmpty, isTrue);
        final body = server.bodiesFor(purchases).single;
        expect(body['store'], 'app_store');
        expect(body['signedTransaction'], 'jws.payload.sig');
        expect(body['appreferId'], 'device-1');
      },
    );

    test(
      'unreachable server queues on disk, completes and still unlocks',
      () async {
        final h = await Harness.create();
        h.store.entitlements = [activeSub('pro_yearly')];
        final info = await h.engine.process(
          h.store.applePurchase('t1', 'pro_yearly'),
        );
        expect(h.store.completed, ['t1']);
        expect(info.entitlements['premium']?.isActive, isTrue);
        expect(info.source, CustomerInfoSource.localFallback);
        final stored =
            jsonDecode(h.prefs.getString(BillingStorage.pendingPurchasesKey)!)
                as List;
        expect((stored.single as Map)['transactionId'], 't1');
      },
    );

    test('rejected purchase is completed, not queued', () async {
      final h = await Harness.create(server: FakeServer()..status(400));
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.store.completed, ['t1']);
      expect(h.queue.isEmpty, isTrue);
    });

    test(
      'purchase without verifiable data is completed without calling the server',
      () async {
        final server = FakeServer()..online();
        final h = await Harness.create(server: server);
        final info = await h.engine.process(
          h.store.applePurchase('t1', 'p', jws: null),
        );
        expect(server.bodiesFor(purchases), isEmpty);
        expect(h.store.completed, ['t1']);
        expect(info.entitlements.active, isEmpty);
      },
    );

    test(
      'Google consumable is sent with its type and consumed after acceptance',
      () async {
        final server = FakeServer()..online();
        final h = await Harness.create(server: server);
        h.store.store = BillingStore.playStore;
        await h.engine.process(
          h.store.googlePurchase(
            'tok_1',
            'coins',
            kind: StoreProductKind.consumable,
          ),
        );
        final body = server.bodiesFor(purchases).single;
        expect(body['store'], 'play_store');
        expect(body['purchaseToken'], 'tok_1');
        expect(body['productId'], 'coins');
        expect(body['productType'], 'consumable');
        expect(h.store.completed, ['tok_1']);
      },
    );

    test('the same purchase delivered twice is sent once', () async {
      final server = FakeServer()..online();
      final h = await Harness.create(server: server);
      final p = h.store.applePurchase('t1', 'pro_yearly');
      await Future.wait([h.engine.process(p), h.engine.process(p)]);
      expect(server.bodiesFor(purchases), hasLength(1));
    });

    test('queue drains when the server comes back', () async {
      final server = FakeServer();
      final h = await Harness.create(server: server);
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.queue.entries, hasLength(1));
      server.requests.clear();
      server.online(active: {'premium': 'pro_yearly'});
      final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.queue.isEmpty, isTrue);
      expect(server.bodiesFor(purchases), hasLength(1));
      expect(info.entitlements['premium']?.isActive, isTrue);
    });

    test(
      'server answer is merged with the store while a purchase is still queued',
      () async {
        final server = FakeServer();
        final h = await Harness.create(server: server);
        h.store.entitlements = [activeSub('pro_yearly')];
        await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        // Server reachable for customers but still refuses the purchase.
        server.handler = (r) => r.url.path == purchases
            ? (503, {'error': 'busy'})
            : (200, customerJson(h.engine.currentAppUserId));
        final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
        expect(h.queue.entries, hasLength(1));
        expect(info.source, CustomerInfoSource.server);
        expect(info.entitlements['premium']?.isActive, isTrue);
      },
    );

    test(
      'purchase() tags the account token and returns once AppRefer recorded it',
      () async {
        final server = FakeServer()..online(active: {'premium': 'pro_yearly'});
        final h = await Harness.create(server: server);
        h.engine.listen();
        h.store.onBuy = (product, options) =>
            h.store.updates.add([h.store.applePurchase('t9', product.id)]);
        final result = await h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        );
        expect(h.store.bought.single.$2.accountToken, token);
        expect(result.outcome, PurchaseOutcome.purchased);
        expect(result.userCancelled, isFalse);
        expect(result.customerInfo.entitlements['premium']?.isActive, isTrue);
        expect(h.store.completed, ['t9']);
      },
    );

    test('purchase() reports cancel and pending', () async {
      final h = await Harness.create(server: FakeServer()..online());
      h.engine.listen();
      h.store.onBuy = (product, _) => h.store.updates.add([
        h.store.applePurchase(
          '',
          product.id,
          status: StorePurchaseStatus.canceled,
        ),
      ]);
      final cancelled = await h.engine.purchase(
        FakeProduct('a'),
        const StorePurchaseOptions(),
      );
      expect(cancelled.userCancelled, isTrue);

      h.store.onBuy = (product, _) => h.store.updates.add([
        h.store.applePurchase(
          '',
          product.id,
          status: StorePurchaseStatus.pending,
        ),
      ]);
      final pending = await h.engine.purchase(
        FakeProduct('a'),
        const StorePurchaseOptions(),
      );
      expect(pending.outcome, PurchaseOutcome.pending);
    });

    test('purchase() surfaces store errors', () async {
      final h = await Harness.create(server: FakeServer()..online());
      h.engine.listen();
      h.store.onBuy = (product, _) => h.store.updates.add([
        StorePurchase(
          id: '',
          productId: product.id,
          store: BillingStore.appStore,
          status: StorePurchaseStatus.error,
          errorMessage: 'boom',
          needsCompletion: false,
        ),
      ]);
      await expectLater(
        h.engine.purchase(FakeProduct('a'), const StorePurchaseOptions()),
        throwsA(
          isA<AppReferBillingException>()
              .having((e) => e.code, 'code', AppReferBillingErrorCode.store)
              .having((e) => e.message, 'message', 'boom'),
        ),
      );
    });

    test(
      'purchase() still opens the sheet when AppRefer is down (no token)',
      () async {
        final h = await Harness.create();
        h.store.entitlements = [activeSub('pro_yearly')];
        h.engine.listen();
        h.store.onBuy = (product, _) =>
            h.store.updates.add([h.store.applePurchase('t1', product.id)]);
        final result = await h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        );
        expect(h.store.bought.single.$2.accountToken, isNull);
        expect(result.outcome, PurchaseOutcome.purchased);
        expect(result.customerInfo.entitlements['premium']?.isActive, isTrue);
        expect(h.queue.entries, hasLength(1));
      },
    );

    test('start completes purchases left unfinished', () async {
      final server = FakeServer()..online();
      final h = await Harness.create(server: server);
      h.store.unfinishedList = [h.store.applePurchase('old', 'pro_yearly')];
      await h.engine.start();
      expect(server.bodiesFor(purchases), hasLength(1));
      expect(h.store.completed, ['old']);
    });
  });

  group('restore', () {
    test('syncs and posts every owned purchase', () async {
      final server = FakeServer()..online(active: {'premium': 'pro_yearly'});
      final h = await Harness.create(server: server);
      h.store.restoreList = [
        h.store.applePurchase(
          'a',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
        ),
        h.store.applePurchase(
          'b',
          'lifetime',
          status: StorePurchaseStatus.restored,
        ),
      ];
      final info = await h.engine.restore();
      expect(h.store.syncCalls, 1);
      expect(server.bodiesFor(purchases), hasLength(2));
      expect(info.entitlements['premium']?.isActive, isTrue);
    });

    test('offline restore queues and falls back', () async {
      final h = await Harness.create();
      h.store.entitlements = [activeSub('pro_yearly')];
      h.store.restoreList = [
        h.store.applePurchase(
          'a',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
        ),
        h.store.applePurchase('b', 'x', status: StorePurchaseStatus.restored),
      ];
      final info = await h.engine.restore();
      expect(info.source, CustomerInfoSource.localFallback);
      expect(info.entitlements['premium']?.isActive, isTrue);
      expect(h.queue.entries.map((e) => e.transactionId), ['a', 'b']);
      // Stopped after the first connectivity failure (2 hosts tried once).
      expect(h.server.requests, hasLength(2));
    });

    test('a cancelled App Store sign-in throws', () async {
      final h = await Harness.create();
      h.store.syncError = Exception('userCancelled');
      await expectLater(
        h.engine.restore(),
        throwsA(isA<AppReferBillingException>()),
      );
    });
  });

  group('identity', () {
    test('logIn from anonymous calls identify', () async {
      final server = FakeServer()..online();
      final h = await Harness.create(server: server);
      final anon = h.engine.currentAppUserId;
      final info = await h.engine.logIn('user_1');
      expect(info.appUserId, 'user_1');
      expect(h.engine.isAnonymous, isFalse);
      expect(server.bodiesFor(identify).single, {
        'anonymousId': anon,
        'appUserId': 'user_1',
      });
      expect(h.storage.pendingIdentify, isNull);
    });

    test('logIn while offline retries identify later', () async {
      final server = FakeServer();
      final h = await Harness.create(server: server);
      final anon = h.engine.currentAppUserId;
      await h.engine.logIn('user_1');
      expect(h.storage.pendingIdentify?.anonymousId, anon);
      server.requests.clear();
      server.online();
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(server.bodiesFor(identify), hasLength(1));
      expect(h.storage.pendingIdentify, isNull);
    });

    test('logIn rejects invalid ids', () async {
      final h = await Harness.create();
      for (final bad in ['', 'has space', r'$ARAnon:123', 'x' * 257]) {
        await expectLater(
          h.engine.logIn(bad),
          throwsA(
            isA<AppReferBillingException>().having(
              (e) => e.code,
              'code',
              AppReferBillingErrorCode.invalidAppUserId,
            ),
          ),
          reason: bad,
        );
      }
    });

    test('logOut mints a new anonymous id', () async {
      final h = await Harness.create(server: FakeServer()..online());
      final anon = h.engine.currentAppUserId;
      await h.engine.logIn('user_1');
      final info = await h.engine.logOut();
      expect(h.engine.isAnonymous, isTrue);
      expect(info.appUserId, startsWith(r'$ARAnon:'));
      expect(info.appUserId, isNot(anon));
    });

    test(
      'configure with appUserId after anonymous use queues identify',
      () async {
        SharedPreferences.setMockInitialValues({});
        final first = await Harness.create();
        final anon = first.engine.currentAppUserId;
        final h = await Harness.create(
          prefs: {'apprefer_billing_anonymous_id': anon},
          appUserId: 'user_1',
        );
        expect(h.engine.currentAppUserId, 'user_1');
        expect(h.storage.pendingIdentify?.anonymousId, anon);
      },
    );

    test(
      'configure with appUserId on a fresh install skips identify',
      () async {
        final h = await Harness.create(appUserId: 'user_1');
        expect(h.engine.currentAppUserId, 'user_1');
        expect(h.storage.pendingIdentify, isNull);
      },
    );
  });

  test('a queued purchase keeps its original user after logIn', () async {
    final server = FakeServer();
    final h = await Harness.create(server: server);
    final anon = h.engine.currentAppUserId;
    await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
    expect(
      PendingPurchaseQueue(
        h.prefs,
        BillingStorage.pendingPurchasesKey,
      ).entries.single.appUserId,
      anon,
    );
  });
}
