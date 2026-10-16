import 'dart:convert';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

Map<String, dynamic> response() => {
  'currentOfferingId': 'default',
  'offerings': [
    {
      'id': 'default',
      'metadata': {
        'nested': [true, null],
      },
      'packages': [
        {'id': r'$rc_annual', 'packageType': 'annual', 'productId': 'year'},
        {'id': 'future', 'packageType': 'future', 'productId': 'missing'},
        {'id': 'no-platform'},
      ],
    },
  ],
  'placements': {'onboarding': 'default', 'settings': null},
  'context': {'experimentId': 'exp', 'variantId': 'b'},
  'requestDateMs': 1700000000000,
  'future': true,
};
void main() {
  test(
    'product lookup failure preserves catalogue and omits packages',
    () async {
      final h = await Harness.create(
        server: FakeServer((r) => (200, response())),
        store: FailingProductStore(),
      );
      final first = await h.engine.offerings();
      expect(first.current!.identifier, 'default');
      expect(first.current!.availablePackages, isEmpty);
      h.server.offline();
      final cached = await h.engine.offerings(FetchPolicy.fetchCurrent);
      expect(cached.current!.identifier, 'default');
      expect(cached.current!.availablePackages, isEmpty);
      await h.engine.dispose();
    },
  );
  test('foreground only refreshes offerings after cache exists', () async {
    final server = FakeServer();
    server.online();
    final h = await Harness.create(server: server);
    await h.engine.resume();
    expect(server.bodiesFor('/api/billing/v1/offerings'), isEmpty);
    server.handler = (r) => r.url.path.endsWith('/offerings')
        ? (200, response())
        : (200, customerJson('alice'));
    await h.engine.offerings();
    h.time = h.time.add(const Duration(minutes: 6));
    await h.engine.resume();
    await Future<void>.delayed(Duration.zero);
    expect(server.bodiesFor('/api/billing/v1/offerings').length, 2);
    await h.engine.dispose();
  });
  test('unreadable identity throws storage without an API call', () async {
    late FlakyPrefs prefs;
    final h = await Harness.create(wrapPrefs: (p) => prefs = FlakyPrefs(p));
    prefs.unreadable.add('apprefer_billing_app_user_id');
    await expectLater(
      h.engine.offerings(),
      throwsA(
        isA<AppReferBillingException>().having(
          (e) => e.code,
          'code',
          AppReferBillingErrorCode.storage,
        ),
      ),
    );
    expect(h.server.requests, isEmpty);
    await h.engine.dispose();
  });
  test(
    'fetchCurrent bypasses running cache policy and is shared with other callers',
    () async {
      final h = await Harness.create(
        server: FakeServer((r) => (200, response())),
      );
      await h.engine.offerings();
      final cached = h.engine.offerings();
      final current = h.engine.offerings(FetchPolicy.fetchCurrent);
      expect(identical(cached, current), isFalse);
      expect(identical(h.engine.offerings(), current), isTrue);
      await Future.wait([cached, current]);
      expect(h.server.requests.length, 2);
      await h.engine.dispose();
    },
  );
  test(
    'Play fallback prefers base plan for bare explicit and unmatched-period packages',
    () async {
      final details = ProductDetailsWrapper(
        productId: 'sub',
        productType: ProductType.subs,
        title: 'Sub',
        name: 'Sub',
        description: '',
        subscriptionOfferDetails: [
          for (final trial in [true, false])
            SubscriptionOfferDetailsWrapper(
              basePlanId: 'month',
              offerId: trial ? 'trial' : null,
              offerTags: [],
              offerIdToken: trial ? 'trial-token' : 'base-token',
              pricingPhases: [
                const PricingPhaseWrapper(
                  billingCycleCount: 0,
                  billingPeriod: 'P1M',
                  formattedPrice: r'$1',
                  priceAmountMicros: 1000000,
                  priceCurrencyCode: 'USD',
                  recurrenceMode: RecurrenceMode.infiniteRecurring,
                ),
              ],
            ),
        ],
      );
      final result = await resolveOfferings({
        'currentOfferingId': 'default',
        'offerings': [
          {
            'id': 'default',
            'packages': [
              {'id': 'custom', 'productId': 'sub'},
              {'id': 'explicit', 'productId': 'sub:month'},
              {'id': r'$ar_annual', 'productId': 'sub'},
              {'id': 'missing', 'productId': 'sub:missing'},
            ],
          },
        ],
      }, (_) async => GooglePlayProductDetails.fromProductDetails(details));
      expect(result.current!.availablePackages.map((p) => p.offerToken), [
        'base-token',
        'base-token',
        'base-token',
      ]);
    },
  );

  test(
    'response parsing, missing products, aliases and placement fallback',
    () async {
      var batches = 0;
      final offerings = await resolveOfferings(response(), (ids) async {
        batches++;
        expect(ids, ['year', 'missing']);
        return [FakeProduct('year')];
      });
      expect(batches, 1);
      expect(offerings.current!.availablePackages.length, 1);
      expect(packageType('future', 'future'), PackageType.custom);
      expect(offerings.currentOffering('unknown')!.identifier, 'default');
      expect(offerings.currentOffering('settings'), isNull);
      expect(
        offerings
            .currentOffering('onboarding')!
            .annual!
            .presentedOfferingContext
            .placementId,
        'onboarding',
      );
      expect(
        offerings.current!.annual!.presentedOfferingContext.placementId,
        isNull,
      );
    },
  );
  test('in-flight sharing, fresh cache and disk fallback', () async {
    final h = await Harness.create(
      server: FakeServer((r) => (200, response())),
      appUserId: 'alice',
    );
    final a = h.engine.offerings();
    final b = h.engine.offerings();
    expect(identical(a, b), isTrue);
    await Future.wait([a, b]);
    await h.engine.offerings();
    expect(h.server.requests.length, 1);
    h.time = h.time.add(const Duration(minutes: 6));
    h.server.offline();
    final cached = await h.engine.offerings();
    expect(cached.current!.annual!.storeProduct.id, 'year');
    expect((jsonDecode(h.server.requests.last.body) as Map)['known'], {
      'experimentId': 'exp',
      'variantId': 'b',
    });
    final restarted = h.rebuild();
    expect(
      (await restarted.offerings(FetchPolicy.fetchCurrent)).current!.identifier,
      'default',
    );
    await h.engine.dispose();
    await restarted.dispose();
  });
  test('no cache throws SDK error', () async {
    final h = await Harness.create();
    await expectLater(
      h.engine.offerings(),
      throwsA(isA<AppReferBillingException>()),
    );
    await h.engine.dispose();
  });
  test(
    'purchase placement context and bucket sent; retry queue persists them',
    () async {
      final server = FakeServer(
        (r) => r.url.path.endsWith('/offerings')
            ? (200, response())
            : (
                200,
                customerJson(
                  (jsonDecode(r.body) as Map)['appUserId'] as String,
                ),
              ),
      );
      final h = await Harness.create(server: server);
      final offerings = await h.engine.offerings();
      final bucket = await h.storage.offeringsBucketId();
      h.engine.listen();
      h.store.onBuy = (p, options) {
        h.store.updates.add([h.store.applePurchase('tx', p.id)]);
      };
      await h.engine.purchasePackage(
        offerings.currentOffering('onboarding')!.annual!,
      );
      final body = server.bodiesFor('/api/billing/v1/purchases').last;
      expect(body['bucketId'], bucket);
      expect(
        (body['presentedOfferingContext'] as Map)['placementId'],
        'onboarding',
      );
      final context = offerings
          .currentOffering('onboarding')!
          .annual!
          .presentedOfferingContext;
      await h.queue.add(
        PendingPurchase(
          transactionId: 'queued',
          productId: 'year',
          appUserId: 'alice',
          appreferId: null,
          storeFields: {'store': 'app_store', 'signedTransaction': 'jws'},
          enqueuedAt: now,
          presentedOfferingContext: context,
          bucketId: bucket,
        ),
      );
      final reloaded = PendingPurchaseQueue(
        h.prefs,
        'apprefer_billing_pending_purchases',
      );
      expect(
        reloaded.entries.last.presentedOfferingContext!.placementId,
        'onboarding',
      );
      await h.engine.dispose();
    },
  );
  test('empty entitlement mappings unlock nothing', () {
    expect(
      LocalEntitlements.entitlementIds(
        'p',
        configured: {'p': []},
        learned: {
          'p': ['other'],
        },
      ),
      isEmpty,
    );
    expect(
      LocalEntitlements.entitlementIds('p', configured: {}, learned: {'p': []}),
      isEmpty,
    );
    expect(LocalEntitlements.entitlementIds('p', configured: {}, learned: {}), [
      'premium',
    ]);
  });
}

class FailingProductStore extends FakeStore {
  @override
  Future<List<ProductDetails>> products(List<String> ids) async =>
      throw StateError('Play disconnected');
}
