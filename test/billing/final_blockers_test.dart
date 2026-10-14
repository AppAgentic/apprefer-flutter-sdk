import 'dart:convert';

import 'package:apprefer/src/billing/billing_api_client.dart';
import 'package:apprefer/src/billing/billing_engine.dart';
import 'package:apprefer/src/billing/billing_error.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/customer_info.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:apprefer/src/billing/purchase_intents.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
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

Future<void> saveIntents(Harness h, List<Object?> intents) =>
    h.prefs.setString(intentsKey, jsonEncode(intents));

List<Map<String, dynamic>> storedIntents(SharedPreferences prefs) =>
    (jsonDecode(prefs.getString(intentsKey) ?? '[]') as List)
        .cast<Map<String, dynamic>>();

String? sentUser(Harness h) =>
    h.server.bodiesFor(purchases).lastOrNull?['appUserId'] as String?;

StorePurchase errorUpdate(String productId, {String? code, String? message}) =>
    StorePurchase(
      id: '',
      productId: productId,
      store: BillingStore.playStore,
      status: StorePurchaseStatus.error,
      errorCode: code,
      errorMessage: message,
      needsCompletion: false,
    );

void main() {
  group('1. renewal guard on every path', () {
    test(
      'a renewal returned by the active purchase sheet does not consume the supplied intent',
      () async {
        final h = await Harness.create(server: FakeServer()..online());
        await saveIntents(h, [intent('u1')]);
        final engine = restarted(h, appUserId: 'u2');
        final supplied = PurchaseIntent(
          appUserId: 'u1',
          productId: 'pro_yearly',
          accountToken: null,
          startedAt: now,
        );

        // Apple: a later transaction of the chain.
        await engine.process(
          h.store.applePurchase(
            't2',
            'pro_yearly',
            originalTransactionId: 't1',
          ),
          intent: supplied,
        );
        expect(sentUser(h), 'u2', reason: 'the intent is not used for owner');
        expect(storedIntents(h.prefs), hasLength(1), reason: 'not consumed');

        // Google: a ..N renewal order.
        h.store.store = BillingStore.playStore;
        await engine.process(
          h.store.googlePurchase(
            'tok-r',
            'pro_yearly',
            orderId: 'GPA.1234-5678-9012-34567..1',
          ),
          intent: supplied,
        );
        expect(sentUser(h), 'u2');
        expect(storedIntents(h.prefs), hasLength(1));

        // A renewal AppRefer can't verify is archived without the intent.
        await engine.process(
          h.store.applePurchase(
            't3',
            'pro_yearly',
            originalTransactionId: 't1',
            jws: null,
          ),
          intent: supplied,
        );
        expect(storedIntents(h.prefs), hasLength(1));

        // The new purchase the sheet started still finds it.
        await engine.process(
          h.store.applePurchase('t9', 'pro_yearly'),
          intent: supplied,
        );
        expect(sentUser(h), 'u1');
        expect(storedIntents(h.prefs), isEmpty);
      },
    );

    test(
      'a renewal on the open sheet settles it but keeps the intent',
      () async {
        final h = await Harness.create(
          server: FakeServer()..online(),
          appUserId: 'u1',
        );
        // An App Store crossgrade: a new transaction on the same chain.
        h.store.onBuy = (product, _) => h.store.updates.add([
          h.store.applePurchase('t2', product.id, originalTransactionId: 't1'),
        ]);
        final result = await h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        );
        expect(result.outcome, PurchaseOutcome.purchased);
        expect(h.store.completed, contains('t2'));
        expect(sentUser(h), 'u1', reason: 'the initiator, not the intent');
        final stored = storedIntents(h.prefs);
        expect(stored, hasLength(1), reason: 'neither used nor dropped');
        expect(stored.single['appUserId'], 'u1');

        // Owner comes from the initiator even when the intent names another
        // user: the intent is never consulted for a renewal.
        await saveIntents(h, [intent('u7')]);
        h.store.onBuy = (product, _) => h.store.updates.add([
          h.store.applePurchase('t4', product.id, originalTransactionId: 't1'),
        ]);
        await h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        );
        expect(sentUser(h), 'u1');
        expect(
          storedIntents(h.prefs).map((e) => e['appUserId']),
          contains('u7'),
        );
      },
    );
  });

  group('2. intents removed only on definitive store outcomes', () {
    test('the classifier', () {
      for (final definitive in <Object>[
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.userCanceled',
        ),
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.itemUnavailable',
        ),
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.developerError',
        ),
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.featureNotSupported',
        ),
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.billingUnavailable',
        ),
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.itemAlreadyOwned',
        ),
        'ITEM_ALREADY_OWNED',
        PlatformException(code: 'userCancelled', message: 'StoreKitError'),
        PlatformException(code: 'productUnavailable', message: 'PurchaseError'),
        PlatformException(code: 'purchaseNotAllowed', message: 'PurchaseError'),
        PlatformException(code: 'ineligibleForOffer', message: 'PurchaseError'),
        PlatformException(
          code: 'invalidOfferIdentifier',
          message: 'PurchaseError',
        ),
        PlatformException(code: 'invalidOfferPrice', message: 'PurchaseError'),
        PlatformException(
          code: 'invalidOfferSignature',
          message: 'PurchaseError',
        ),
        PlatformException(
          code: 'missingOfferParameters',
          message: 'PurchaseError',
        ),
        PlatformException(code: 'invalidQuantity', message: 'PurchaseError'),
        PlatformException(
          code: 'notAvailableInStorefront',
          message: 'StoreKitError',
        ),
        PlatformException(code: 'notEntitled', message: 'StoreKitError'),
        IAPError(
          source: 'google_play',
          code: 'purchase_error',
          message: 'BillingResponse.itemUnavailable',
        ),
      ]) {
        expect(
          isDefinitiveStoreFailure(definitive),
          isTrue,
          reason: '$definitive',
        );
      }
      for (final ambiguous in <Object?>[
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.serviceUnavailable',
        ),
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.serviceDisconnected',
        ),
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.networkError',
        ),
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.error',
        ),
        errorUpdate(
          'p',
          code: 'purchase_error',
          message: 'BillingResponse.itemNotOwned',
        ),
        errorUpdate('p', code: 'purchase_error', message: ''),
        errorUpdate('p'),
        PlatformException(
          code: 'networkError(Error Domain=NSURLErrorDomain Code=-1009)',
          message: 'StoreKitError',
        ),
        PlatformException(code: 'systemError(x)', message: 'StoreKitError'),
        PlatformException(code: 'unknown', message: 'StoreKitError'),
        PlatformException(code: 'storekit_duplicate_product_object'),
        const AppReferBillingException(
          AppReferBillingErrorCode.store,
          message: 'The store could not start the purchase',
        ),
        Exception('boom'),
        null,
      ]) {
        expect(
          isDefinitiveStoreFailure(ambiguous),
          isFalse,
          reason: '$ambiguous',
        );
      }
    });

    Future<Harness> sheetFailing(void Function(Harness h) onBuy) async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        appUserId: 'u1',
      );
      h.store.store = BillingStore.playStore;
      h.engine.listen();
      onBuy(h);
      await expectLater(
        h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        ),
        throwsA(isA<AppReferBillingException>()),
      );
      return h;
    }

    test('an ambiguous purchase-update error keeps the intent', () async {
      for (final message in [
        'BillingResponse.serviceUnavailable',
        'BillingResponse.networkError',
        'BillingResponse.error',
      ]) {
        final h = await sheetFailing(
          (h) => h.store.onBuy = (product, _) => h.store.updates.add([
            errorUpdate(product.id, code: 'purchase_error', message: message),
          ]),
        );
        expect(storedIntents(h.prefs), hasLength(1), reason: message);
      }
    });

    test('a definitive purchase-update error drops the intent', () async {
      final h = await sheetFailing(
        (h) => h.store.onBuy = (product, _) => h.store.updates.add([
          errorUpdate(
            product.id,
            code: 'purchase_error',
            message: 'BillingResponse.itemUnavailable',
          ),
        ]),
      );
      expect(storedIntents(h.prefs), isEmpty);
    });

    test('an ambiguous purchase-start exception keeps the intent', () async {
      for (final error in <Object>[
        PlatformException(
          code: 'networkError(offline)',
          message: 'StoreKitError',
        ),
        Exception('unknown'),
        const AppReferBillingException(
          AppReferBillingErrorCode.store,
          message: 'The store could not start the purchase',
        ),
      ]) {
        final h = await sheetFailing(
          (h) => h.store.onBuy = (_, _) => throw error,
        );
        expect(storedIntents(h.prefs), hasLength(1), reason: '$error');
      }
    });

    test('a definitive purchase-start exception drops the intent', () async {
      final h = await sheetFailing(
        (h) => h.store.onBuy = (_, _) => throw PlatformException(
          code: 'productUnavailable',
          message: 'PurchaseError',
        ),
      );
      expect(storedIntents(h.prefs), isEmpty);
    });

    test('a user cancel stays definitive', () async {
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

    test(
      'a second purchase start for the same user/product keeps both intents',
      () async {
        final h = await sheetFailing(
          (h) => h.store.onBuy = (_, _) => throw Exception('service timeout'),
        );
        expect(storedIntents(h.prefs), hasLength(1));
        h.time = now.add(const Duration(seconds: 5));
        h.store.onBuy = (product, _) => h.store.updates.add([
          h.store.googlePurchase(
            '',
            product.id,
            status: StorePurchaseStatus.pending,
          ),
        ]);
        final r = await h.engine.purchase(
          FakeProduct('pro_yearly'),
          const StorePurchaseOptions(),
        );
        expect(r.outcome, PurchaseOutcome.pending);
        final stored = storedIntents(h.prefs);
        expect(stored, hasLength(2));
        expect(stored.map((e) => e['appUserId']), ['u1', 'u1']);
        expect(stored.map((e) => e['startedAtMs']), [
          now.millisecondsSinceEpoch,
          now.add(const Duration(seconds: 5)).millisecondsSinceEpoch,
        ]);
      },
    );
  });

  group('3. oldest intent is the earliest startedAt', () {
    test('oldest by startedAt wins even when stored out of order', () async {
      final h = await Harness.create(server: FakeServer()..online());
      await saveIntents(h, [
        intent('u3', ageMs: 1000),
        intent('u4', ageMs: 2000),
        intent('u1', ageMs: 9000),
        intent('u5', ageMs: 9000), // tie: the first stored wins
        intent('u2', ageMs: 5000),
      ]);
      final engine = restarted(h, appUserId: 'u9');
      await engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      expect(sentUser(h), 'u1');
      await engine.process(h.store.applePurchase('t2', 'pro_yearly'));
      expect(sentUser(h), 'u5');
      await engine.process(h.store.applePurchase('t3', 'pro_yearly'));
      expect(sentUser(h), 'u2');
      expect(storedIntents(h.prefs).map((e) => e['appUserId']), ['u3', 'u4']);
    });

    test('a tagged purchase takes the oldest intent with its token', () async {
      final h = await Harness.create(server: FakeServer()..online());
      await saveIntents(h, [
        intent('u3', accountToken: token, ageMs: 1000),
        intent('u1', accountToken: token, ageMs: 5000),
      ]);
      final engine = restarted(h, appUserId: 'u9');
      await engine.process(
        h.store.applePurchase('t1', 'pro_yearly', accountToken: token),
      );
      // The token was issued on another install, so the intent decides.
      expect(sentUser(h), 'u1');
      expect(storedIntents(h.prefs).map((e) => e['appUserId']), ['u3']);
    });
  });

  group('4. partly malformed intents', () {
    test(
      'a partly-malformed intents file keeps parseable entries, quarantines the raw original, sets the marker',
      () async {
        final h = await Harness.create(server: FakeServer()..online());
        final raw = jsonEncode([
          intent('u1', ageMs: 3000),
          {'bad': 1},
          7,
          intent('u2', productId: 'other'),
        ]);
        await h.prefs.setString(intentsKey, raw);
        final engine = restarted(h, appUserId: 'u9');

        await engine.process(h.store.applePurchase('t1', 'pro_yearly'));
        expect(sentUser(h), 'u1', reason: 'a kept intent still matches');
        final quarantined = h.prefs.getKeys().where(
          (k) => k.startsWith('${intentsKey}_quarantine_'),
        );
        expect(h.prefs.getString(quarantined.single), raw);
        expect(h.prefs.getString(lostKey), isNotNull);
        expect(storedIntents(h.prefs).map((e) => e['appUserId']), ['u2']);

        // An untagged purchase with no intent left is held, as on full loss.
        await engine.process(h.store.applePurchase('t2', 'pro_yearly'));
        expect(h.server.bodiesFor(purchases), hasLength(1));
        expect(h.store.completed, isNot(contains('t2')));
      },
    );

    test(
      'a wholly unparseable file keeps nothing, quarantines, sets the marker',
      () async {
        final h = await Harness.create(server: FakeServer()..online());
        await h.prefs.setString(intentsKey, '{"not":"a list"}');
        final store = PurchaseIntentStore(h.prefs, intentsKey, now: () => now);
        expect(await store.read(), isEmpty);
        final quarantined = h.prefs.getKeys().where(
          (k) => k.startsWith('${intentsKey}_quarantine_'),
        );
        expect(h.prefs.getString(quarantined.single), '{"not":"a list"}');
        expect(store.lostMarker()?.lostAt, now);
        expect(storedIntents(h.prefs), isEmpty);
      },
    );
  });
}
