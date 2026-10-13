import 'package:apprefer/apprefer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppReferBilling.resetForTesting();
  });

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
      expect(info.entitlements['premium']?.isActive, isTrue);
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
