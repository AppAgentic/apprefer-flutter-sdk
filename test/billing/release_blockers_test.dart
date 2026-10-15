import 'dart:async';
import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_api_client.dart';
import 'package:apprefer/src/billing/billing_engine.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const purchases = '/api/billing/v1/purchases';

/// The same device after a restart: a new engine on the same stored state.
BillingEngine restarted(
  Harness h, {
  SharedPreferences? prefs,
  String? appUserId,
}) {
  final p = prefs ?? h.prefs;
  return BillingEngine(
    api: BillingApiClient(
      baseUrls: const ['https://trk.example.com'],
      apiKey: () => 'pk_test_1',
      client: h.server.client,
      keyWaitAttempts: 0,
    ),
    storage: BillingStorage(p),
    queue: PendingPurchaseQueue(p, BillingStorage.pendingPurchasesKey),
    store: h.store,
    appUserId: appUserId,
    appreferId: () async => 'device-1',
    now: () => h.time,
  );
}

List<Map<String, dynamic>> storedRejected(SharedPreferences prefs) =>
    (jsonDecode(prefs.getString(BillingStorage.rejectedPurchasesKey) ?? '[]')
            as List)
        .cast<Map<String, dynamic>>();

List<Map<String, dynamic>> storedIntents(SharedPreferences prefs) =>
    (jsonDecode(prefs.getString(BillingStorage.purchaseIntentsKey) ?? '[]')
            as List)
        .cast<Map<String, dynamic>>();

