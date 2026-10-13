import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/customer_info.dart'
    show BillingCustomerResponse;
import 'package:apprefer/src/billing/in_app_purchase_store.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const serverJson = '''
{
  "appUserId": "user_1",
  "entitlements": {
    "premium": {"id": "premium", "isActive": true, "productId": "pro_yearly", "store": "app_store",
      "expiresAtMs": 1790000000000, "willRenew": true, "periodType": "trial", "state": "active",
      "subscriptionKey": "2000000000000001"},
    "lifetime": {"id": "lifetime", "isActive": true, "productId": "pro_life", "store": "play_store",
      "expiresAtMs": null, "willRenew": false, "periodType": "normal", "state": "active",
      "subscriptionKey": "GPA.1"}
  },
  "activeSubscriptions": ["pro_yearly"],
  "requestDateMs": 1760000000000,
  "accountToken": "11111111-2222-4333-8444-555555555555"
}''';

void main() {
  group('CustomerInfo', () {
    test('decodes the server response', () {
      final res = BillingCustomerResponse.fromJson(jsonDecode(serverJson));
      final info = res.info;
      expect(res.accountToken, token);
      expect(info.appUserId, 'user_1');
      expect(info.source, CustomerInfoSource.server);
      expect(info.requestDate, now);
      expect(info.activeSubscriptions, {'pro_yearly'});
      final premium = info.entitlements['premium']!;
      expect(premium.isActive, isTrue);
      expect(premium.productIdentifier, 'pro_yearly');
      expect(premium.store, BillingStore.appStore);
      expect(
        premium.expirationDate,
        DateTime.fromMillisecondsSinceEpoch(1790000000000),
      );
      expect(premium.willRenew, isTrue);
      expect(premium.periodType, BillingPeriodType.trial);
      expect(premium.state, BillingSubscriptionState.active);
      expect(info.entitlements['lifetime']!.expirationDate, isNull);
      expect(info.entitlements['lifetime']!.store, BillingStore.playStore);
      expect(
        info.entitlements.active.keys,
        containsAll(['premium', 'lifetime']),
      );
      expect(info.hasActiveEntitlement, isTrue);
    });

    test('unknown enum values and missing id do not fail', () {
      final info = AppReferCustomerInfo.fromJson({
        'appUserId': 'u',
        'entitlements': {
          'vip': {
            'isActive': true,
            'store': 'huawei',
            'periodType': 'weird',
            'state': 'odd',
          },
        },
      });
      final vip = info.entitlements['vip']!;
      expect(vip.identifier, 'vip');
      expect(vip.store, BillingStore.unknown);
      expect(vip.periodType, BillingPeriodType.unknown);
      expect(vip.state, BillingSubscriptionState.unknown);
    });

    test('encode/decode round trip keeps source', () {
      final info = BillingCustomerResponse.fromJson(
        jsonDecode(serverJson),
      ).info.withSource(CustomerInfoSource.localFallback);
      final back = AppReferCustomerInfo.tryDecode(jsonEncode(info.toJson()))!;
      expect(back.source, CustomerInfoSource.localFallback);
      expect(back.hasSameContent(info), isTrue);
      expect(back.requestDate, info.requestDate);
    });

    test('reevaluated expires a stale cache but keeps grace period', () {
      final info = AppReferCustomerInfo.fromJson({
        'appUserId': 'u',
        'entitlements': {
          'a': {
            'id': 'a',
            'isActive': true,
            'productId': 'p1',
            'expiresAtMs': 1000,
            'state': 'active',
          },
          'b': {
            'id': 'b',
            'isActive': true,
            'productId': 'p2',
            'expiresAtMs': 1000,
            'state': 'in_grace_period',
          },
          'c': {
            'id': 'c',
            'isActive': true,
            'productId': 'p3',
            'expiresAtMs': null,
            'state': 'active',
          },
        },
        'activeSubscriptions': ['p1', 'p2'],
      });
      final re = info.reevaluated(now);
      expect(re.source, CustomerInfoSource.cache);
      expect(re.entitlements['a']!.isActive, isFalse);
      expect(re.entitlements['a']!.state, BillingSubscriptionState.expired);
      expect(re.entitlements['b']!.isActive, isTrue);
      expect(re.entitlements['c']!.isActive, isTrue);
      expect(re.activeSubscriptions, {'p2'});
    });

    test('public typedefs resolve to the same types', () {
      final CustomerInfo info = AppReferCustomerInfo.fromJson({
        'appUserId': 'u',
      });
      expect(info, isA<AppReferCustomerInfo>());
      const EntitlementInfo? none = null;
      expect(none, isNull);
    });
  });

  group('BillingStorage', () {
    late BillingStorage storage;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      storage = BillingStorage(await SharedPreferences.getInstance());
    });

    test('anonymous id format matches the server', () {
      final id = storage.anonymousId();
      expect(
        RegExp(
          r'^\$ARAnon:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
        ).hasMatch(id),
        isTrue,
        reason: id,
      );
    });

    test('anonymous id is minted once and persisted', () async {
      final id = storage.anonymousId();
      expect(storage.anonymousId(), id);
      final again = BillingStorage(await SharedPreferences.getInstance());
      expect(again.anonymousId(), id);
      expect(storage.resetAnonymousId(), isNot(id));
    });

    test('current app user id prefers the logged-in user', () {
      final anon = storage.anonymousId();
      expect(storage.currentAppUserId, anon);
      storage.loggedInAppUserId = 'u1';
      expect(storage.currentAppUserId, 'u1');
      storage.loggedInAppUserId = null;
      expect(storage.currentAppUserId, anon);
    });

    test('account tokens are per user and validated', () {
      storage.setAccountToken(token, 'u1');
      storage.setAccountToken('not-a-uuid', 'u2');
      expect(storage.accountToken('u1'), token);
      expect(storage.accountToken('u2'), isNull);
    });

    test('pending attributes clear only what was sent', () {
      storage.mergePendingAttributes({
        r'$email': 'a@b.com',
        r'$displayName': 'A',
      });
      final sent = storage.pendingAttributes;
      storage.mergePendingAttributes({r'$email': 'new@b.com'});
      storage.clearSentAttributes(sent);
      expect(storage.pendingAttributes, {r'$email': 'new@b.com'});
    });

    test('learns entitlements from server answers', () {
      storage.learnEntitlements(
        AppReferCustomerInfo.fromJson(
          customerJson('u', active: {'premium': 'pro_yearly'}),
        ),
      );
      storage.learnEntitlements(
        AppReferCustomerInfo.fromJson(
          customerJson('u', active: {'gold': 'pro_yearly'}),
        ),
      );
      expect(storage.learnedEntitlements, {
        'pro_yearly': ['gold', 'premium'],
      });
    });

    test('pending identify and cached customer info persist', () {
      storage.pendingIdentify = (anonymousId: r'$ARAnon:A', appUserId: 'u1');
      expect(storage.pendingIdentify?.appUserId, 'u1');
      storage.pendingIdentify = null;
      expect(storage.pendingIdentify, isNull);
      storage.setCachedCustomerInfo(
        AppReferCustomerInfo.fromJson(
          customerJson('u1', active: {'premium': 'p'}),
        ),
      );
      expect(
        storage.cachedCustomerInfo()?.entitlements['premium']?.isActive,
        isTrue,
      );
    });
  });

  group('PendingPurchaseQueue', () {
    PendingPurchase entry(String id, {int attempts = 1, DateTime? at}) =>
        PendingPurchase(
          transactionId: id,
          productId: 'pro_yearly',
          appUserId: 'u1',
          appreferId: 'device-1',
          storeFields: const {'store': 'app_store', 'signedTransaction': 'jws'},
          enqueuedAt: at ?? now,
          attempts: attempts,
        );

    test('persists across launches', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await PendingPurchaseQueue(prefs, 'q').add(entry('t1'));
      final reloaded = PendingPurchaseQueue(prefs, 'q');
      expect(reloaded.entries.single.transactionId, 't1');
      expect(reloaded.entries.single.storeFields['signedTransaction'], 'jws');
      expect(reloaded.containsUser('u1'), isTrue);
    });

    test('dedupes by transaction and tracks attempts', () async {
      SharedPreferences.setMockInitialValues({});
      final q = PendingPurchaseQueue(
        await SharedPreferences.getInstance(),
        'q',
      );
      await q.add(entry('t1'));
      await q.add(entry('t1'));
      q.recordAttempt('t1');
      expect(q.entries.single.attempts, 2);
      q.remove('t1');
      expect(q.isEmpty, isTrue);
    });

    test('prunes too many attempts and too old', () async {
      SharedPreferences.setMockInitialValues({});
      final q = PendingPurchaseQueue(
        await SharedPreferences.getInstance(),
        'q',
      );
      await q.add(entry('ok'));
      await q.add(entry('tired', attempts: PendingPurchaseQueue.maxAttempts));
      await q.add(entry('old', at: now.subtract(const Duration(days: 91))));
      final dropped = q.prune(now);
      expect(
        dropped.map((e) => e.transactionId),
        unorderedEquals(['tired', 'old']),
      );
      expect(q.entries.map((e) => e.transactionId), ['ok']);
    });

    test('corrupt data starts empty', () async {
      SharedPreferences.setMockInitialValues({'q': '{not json'});
      final q = PendingPurchaseQueue(
        await SharedPreferences.getInstance(),
        'q',
      );
      expect(q.isEmpty, isTrue);
    });
  });

  group('LocalEntitlements', () {
    StoreEntitlement purchase(
      String productId, {
      StoreProductKind kind = StoreProductKind.autoRenewable,
      DateTime? expires,
      DateTime? revoked,
      bool upgraded = false,
    }) => StoreEntitlement(
      productId: productId,
      originalId: 'o_$productId',
      kind: kind,
      store: BillingStore.appStore,
      expirationDate: expires,
      revocationDate: revoked,
      isUpgraded: upgraded,
    );

    final later = now.add(const Duration(days: 2));

    test('active subscription unlocks mapped entitlements', () {
      final r = LocalEntitlements.compute(
        [purchase('pro', expires: later)],
        configured: {
          'pro': ['premium', 'ai'],
        },
        learned: const {},
        now: now,
      );
      expect(r.entitlements.keys, unorderedEquals(['premium', 'ai']));
      expect(r.entitlements['premium']!.expirationDate, later);
      expect(r.activeSubscriptions, {'pro'});
    });

    test('expired, revoked, upgraded and consumables grant nothing', () {
      final r = LocalEntitlements.compute(
        [
          purchase('a', expires: now.subtract(const Duration(seconds: 1))),
          purchase('b', expires: later, revoked: now),
          purchase('c', expires: later, upgraded: true),
          purchase('d', kind: StoreProductKind.consumable),
        ],
        configured: const {},
        learned: const {},
        now: now,
      );
      expect(r.entitlements, isEmpty);
      expect(r.activeSubscriptions, isEmpty);
    });

    test('lifetime purchase unlocks without expiry', () {
      final r = LocalEntitlements.compute(
        [purchase('life', kind: StoreProductKind.nonConsumable)],
        configured: const {},
        learned: const {},
        now: now,
      );
      expect(r.entitlements['premium']!.expirationDate, isNull);
      expect(r.activeSubscriptions, isEmpty);
    });

    test('mapping precedence: configured, then learned, then default', () {
      List<String> ids(String p) => LocalEntitlements.entitlementIds(
        p,
        configured: {
          'a': ['cfg'],
        },
        learned: {
          'a': ['lrn'],
          'b': ['lrn'],
        },
        defaultEntitlement: 'dflt',
      );
      expect(ids('a'), ['cfg']);
      expect(ids('b'), ['lrn']);
      expect(ids('c'), ['dflt']);
      expect(
        LocalEntitlements.entitlementIds(
          'c',
          configured: const {},
          learned: const {},
        ),
        ['premium'],
      );
    });

    test('later expiry wins within one entitlement', () {
      final far = now.add(const Duration(days: 300));
      final r = LocalEntitlements.compute(
        [purchase('m', expires: later), purchase('y', expires: far)],
        configured: const {},
        learned: const {},
        now: now,
      );
      expect(r.entitlements['premium']!.productIdentifier, 'y');
    });

    test(
      'merge: local active overrides cached inactive; keeps unknown cached ones',
      () {
        final cached = AppReferCustomerInfo.fromJson({
          'appUserId': 'u',
          'entitlements': {
            'premium': {
              'id': 'premium',
              'isActive': false,
              'productId': 'pro',
              'expiresAtMs': 1,
            },
            'web': {
              'id': 'web',
              'isActive': true,
              'productId': 'stripe_plan',
              'store': 'stripe',
            },
          },
        });
        final local = LocalEntitlements.compute(
          [purchase('pro', expires: later)],
          configured: const {},
          learned: const {},
          now: now,
        );
        final merged = LocalEntitlements.merge(
          server: cached,
          local: local,
          appUserId: 'u',
          now: now,
          source: CustomerInfoSource.localFallback,
        );
        expect(merged.entitlements['premium']!.isActive, isTrue);
        expect(merged.entitlements['web']!.isActive, isTrue);
        expect(merged.source, CustomerInfoSource.localFallback);
      },
    );
  });

  group('store mapping', () {
    test('StorePurchase.storeFields per store', () {
      final store = FakeStore();
      expect(store.applePurchase('1', 'p').storeFields, {
        'store': 'app_store',
        'signedTransaction': 'jws.payload.sig',
      });
      expect(store.applePurchase('1', 'p', jws: '').storeFields, isNull);
      expect(
        store
            .googlePurchase('tok', 'coins', kind: StoreProductKind.consumable)
            .storeFields,
        {
          'store': 'play_store',
          'purchaseToken': 'tok',
          'productId': 'coins',
          'productType': 'consumable',
        },
      );
      expect(
        store
            .googlePurchase('tok', 'life', kind: StoreProductKind.nonConsumable)
            .storeFields!['productType'],
        'non_consumable',
      );
      expect(
        store.googlePurchase('tok', 'sub').storeFields!['productType'],
        'subscription',
      );
    });

    test('parses StoreKit 2 jsonRepresentation', () {
      final json = AppleTransactionJson.parse(
        jsonEncode({
          'transactionId': '2000000000000002',
          'originalTransactionId': '2000000000000001',
          'productId': 'pro_yearly',
          'type': 'Auto-Renewable Subscription',
          'expiresDate': 1790000000000,
          'offerType': 1,
          'offerDiscountType': 'FREE_TRIAL',
          'isUpgraded': false,
        }),
      )!;
      expect(json.kind, StoreProductKind.autoRenewable);
      expect(json.periodType, BillingPeriodType.trial);
      expect(
        json.expiresDate,
        DateTime.fromMillisecondsSinceEpoch(1790000000000),
      );
      final ent = json.toEntitlement(
        fallbackProductId: 'x',
        fallbackOriginalId: 'y',
      );
      expect(ent.originalId, '2000000000000001');
      expect(ent.productId, 'pro_yearly');

      final revoked = AppleTransactionJson.parse(
        jsonEncode({
          'type': 'Non-Consumable',
          'revocationDate': 1750000000000,
          'offerType': 2,
        }),
      )!;
      expect(revoked.kind, StoreProductKind.nonConsumable);
      expect(revoked.revocationDate, isNotNull);
      expect(revoked.periodType, BillingPeriodType.promotional);
      expect(
        AppleTransactionJson.parse('{"type":"Consumable"}')!.kind,
        StoreProductKind.consumable,
      );
      expect(AppleTransactionJson.parse('nope'), isNull);
      expect(AppleTransactionJson.parse(''), isNull);
    });

    test('products keep the requested order, offers in store order', () {
      final sorted = sortProducts(
        [
          FakeProduct('b'),
          FakeProduct('x'),
          FakeProduct('a'),
          FakeProduct('b'),
        ],
        ['a', 'b'],
      );
      expect(sorted.map((p) => p.id), ['a', 'b', 'b', 'x']);
    });
  });
}
