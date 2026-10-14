import 'dart:convert';

import 'package:apprefer/src/billing/billing_api_client.dart';
import 'package:apprefer/src/billing/billing_engine.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/customer_info.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:apprefer/src/billing/rejected_purchases.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const purchases = '/api/billing/v1/purchases';
const intentsKey = BillingStorage.purchaseIntentsKey;
const lostKey = '${BillingStorage.purchaseIntentsKey}_lost';

/// The same device after a restart, signed in as [appUserId].
BillingEngine restarted(Harness h, {String? appUserId}) => BillingEngine(
  api: BillingApiClient(
    baseUrls: const ['https://trk.example.com'],
    apiKey: () => 'pk_test_1',
    client: h.server.client,
    keyWaitAttempts: 0,
  ),
  storage: BillingStorage(h.prefs),
  queue: PendingPurchaseQueue(h.prefs, BillingStorage.pendingPurchasesKey),
  store: h.store,
  appUserId: appUserId,
  appreferId: () async => 'device-1',
  now: () => h.time,
);

Map<String, Object?> intent(
  String user, {
  String productId = 'pro_yearly',
  String? accountToken,
  int ageMs = 0,
}) => {
  'appUserId': user,
  'productId': productId,
  'accountToken': accountToken,
  'startedAtMs': now.millisecondsSinceEpoch - ageMs,
};

Future<void> saveIntents(Harness h, List<Map<String, Object?>> intents) =>
    h.prefs.setString(intentsKey, jsonEncode(intents));

List<Map<String, dynamic>> storedIntents(SharedPreferences prefs) =>
    (jsonDecode(prefs.getString(intentsKey) ?? '[]') as List)
        .cast<Map<String, dynamic>>();

List<Map<String, dynamic>> storedRejected(SharedPreferences prefs) =>
    (jsonDecode(prefs.getString(BillingStorage.rejectedPurchasesKey) ?? '[]')
            as List)
        .cast<Map<String, dynamic>>();

String? sentUser(Harness h) =>
    h.server.bodiesFor(purchases).lastOrNull?['appUserId'] as String?;

