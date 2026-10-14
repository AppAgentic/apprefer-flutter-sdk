import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/in_app_purchase_store.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'open purchases skip import and old markers never suppress normal completion',
    () async {
      final h = await Harness.create(appUserId: 'alice');
      h.server.online();
      final p = h.store.applePurchase('open', 'pro_yearly');
      h.store.restoreList = [p];
      h.store.unfinishedList = [p];
      await h.storage.markMigrationPurchase('appStore:open');
      await h.engine.migrationSync();
      expect(h.server.bodiesFor('/api/billing/v1/purchases'), isEmpty);
      await h.engine.retryUnfinished();
      expect(h.server.bodiesFor('/api/billing/v1/purchases'), hasLength(1));
      expect(h.store.completed, ['open']);
      await h.engine.dispose();
    },
  );

  test(
    'only untagged and current user tags import, never foreign or unknown',
    () async {
      final h = await Harness.create(appUserId: 'alice');
      h.server.online();
      h.storage.setAccountToken(
        '11111111-2222-4333-8444-555555555555',
        'alice',
      );
      h.storage.setAccountToken('22222222-3333-4444-8555-666666666666', 'bob');
      h.store.restoreList = [
        h.store.applePurchase(
          'untagged',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
        ),
        h.store.applePurchase(
          '11111111-2222-4333-8444-555555555555',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
          accountToken: '11111111-2222-4333-8444-555555555555',
        ),
        h.store.applePurchase(
          '22222222-3333-4444-8555-666666666666',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
          accountToken: '22222222-3333-4444-8555-666666666666',
        ),
        h.store.applePurchase(
          'unknown',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
          accountToken: 'unknown',
        ),
      ];
      await h.engine.migrationSync();
      expect(h.server.bodiesFor('/api/billing/v1/purchases'), hasLength(2));
      await h.engine.dispose();
    },
  );

  test(
    'partial progress survives a new engine and retries only leftovers',
    () async {
      final h = await Harness.create(appUserId: 'alice');
      h.server.online();
      h.store.restoreList = [
        h.store.applePurchase(
          'good',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
        ),
        h.store.applePurchase(
          'bad',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
          jws: null,
        ),
      ];
      await h.engine.migrationSync();
      expect(h.storage.migrationSynced('alice'), isFalse);
      final second = h.rebuild();
      await second.migrationSync();
      expect(h.server.bodiesFor('/api/billing/v1/purchases'), hasLength(1));
      h.store.restoreList[1] = h.store.applePurchase(
        'bad',
        'pro_yearly',
        status: StorePurchaseStatus.restored,
      );
      await second.migrationSync();
      expect(h.server.bodiesFor('/api/billing/v1/purchases'), hasLength(2));
      expect(h.storage.migrationSynced('alice'), isTrue);
      await second.dispose();
      await h.engine.dispose();
    },
  );

  test('stale explicit user and switch during enumeration abort', () async {
    final h = await Harness.create(appUserId: 'alice');
    h.server.online();
    h.store.restoreList = [
      h.store.applePurchase(
        'legacy',
        'pro_yearly',
        status: StorePurchaseStatus.restored,
      ),
    ];
    var queries = 0;
    h.store.onMigrationQuery = () async {
      queries++;
      h.storage.loggedInAppUserId = 'bob';
    };
    await h.engine.migrationSync('bob');
    expect(queries, 0);
    await h.engine.migrationSync('alice');
    expect(h.server.bodiesFor('/api/billing/v1/purchases'), isEmpty);
    expect(h.storage.migrationSynced('alice'), isFalse);
    await h.engine.dispose();
  });

  test('rejected import exposes real id and restore sends it once', () async {
    final h = await Harness.create(appUserId: 'alice');
    h.store.restoreList = [
      h.store.applePurchase(
        'legacy',
        'pro_yearly',
        status: StorePurchaseStatus.restored,
      ),
    ];
    h.server.status(422);
    await h.engine.migrationSync();
    final rejected = h.engine.rejectedPurchases();
    expect(rejected.single.transactionId, 'legacy');
    expect(rejected.single.migrationOnly, isTrue);
    h.server.online();
    final before = h.server.bodiesFor('/api/billing/v1/purchases').length;
    await h.engine.restore();
    expect(h.server.bodiesFor('/api/billing/v1/purchases').length - before, 1);
    expect(h.engine.rejectedPurchases(), isEmpty);
    await h.engine.dispose();
  });

  test(
    'start fetches first and returns while import enumeration waits',
    () async {
      final h = await Harness.create(appUserId: 'alice');
      h.server.online();
      final gate = Completer<void>();
      var reached = false;
      h.store.onMigrationQuery = () async {
        reached = true;
        expect(
          h.server.requests.any((r) => r.url.path.contains('/customers')),
          isTrue,
        );
        await gate.future;
      };
      await h.engine.start();
      await Future<void>.delayed(Duration.zero);
      expect(reached, isTrue);
      gate.complete();
      await Future<void>.delayed(Duration.zero);
      await h.engine.dispose();
    },
  );

  test(
    'malformed StoreKit item leaves a retryable leftover while valid siblings import; excludes revoked upgraded expired',
    () {
      Map<String, Object?> item(String id, Map<String, Object?> json) => {
        'id': id,
        'productId': 'pro_yearly',
        'originalId': id,
        'json': jsonEncode({'type': 'Auto-Renewable Subscription', ...json}),
        'signedTransaction': 'jws-$id',
      };
      final purchases = InAppPurchaseBillingStore.migrationEntitlements([
        {'id': 'bad', 'productId': 'pro_yearly', 'json': 'invalid'},
        item('good', {
          'expiresDate': DateTime.now()
              .add(const Duration(days: 2))
              .millisecondsSinceEpoch,
        }),
        item('upgraded', {'isUpgraded': true}),
        item('revoked', {'revocationDate': 1000}),
        item('expired', {'expiresDate': 1000}),
      ]);
      expect(purchases.map((p) => p.id), ['bad', 'good']);
      expect(purchases.first.storeFields, isNull);
      expect(purchases.last.storeFields?['signedTransaction'], 'jws-good');
      expect(purchases.every((p) => !p.needsCompletion), isTrue);
    },
  );
}