void main() {
  group('rejected-purchase archive', () {
    test(
      'a 400 is archived on disk with its store data, then finished',
      () async {
        final h = await Harness.create(
          server: FakeServer()..status(400),
          appUserId: 'u1',
        );
        await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        final stored = storedRejected(h.prefs).single;
        expect(stored['transactionId'], 't1');
        expect(stored['appUserId'], 'u1');
        expect(stored['storeFields'], {
          'store': 'app_store',
          'signedTransaction': 'jws.payload.sig',
        });
        expect(h.store.completed, ['t1']);
        expect(h.engine.rejectedPurchases().single.transactionId, 't1');
      },
    );

    for (final status in [413, 422]) {
      test('$status is archived too', () async {
        final h = await Harness.create(server: FakeServer()..status(status));
        await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        expect(storedRejected(h.prefs), hasLength(1));
        expect(h.queue.isEmpty, isTrue);
      });
    }

    test('a rejected Apple consumable is left unfinished', () async {
      final h = await Harness.create(server: FakeServer()..status(400));
      await h.engine.process(
        h.store.applePurchase('t1', 'coins', kind: StoreProductKind.consumable),
      );
      expect(storedRejected(h.prefs).single['kind'], 'consumable');
      expect(h.store.completed, isEmpty);
    });

    test(
      'a rejected Google consumable is acknowledged, never consumed',
      () async {
        final h = await Harness.create(server: FakeServer()..status(422));
        await h.engine.process(
          h.store.googlePurchase(
            'g1',
            'coins',
            kind: StoreProductKind.consumable,
          ),
        );
        expect(h.store.acknowledged, ['g1']);
        expect(h.store.completed, isEmpty, reason: 'not consumed');

        // Still open next launch: secured again, still not consumed.
        h.store.unfinishedList = [
          h.store.googlePurchase(
            'g1',
            'coins',
            kind: StoreProductKind.consumable,
            isAcknowledged: true,
          ),
        ];
        await h.engine.retryUnfinished();
        expect(h.store.completed, isEmpty);
      },
    );

    test(
      'a purchase without store data is archived with what the store gave',
      () async {
        final h = await Harness.create(server: FakeServer()..online());
        await h.engine.process(
          h.store.applePurchase('t1', 'pro_yearly', jws: null),
        );
        expect(h.server.bodiesFor(purchases), isEmpty);
        final stored = storedRejected(h.prefs).single;
        expect(stored['storeFields'], isNull);
        expect(stored['reason'], 'no verifiable store data');
        expect(jsonDecode(stored['raw'] as String)['id'], 't1');
        expect(h.store.completed, ['t1']);
      },
    );

    test(
      'if the archive cannot be saved the purchase stays open, even from memory',
      () async {
        late FlakyPrefs flaky;
        final h = await Harness.create(
          server: FakeServer()..status(400),
          appUserId: 'u1',
          wrapPrefs: (p) => flaky = FlakyPrefs(p),
        );
        await h.storage.flush();
        flaky.failWrites = true;
        final purchase = h.store.applePurchase('t1', 'pro_yearly');
        await h.engine.process(purchase);
        expect(h.store.completed, isEmpty);

        // Next foreground with the copy still only in memory: still open.
        h.store.unfinishedList = [purchase];
        await h.engine.retryUnfinished();
        expect(h.store.completed, isEmpty);

        flaky.failWrites = false;
        await h.engine.retryUnfinished();
        expect(storedRejected(h.prefs).single['transactionId'], 't1');
        expect(h.store.completed, ['t1']);
      },
    );

    PendingPurchase queued(String id, {int attempts = 1}) => PendingPurchase(
      transactionId: id,
      productId: 'pro_yearly',
      appUserId: 'u1',
      appreferId: 'device-1',
      storeFields: {'store': 'app_store', 'signedTransaction': 'jws_$id'},
      enqueuedAt: now,
      attempts: attempts,
    );

    test('a purchase the retry queue gives up on is archived first', () async {
      final h = await Harness.create(server: FakeServer()..online());
      await h.queue.add(
        queued('t1', attempts: PendingPurchaseQueue.maxAttempts),
      );
      await h.engine.drainQueue();
      expect(h.queue.isEmpty, isTrue);
      final stored = storedRejected(h.prefs).single;
      expect(stored['transactionId'], 't1');
      expect(stored['storeFields']['signedTransaction'], 'jws_t1');
    });

    test('a queued purchase rejected for good is archived first', () async {
      final h = await Harness.create(server: FakeServer()..status(422));
      await h.queue.add(queued('t1'));
      await h.engine.drainQueue();
      expect(h.queue.isEmpty, isTrue);
      expect(storedRejected(h.prefs).single['transactionId'], 't1');
    });

    test('a given-up purchase stays queued if it cannot be archived', () async {
      late FlakyPrefs flaky;
      final h = await Harness.create(
        server: FakeServer()..online(),
        wrapPrefs: (p) => flaky = FlakyPrefs(p),
      );
      await h.queue.add(
        queued('t1', attempts: PendingPurchaseQueue.maxAttempts),
      );
      flaky.failWrites = true;
      h.server.offline();
      await h.engine.drainQueue();
      // The archive write failed, so the retry copy is not dropped.
      expect(h.queue.contains('t1'), isTrue);
    });

    test(
      'restore sends archived purchases the store no longer lists',
      () async {
        final h = await Harness.create(
          server: FakeServer()..status(400),
          appUserId: 'u1',
        );
        await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        h.server.online();
        h.server.requests.clear();
        await h.engine.restore();
        final body = h.server.bodiesFor(purchases).single;
        expect(body['restore'], isTrue);
        expect(body['signedTransaction'], 'jws.payload.sig');
        expect(h.engine.rejectedPurchases(), isEmpty);
        expect(storedRejected(h.prefs), isEmpty);
      },
    );

    test('a restored Google consumable is consumed once recorded', () async {
      final h = await Harness.create(server: FakeServer()..status(400));
      final coins = h.store.googlePurchase(
        'g1',
        'coins',
        kind: StoreProductKind.consumable,
      );
      await h.engine.process(coins);
      expect(h.store.completed, isEmpty);
      h.server.online();
      h.store.restoreList = [coins];
      await h.engine.restore();
      expect(h.store.completed, ['g1']);
      expect(h.engine.rejectedPurchases(), isEmpty);
    });

    test('an archived copy survives a restart', () async {
      final h = await Harness.create(server: FakeServer()..status(400));
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(restarted(h).rejectedPurchases().single.transactionId, 't1');
    });
  });

  group('persisted purchase intent', () {
    test('who started it is on disk before the sheet opens', () async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        appUserId: 'u1',
      );
      List<Map<String, dynamic>>? atBuy;
      h.store.onBuy = (_, _) => atBuy = storedIntents(h.prefs);
      unawaited(
        h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        ),
      );
      await pumpEventQueue();
      expect(atBuy!.single['appUserId'], 'u1');
      expect(atBuy!.single['productId'], 'pro_yearly');
      expect(atBuy!.single['accountToken'], token);
    });

    test('the sheet does not open if the intent cannot be saved', () async {
      late FlakyPrefs flaky;
      final h = await Harness.create(
        server: FakeServer()..online(),
        appUserId: 'u1',
        wrapPrefs: (p) => flaky = FlakyPrefs(p),
      );
      await h.storage.flush();
      flaky.unreadable.add(BillingStorage.purchaseIntentsKey);
      await expectLater(
        h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        ),
        throwsA(
          isA<AppReferBillingException>().having(
            (e) => e.code,
            'code',
            AppReferBillingErrorCode.storage,
          ),
        ),
      );
      expect(h.store.bought, isEmpty);

      flaky.unreadable.clear();
      flaky.failWrites = true;
      await expectLater(
        h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        ),
        throwsA(isA<AppReferBillingException>()),
      );
      expect(h.store.bought, isEmpty);
    });

    test(
      'Ask to Buy approved after a restart and user switch goes to the initiator',
      () async {
        final h = await Harness.create(
          server: FakeServer()..online(),
          appUserId: 'u1',
        );
        h.store.onBuy = (product, _) => h.store.updates.add([
          h.store.applePurchase(
            '',
            product.id,
            status: StorePurchaseStatus.pending,
          ),
        ]);
        final result = await h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        );
        expect(result.outcome, PurchaseOutcome.pending);
        expect(
          storedIntents(h.prefs),
          hasLength(1),
          reason: 'kept while pending',
        );

        // Restart, now signed in as someone else; the approved purchase
        // arrives untagged.
        final engine = restarted(h, appUserId: 'u2');
        h.server.requests.clear();
        await engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        expect(h.server.bodiesFor(purchases).single['appUserId'], 'u1');
        expect(storedIntents(h.prefs), isEmpty, reason: 'resolved');
      },
    );

    test('a tagged purchase resolves through the intent token', () async {
      final h = await Harness.create(server: FakeServer()..online());
      await h.prefs.setString(
        BillingStorage.purchaseIntentsKey,
        jsonEncode([
          {
            'appUserId': 'u1',
            'productId': 'pro_yearly',
            'accountToken': token,
            'startedAtMs': now.millisecondsSinceEpoch,
          },
          {
            'appUserId': 'u3',
            'productId': 'pro_yearly',
            'accountToken': null,
            'startedAtMs': now.millisecondsSinceEpoch - 1000,
          },
        ]),
      );
      final engine = restarted(h, appUserId: 'u2');
      await engine.process(
        h.store.applePurchase('t1', 'pro_yearly', accountToken: token),
      );
      expect(h.server.bodiesFor(purchases).single['appUserId'], 'u1');
    });

    test('unreadable intents defer an untagged delivery', () async {
      final h = await Harness.create(server: FakeServer()..online());
      final flaky = FlakyPrefs(h.prefs)
        ..unreadable.add(BillingStorage.purchaseIntentsKey);
      final engine = restarted(h, prefs: flaky, appUserId: 'u2');
      await engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.server.bodiesFor(purchases), isEmpty);
      expect(h.store.completed, isEmpty, reason: 'left open with the store');
    });

    test('a cancelled purchase drops its intent', () async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        appUserId: 'u1',
      );
      h.store.onBuy = (product, _) => h.store.updates.add([
        h.store.applePurchase(
          '',
          product.id,
          status: StorePurchaseStatus.canceled,
        ),
      ]);
      final result = await h.engine.purchase(
        FakeProduct('pro_yearly'),
        const StorePurchaseOptions(),
      );
      expect(result.userCancelled, isTrue);
      expect(storedIntents(h.prefs), isEmpty);
    });

    test('an intent is kept until a rejected purchase is archived', () async {
      late FlakyPrefs flaky;
      final h = await Harness.create(
        server: FakeServer()..status(400),
        wrapPrefs: (p) => flaky = FlakyPrefs(p),
      );
      await h.prefs.setString(
        BillingStorage.purchaseIntentsKey,
        jsonEncode([
          {
            'appUserId': 'u1',
            'productId': 'pro_yearly',
            'startedAtMs': now.millisecondsSinceEpoch,
          },
        ]),
      );
      await h.storage.flush();
      flaky.failWrites = true;
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(storedIntents(h.prefs), hasLength(1));
      expect(h.store.completed, isEmpty);

      flaky.failWrites = false;
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(storedRejected(h.prefs).single['appUserId'], 'u1');
      expect(storedIntents(h.prefs), isEmpty);
    });
  });
}
