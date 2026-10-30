import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'outage grants only verified local scope and rejects unknown scope',
    () async {
      var scope = BillingEnvironment.production;
      final h = await Harness.create(
        environment: () => scope,
        entitlementsByProduct: {
          'prod': ['premium'],
          'test': ['premium'],
          'unknown': ['premium'],
        },
      );
      h.store.entitlements = [
        for (final entry in [
          ('prod', BillingEnvironment.production),
          ('test', BillingEnvironment.sandbox),
          ('unknown', null),
        ])
          StoreEntitlement(
            productId: entry.$1,
            originalId: entry.$1,
            kind: StoreProductKind.autoRenewable,
            store: BillingStore.appStore,
            environment: entry.$2,
            expirationDate: now.add(const Duration(days: 1)),
          ),
      ];
      expect((await h.engine.localFallback()).activeSubscriptions, {'prod'});
      scope = BillingEnvironment.sandbox;
      expect((await h.engine.localFallback()).activeSubscriptions, {'test'});
      h.engine.dispose();
    },
  );
  test(
    'old Google proof is classified and retained without blocking valid work or expiring',
    () async {
      var scope = BillingEnvironment.production;
      final server = FakeServer()..online();
      final h = await Harness.create(
        server: server,
        appUserId: 'same-user',
        environment: () => scope,
        apiKey: 'pk_live_a',
      );
      for (final token in ['legacy', 'prod']) {
        await h.queue.add(
          PendingPurchase(
            transactionId: token,
            productId: token,
            appUserId: 'same-user',
            appreferId: null,
            storeFields: {
              'store': 'play_store',
              'purchaseToken': token,
              'productId': token,
              'productType': 'subscription',
            },
            enqueuedAt: DateTime.fromMillisecondsSinceEpoch(0),
            attempts: 999,
            migrationOnly: true,
          ),
        );
      }
      server.handler = (r) {
        final body = jsonDecode(r.body) as Map;
        if (body['purchaseToken'] == 'legacy' &&
            scope == BillingEnvironment.production) {
          return (
            400,
            {'code': 'billing_environment_mismatch', 'environment': 'sandbox'},
          );
        }
        return (200, {...customerJson('same-user'), 'environment': scope.name});
      };
      await h.engine.drainQueue();
      expect(h.queue.entries.map((e) => e.transactionId), ['legacy']);
      expect(h.queue.entries.single.attempts, 999);
      expect(
        h.storage.purchaseEnvironment({
          'store': 'play_store',
          'purchaseToken': 'legacy',
        }),
        BillingEnvironment.sandbox,
      );
      scope = BillingEnvironment.sandbox;
      await h.engine.drainQueue();
      expect(h.queue.entries, isEmpty);
      h.engine.dispose();
    },
  );
}
