import 'package:flutter_test/flutter_test.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/billing_engine.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'imports once per user, login imports again, never restores or finishes',
    () async {
      final h = await Harness.create(appUserId: 'alice');
      h.server.online();
      h.store.restoreList = [
        h.store.applePurchase(
          'legacy',
          'pro_yearly',
          status: StorePurchaseStatus.restored,
        ),
      ];
      await h.engine.migrationSync();
      expect(h.storage.migrationSynced('alice'), isTrue);
      await h.engine.migrationSync();
      expect(h.server.bodiesFor('/api/billing/v1/purchases'), hasLength(1));
      await h.engine.logIn('bob');
      await Future<void>.delayed(Duration.zero);
      await h.engine.migrationSync();
      expect(h.storage.migrationSynced('bob'), isTrue);
      final bodies = h.server.bodiesFor('/api/billing/v1/purchases');
      expect(bodies.map((b) => b['appUserId']).toSet(), {'alice', 'bob'});
      expect(bodies.every((b) => !b.containsKey('restore')), isTrue);
      expect(h.store.completed, isEmpty);
      expect(h.store.acknowledged, isEmpty);
      expect(h.store.syncCalls, 0);
    },
  );

  test(
    'flag requires durable queue; replay does not consume a migrated purchase',
    () async {
      late FlakyPrefs prefs;
      final h = await Harness.create(
        appUserId: 'alice',
        wrapPrefs: (p) => prefs = FlakyPrefs(p),
      );
      h.server.online();
      h.store.restoreList = [
        h.store.googlePurchase(
          'legacy',
          'coins',
          kind: StoreProductKind.nonConsumable,
          isAcknowledged: true,
        ),
      ];
      // Persist the identity before injecting failures.
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      h.server.offline();
      prefs.failWrites = true;
      await h.engine.migrationSync();
      expect(h.storage.migrationSynced('alice'), isFalse);
      prefs.failWrites = false;
      await h.engine.migrationSync();
      expect(h.storage.migrationSynced('alice'), isTrue);
      final reloaded = PendingPurchaseQueue(
        h.prefs,
        BillingStorage.pendingPurchasesKey,
      );
      expect(reloaded.entries.single.migrationOnly, isTrue);
      h.server.online();
      await h.engine.drainQueue();
      expect(h.queue.isEmpty, isTrue);
      expect(h.store.completed, isEmpty);
      expect(h.store.acknowledged, isEmpty);
    },
  );

  test('missing signed proof does not set flag', () async {
    final h = await Harness.create(appUserId: 'alice');
    h.store.restoreList = [
      h.store.applePurchase(
        'legacy',
        'pro_yearly',
        jws: null,
        status: StorePurchaseStatus.restored,
      ),
    ];
    await h.engine.migrationSync();
    expect(h.storage.migrationSynced('alice'), isFalse);
  });
  test('startup handles open purchases normally', () async {
    final h = await Harness.create(appUserId: 'alice');
    h.server.online();
    final legacy = h.store.googlePurchase(
      'legacy',
      'coins',
      kind: StoreProductKind.consumable,
    );
    h.store.restoreList = [legacy];
    h.store.unfinishedList = [legacy];
    await h.engine.start();
    await h.engine.resume();
    expect(h.store.completed, contains('legacy'));
    expect(h.server.bodiesFor('/api/billing/v1/purchases'), hasLength(2));
    expect(
      BillingStorage(h.prefs).isMigrationPurchase('playStore:legacy'),
      isFalse,
    );
    await h.engine.dispose();
  });
  for (final status in [401, 403, 404, 409, 429]) {
    test(
      'migration backoff $status preserves every durable import without completing',
      () async {
        final h = await Harness.create(appUserId: 'alice');
        h.store.restoreList = [
          h.store.applePurchase(
            'one',
            'pro_yearly',
            status: StorePurchaseStatus.restored,
          ),
          h.store.applePurchase(
            'two',
            'pro_yearly',
            status: StorePurchaseStatus.restored,
          ),
        ];
        h.server.status(status);
        await h.engine.migrationSync();
        expect(h.storage.migrationSynced('alice'), isTrue);
        expect(h.queue.entries, hasLength(2));
        expect(
          h.queue.entries.every(
            (e) => e.attempts == 0 && !e.restore && e.migrationOnly,
          ),
          isTrue,
        );
        final sent = h.server.requests.length;
        await h.engine.drainQueue();
        expect(h.server.requests.length, sent);
        expect(h.store.completed, isEmpty);
      },
    );
  }
}