void main() {
  test('(a) the rejected archive has no cap and never evicts', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final log = RejectedPurchaseLog(prefs, BillingStorage.rejectedPurchasesKey);
    for (var i = 0; i < 260; i++) {
      expect(
        await log.add(
          RejectedPurchase(
            transactionId: 't$i',
            productId: 'pro_yearly',
            store: BillingStore.appStore,
            appUserId: 'u1',
            appreferId: null,
            storeFields: const {'store': 'app_store', 'signedTransaction': 'j'},
            accountToken: null,
            kind: null,
            reason: '400',
            rejectedAt: now,
          ),
        ),
        isTrue,
      );
    }
    expect(storedRejected(prefs), hasLength(260));
    expect(log.contains(BillingStore.appStore, 't0'), isTrue);

    // It only shrinks when AppRefer records an entry.
    await log.remove(BillingStore.appStore, 't0');
    expect(storedRejected(prefs), hasLength(259));
    expect(
      RejectedPurchaseLog(
        prefs,
        BillingStorage.rejectedPurchasesKey,
      ).entries.length,
      259,
    );
  });

  group('(b) renewals never match or consume a saved intent', () {
    test('Apple: original transaction id differs from the id', () async {
      final h = await Harness.create(server: FakeServer()..online());
      await saveIntents(h, [intent('u1')]);
      final engine = restarted(h, appUserId: 'u2');
      await engine.process(
        h.store.applePurchase('t2', 'pro_yearly', originalTransactionId: 't1'),
      );
      expect(sentUser(h), 'u2');
      expect(storedIntents(h.prefs), hasLength(1), reason: 'not consumed');

      // The first transaction of the chain is a new purchase.
      await engine.process(
        h.store.applePurchase('t9', 'pro_yearly', originalTransactionId: 't9'),
      );
      expect(sentUser(h), 'u1');
      expect(storedIntents(h.prefs), isEmpty);
    });

    test('Google: an order id with a ..N renewal suffix', () async {
      final h = await Harness.create(server: FakeServer()..online());
      h.store.store = BillingStore.playStore;
      await saveIntents(h, [intent('u1')]);
      final engine = restarted(h, appUserId: 'u2');
      await engine.process(
        h.store.googlePurchase(
          'tok-r',
          'pro_yearly',
          orderId: 'GPA.1234-5678-9012-34567..0',
        ),
      );
      expect(sentUser(h), 'u2');
      expect(storedIntents(h.prefs), hasLength(1));

      await engine.process(
        h.store.googlePurchase(
          'tok-1',
          'pro_yearly',
          orderId: 'GPA.1234-5678-9012-34568',
        ),
      );
      expect(sentUser(h), 'u1');
      expect(storedIntents(h.prefs), isEmpty);
    });

    test('a renewal on the stream does not take a waiting purchase', () async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        appUserId: 'u1',
      );
      h.store.onBuy = (product, _) => h.store.updates.add([
        h.store.applePurchase('t2', product.id, originalTransactionId: 't1'),
        h.store.applePurchase('t3', product.id),
      ]);
      final result = await h.engine.purchase(
        FakeProduct('pro_yearly'),
        const StorePurchaseOptions(),
      );
      expect(result.outcome, PurchaseOutcome.purchased);
      expect(h.store.completed, containsAll(['t2', 't3']));
      // The waiter was resolved by t3, which used up the intent.
      expect(storedIntents(h.prefs), isEmpty);
    });
  });

  test(
    '(c) an untagged new purchase takes the oldest intent for the product, tagged or not',
    () async {
      final h = await Harness.create(server: FakeServer()..online());
      await saveIntents(h, [
        intent('u3', ageMs: 1000),
        intent('u1', accountToken: token, ageMs: 5000),
        intent('u4', productId: 'other', ageMs: 9000),
      ]);
      final engine = restarted(h, appUserId: 'u2');
      await engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(sentUser(h), 'u1');
      expect(storedIntents(h.prefs).map((e) => e['appUserId']), ['u3', 'u4']);
    },
  );

  group('(d) unparseable intents', () {
    test('are quarantined with a marker and hold untagged purchases', () async {
      final h = await Harness.create(server: FakeServer()..online());
      await h.prefs.setString(intentsKey, '{not json');
      final engine = restarted(h, appUserId: 'u2');

      await engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(h.server.bodiesFor(purchases), isEmpty);
      expect(h.store.completed, isEmpty, reason: 'left open with the store');
      final quarantined = h.prefs.getKeys().where(
        (k) => k.startsWith('${intentsKey}_quarantine_'),
      );
      expect(h.prefs.getString(quarantined.single), '{not json');
      expect(h.prefs.getString(lostKey), isNotNull);
      expect(storedIntents(h.prefs), isEmpty);

      // A renewal is not held.
      await engine.process(
        h.store.applePurchase('t5', 'pro_yearly', originalTransactionId: 't4'),
      );
      expect(sentUser(h), 'u2');

      // Retried on foreground, still inside the 48 h hold.
      h.store.unfinishedList = [h.store.applePurchase('t1', 'pro_yearly')];
      h.time = now.add(const Duration(hours: 47));
      await engine.retryUnfinished();
      expect(h.store.completed, isNot(contains('t1')));
      expect(h.prefs.getString(lostKey), isNotNull);

      // After 48 h it goes to the current user and the marker clears.
      h.time = now.add(const Duration(hours: 48));
      await engine.retryUnfinished();
      expect(sentUser(h), 'u2');
      expect(h.store.completed, contains('t1'));
      expect(h.prefs.getString(lostKey), isNull);

      // With the marker gone, untagged purchases are no longer held.
      await engine.process(h.store.applePurchase('t6', 'pro_yearly'));
      expect(h.store.completed, contains('t6'));
    });

    test('the hold counts from the purchase time when earlier', () async {
      final h = await Harness.create(server: FakeServer()..online());
      await h.prefs.setString(intentsKey, '[{"bad":1}]');
      final engine = restarted(h, appUserId: 'u2');
      await engine.process(
        h.store.googlePurchase(
          'tok',
          'pro_yearly',
          orderId: 'GPA.1',
          purchasedAt: now.subtract(const Duration(hours: 49)),
        ),
      );
      expect(sentUser(h), 'u2');
    });

    test('the hold counts from the loss when the purchase is later', () async {
      final h = await Harness.create(server: FakeServer()..online());
      await h.prefs.setString(intentsKey, '[{"bad":1}]');
      final engine = restarted(h, appUserId: 'u2');
      await engine.process(h.store.applePurchase('t0', 'pro_yearly'));
      expect(h.prefs.getString(lostKey), isNotNull);

      // Bought a day after the loss: held until 48 h after the loss.
      h.time = now.add(const Duration(hours: 24));
      final later = h.store.googlePurchase(
        'tok',
        'pro_yearly',
        orderId: 'GPA.1',
        purchasedAt: h.time,
      );
      await engine.process(later);
      expect(h.server.bodiesFor(purchases), isEmpty);
      h.time = now.add(const Duration(hours: 48));
      await engine.process(later);
      expect(sentUser(h), 'u2');
    });

    test('a guessed owner is noted on the rejected archive entry', () async {
      final h = await Harness.create(server: FakeServer()..status(400));
      await h.prefs.setString(intentsKey, '7');
      final engine = restarted(h, appUserId: 'u2');
      await engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(storedRejected(h.prefs), isEmpty);

      h.time = now.add(const Duration(hours: 48));
      await engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      final entry = storedRejected(h.prefs).single;
      expect(entry['appUserId'], 'u2');
      expect(entry['note'], contains('intents were lost'));
    });

    test('the marker stays for 48 h even with nothing held', () async {
      final h = await Harness.create(server: FakeServer()..online());
      await h.prefs.setString(intentsKey, 'oops');
      final engine = restarted(h, appUserId: 'u2');
      await engine.retryUnfinished(); // reads (and quarantines) nothing yet
      await engine.process(
        h.store.applePurchase('t1', 'pro_yearly', accountToken: token),
      ); // a tagged purchase reads the intents
      expect(h.prefs.getString(lostKey), isNotNull);
      h.time = now.add(const Duration(hours: 1));
      await engine.retryUnfinished();
      expect(h.prefs.getString(lostKey), isNotNull);
      h.time = now.add(const Duration(hours: 48));
      await engine.retryUnfinished();
      expect(h.prefs.getString(lostKey), isNull);
    });
  });

  group('(e) intents leave only on definitive outcomes', () {
    test('not by age, a store query or a newer purchase', () async {
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
      for (var i = 0; i < 2; i++) {
        final r = await h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        );
        expect(r.outcome, PurchaseOutcome.pending);
        h.time = h.time.add(const Duration(seconds: 1));
      }
      expect(storedIntents(h.prefs), hasLength(2));

      h.time = now.add(const Duration(days: 400));
      h.store.unfinishedList = [];
      await h.engine.retryUnfinished();
      await restarted(h, appUserId: 'u1').retryUnfinished();
      expect(storedIntents(h.prefs), hasLength(2));
    });

    test('kept while the upload is neither recorded nor saved', () async {
      late FlakyPrefs flaky;
      final h = await Harness.create(wrapPrefs: (p) => flaky = FlakyPrefs(p));
      await saveIntents(h, [intent('u1')]);
      await h.storage.flush();
      flaky.failWrites = true; // network down and the retry copy can't save
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(storedIntents(h.prefs), hasLength(1));

      flaky.failWrites = false; // queued durably now
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(storedIntents(h.prefs), isEmpty);
    });
  });
}
