import 'package:apprefer/apprefer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';
import 'package:apprefer/src/services/registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppReferBilling.resetForTesting();
  });

  for (final row in [
    ('pk_live_a', null, BillingEnvironment.sandbox, BillingEnvironment.sandbox),
    (
      'pk_live_a',
      BillingEnvironment.production,
      BillingEnvironment.sandbox,
      BillingEnvironment.production,
    ),
    (
      'pk_test_a',
      null,
      BillingEnvironment.production,
      BillingEnvironment.sandbox,
    ),
    ('pk_live_a', null, null, BillingEnvironment.production),
  ]) {
    test('verified context matrix ' + row.toString(), () async {
      final server = FakeServer()..online();
      await AppReferBilling.configureForTesting(
        apiKey: row.$1,
        environment: row.$2,
        appUserId: 'review-user',
        store: _ContextStore(row.$3),
        httpClient: server.client,
      );
      final info = await AppReferBilling.customerInfo(
        fetchPolicy: FetchPolicy.fetchCurrent,
      );
      expect(info.environment, row.$4);
      expect(
        server.requests.every(
          (r) => r.headers['X-AppRefer-Billing-Environment'] == row.$4.name,
        ),
        isTrue,
      );
    });
  }

  test(
    'calls before configure throw notConfigured; customerInfo never throws',
    () async {
      AppReferBilling.unconfiguredStore = () => FakeStore()
        ..entitlements = [
          activeSub('pro_yearly', left: const Duration(days: 36500)),
        ];
      await expectLater(
        AppReferBilling.logIn('u1'),
        throwsA(
          isA<AppReferBillingException>().having(
            (e) => e.code,
            'code',
            AppReferBillingErrorCode.notConfigured,
          ),
        ),
      );
      final info = await AppReferBilling.customerInfo();
      expect(info.source, CustomerInfoSource.localFallback);
      expect(info.entitlements.active, isEmpty);
      expect(await AppReferBilling.appUserId, '');
      expect(await AppReferBilling.isAnonymous, isTrue);
    },
  );

  test('configure, customerInfo, stream replay and listener', () async {
    final server = FakeServer()..online(active: {'premium': 'pro_yearly'});
    await AppReferBilling.configureForTesting(
      store: FakeStore(),
      httpClient: server.client,
      now: () => now,
    );
    expect(AppReferBilling.isConfigured, isTrue);

    final heard = <CustomerInfo>[];
    void listener(CustomerInfo info) => heard.add(info);
    AppReferBilling.addCustomerInfoUpdateListener(listener);

    final info = await AppReferBilling.customerInfo(
      fetchPolicy: FetchPolicy.fetchCurrent,
    );
    expect(info.entitlements['premium']?.isActive, isTrue);
    expect(await AppReferBilling.appUserId, startsWith(r'$ARAnon:'));

    final first = await AppReferBilling.customerInfoStream.first;
    expect(first.entitlements['premium']?.isActive, isTrue);

    await AppReferBilling.logIn('user_1');
    expect(heard.last.appUserId, 'user_1');
    AppReferBilling.removeCustomerInfoUpdateListener(listener);

    await AppReferBilling.setEmail('a@b.com');
    await AppReferBilling.customerInfo(fetchPolicy: FetchPolicy.fetchCurrent);
    expect(server.bodiesFor('/api/billing/v1/customers').last['attributes'], {
      r'$email': 'a@b.com',
    });
  });

  test(
    'stream replay validates the current registered-key environment',
    () async {
      AppReferRegistry.apiKey = 'pk_test_registered';
      final server = FakeServer()..online(active: {'premium': 'pro_yearly'});
      await AppReferBilling.configureForTesting(
        apiKey: null,
        store: FakeStore(),
        httpClient: server.client,
      );
      final sandbox = await AppReferBilling.customerInfo(
        fetchPolicy: FetchPolicy.fetchCurrent,
      );
      expect(sandbox.environment, BillingEnvironment.sandbox);
      AppReferRegistry.apiKey = 'pk_live_registered';
      final next = AppReferBilling.customerInfoStream.first;
      await AppReferBilling.customerInfo(fetchPolicy: FetchPolicy.fetchCurrent);
      expect((await next).environment, BillingEnvironment.production);
      AppReferRegistry.apiKey = null;
    },
  );

  test(
    'registered test to live key retains verified sandbox context',
    () async {
      AppReferRegistry.apiKey = 'pk_test_a';
      final server = FakeServer()..online();
      await AppReferBilling.configureForTesting(
        apiKey: null,
        store: _ContextStore(BillingEnvironment.sandbox),
        httpClient: server.client,
      );
      AppReferRegistry.apiKey = 'pk_live_a';
      final info = await AppReferBilling.customerInfo(
        fetchPolicy: FetchPolicy.fetchCurrent,
      );
      expect(info.environment, BillingEnvironment.sandbox);
      AppReferRegistry.apiKey = null;
    },
  );

  test('products and purchase go through the store', () async {
    final server = FakeServer()..online(active: {'premium': 'pro_yearly'});
    final store = FakeStore();
    store.onBuy = (product, _) =>
        store.updates.add([store.applePurchase('t1', product.id)]);
    await AppReferBilling.configureForTesting(
      store: store,
      httpClient: server.client,
    );

    final products = await AppReferBilling.products([
      'pro_monthly',
      'pro_yearly',
    ]);
    expect(products.map((p) => p.id), ['pro_monthly', 'pro_yearly']);
    final result = await AppReferBilling.purchase(products[1]);
    expect(result.outcome, PurchaseOutcome.purchased);
    expect(result.customerInfo.entitlements['premium']?.isActive, isTrue);
    expect(store.bought.single.$2.accountToken, token);
    expect(store.completed, ['t1']);
  });
}

class _ContextStore extends FakeStore {
  final BillingEnvironment? environment;
  _ContextStore(this.environment);
  @override
  Future<BillingEnvironment?> storeEnvironment() async => environment;
}
