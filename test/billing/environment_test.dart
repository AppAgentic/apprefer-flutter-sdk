import 'dart:convert';
import 'package:apprefer/src/billing/billing_api_client.dart';
import 'package:apprefer/src/billing/customer_info.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('scope survives cache, source changes and expiry reevaluation', () {
    final info = AppReferCustomerInfo.fromJson({'appUserId': 'same-user', 'environment': 'sandbox'});
    expect(info.environment, BillingEnvironment.sandbox);
    expect(info.withSource(CustomerInfoSource.cache).environment, BillingEnvironment.sandbox);
    expect(info.reevaluated(DateTime.now()).environment, BillingEnvironment.sandbox);
    expect(AppReferCustomerInfo.fromJson(info.toJson()).environment, BillingEnvironment.sandbox);
    expect(AppReferCustomerInfo.fromJson({'appUserId': 'same-user'}).environment, isNull);
  });
  for (final selected in BillingEnvironment.values) {
    test('transport selects and validates ${selected.name}', () async {
      for (final returned in [selected.name, selected == BillingEnvironment.production ? 'sandbox' : 'production', null]) {
        final api = BillingApiClient(baseUrls: ['https://example.com'], apiKey: () => 'pk_live_a', environment: selected,
          client: MockClient((request) async {
            expect(request.headers['X-AppRefer-Billing-Environment'], selected.name);
            return http.Response(jsonEncode({'appUserId': 'same-user', 'environment': returned}), 200);
          }));
        if (returned == selected.name) {
          final answer = await api.send(const GetCustomer('same-user'));
          expect(answer.info.environment, selected);
        } else {
          await expectLater(api.send(const GetCustomer('same-user')), throwsA(anything));
        }
      }
    });
  }
}
