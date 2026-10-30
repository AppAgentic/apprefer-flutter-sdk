import 'dart:async';
import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apprefer/src/billing/automatic_billing_scope.dart';
import 'package:apprefer/src/billing/purchase_intents.dart';
import 'support.dart';

class MemoryState implements ProtectedBillingState {
  String? value;
  bool failRead = false, failWrite = false, failFinal = false;
  int untilGate = 0;
  Completer<void>? entered, release;
  void gate(int n) {
    untilGate = n;
    entered = Completer();
    release = Completer();
  }

  @override
  Future<String?> read() async {
    if (failRead) throw StateError('locked');
    return value;
  }

  @override
  Future<void> write(String next) async {
    final d = jsonDecode(next) as Map;
    if (failWrite ||
        (failFinal &&
            d['pending'] == null &&
            (d['contexts'] as Map).values.contains('sandbox')))
      throw StateError('locked');
    value = next;
    if (untilGate > 0 && --untilGate == 0) {
      entered!.complete();
      await release!.future;
    }
  }
}

const proof = {
  'store': 'play_store',
  'purchaseToken': 'exact',
  'productId': 'plan',
};

class IntentGate extends FlakyPrefs {
  final entered = Completer<void>(), release = Completer<void>();
  IntentGate(super.inner);
  @override
  Future<bool> setString(String key, String value) async {
    final ok = await super.setString(key, value);
    if (key.contains('purchase_intents') && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return ok;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final change in ['single transition', 'roundtrip transition']) {
    test(
      '$change during intent persistence cannot mint new automatic authority',
      () async {
        final state = MemoryState();
        final automatic = AutomaticBillingScope(
          state,
          () => 'pk_live_a',
          () => (user: 'buyer', revision: 'one', reset: null),
          () => 0,
        );
        late IntentGate prefs;
        final h = await Harness.create(
          appUserId: 'buyer',
          apiKey: 'pk_live_a',
          automaticScope: automatic,
          wrapPrefs: (p) => prefs = IntentGate(p),
        );
        h.server.online();
        h.store.onBuy = (p, o) => h.store.updates.add([
          h.store.applePurchase(
            'pending',
            p.id,
            status: StorePurchaseStatus.pending,
          ),
        ]);
        final purchase = h.engine.purchase(
          FakeProduct('plan'),
          const StorePurchaseOptions(),
        );
        await prefs.entered.future;
        automatic.noteTransition();
        if (change == 'roundtrip transition') automatic.noteTransition();
        prefs.release.complete();
        await purchase;
        expect((jsonDecode(state.value!) as Map)['intents'], isEmpty);
        h.engine.dispose();
      },
    );
  }
  for (final storeType in [BillingStore.appStore, BillingStore.playStore]) {
    for (final delayed in [false, true]) {
      test(
        'default live-key ${storeType.name} ${delayed ? "pending recovery" : "fresh purchase"} adopts only owned sandbox and survives restart',
        () async {
          SharedPreferences.setMockInitialValues({});
          await AppReferBilling.resetForTesting();
          final state = MemoryState(),
              server = FakeServer(),
              store = FakeStore()..store = storeType;
          server.handler = (r) {
            final body = r.method == 'POST'
                ? jsonDecode(r.body) as Map
                : <String, dynamic>{};
            final user =
                body['appUserId'] ??
                r.url.queryParameters['appUserId'] ??
                'buyer';
            final scope = r.headers['X-AppRefer-Billing-Environment'];
            if (r.url.path.endsWith('/purchases') && scope == 'production') {
              return (
                400,
                {
                  'code': 'billing_environment_mismatch',
                  'environment': 'sandbox',
                },
              );
            }
            return (
              200,
              {
                ...customerJson(
                  user as String,
                  active: scope == 'sandbox' ? {'premium': 'plan'} : {},
                ),
                'environment': scope,
              },
            );
          };
          store.onBuy = (product, options) {
            final purchase = storeType == BillingStore.playStore
                ? store.googlePurchase(
                    'fresh',
                    product.id,
                    status: delayed
                        ? StorePurchaseStatus.pending
                        : StorePurchaseStatus.purchased,
                    accountToken: options.accountToken,
                    purchasedAt: now,
                  )
                : store.applePurchase(
                    'fresh',
                    product.id,
                    status: delayed
                        ? StorePurchaseStatus.pending
                        : StorePurchaseStatus.purchased,
                    accountToken: options.accountToken,
                    purchasedAt: now,
                  );
            store.updates.add([purchase]);
          };
          await AppReferBilling.configureForTesting(
            store: store,
            httpClient: server.client,
            apiKey: 'pk_live_a',
            appUserId: 'buyer',
            automaticState: state,
            now: () => now,
          );
          final result = await AppReferBilling.purchase(
            (await AppReferBilling.products(['plan'])).single,
          );
          if (!delayed)
            expect(result.customerInfo.environment, BillingEnvironment.sandbox);
          final restarted = FakeStore()..store = storeType;
          if (delayed)
            restarted.unfinishedList = [
              storeType == BillingStore.playStore
                  ? restarted.googlePurchase(
                      'fresh',
                      'plan',
                      accountToken: token,
                      purchasedAt: now,
                    )
                  : restarted.applePurchase(
                      'fresh',
                      'plan',
                      accountToken: token,
                      purchasedAt: now,
                    ),
            ];
          await AppReferBilling.resetForTesting();
          await AppReferBilling.configureForTesting(
            store: restarted,
            httpClient: server.client,
            apiKey: 'pk_live_a',
            appUserId: 'buyer',
            automaticState: state,
            now: () => now,
          );
          if (delayed)
            await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(
            (await AppReferBilling.customerInfo(
              fetchPolicy: FetchPolicy.fetchCurrent,
            )).environment,
            BillingEnvironment.sandbox,
          );
          await AppReferBilling.resetForTesting();
        },
      );
    }
  }
  test(
    'exact proofs are partitioned by user and key and revoked by reset and identity generation',
    () async {
      final state = MemoryState();
      var key = 'pk_live_a', epoch = 0;
      AutomaticIdentity i = (user: 'buyer', revision: 'one', reset: null);
      AutomaticBillingScope make() =>
          AutomaticBillingScope(state, () => key, () => i, () => epoch);
      final a = make(), t = (await a.capture('buyer'))!;
      await a.authorizeProof(proof, t);
      expect(
        await a.commit(
          t,
          BillingEnvironment.sandbox,
          'wrong',
          acceptedFields: proof,
        ),
        false,
      );
      final b = make(), recovered = (await b.recoverProof('buyer', proof))!;
      expect(
        await b.recoverProof('buyer', {...proof, 'purchaseToken': 'old'}),
        null,
      );
      expect(
        await b.commit(
          recovered,
          BillingEnvironment.sandbox,
          'buyer',
          acceptedFields: proof,
        ),
        true,
      );
      expect(b.current(), BillingEnvironment.sandbox);
      expect(state.value, isNot(contains('pk_live_a')));
      key = 'pk_live_b';
      expect(b.current(), BillingEnvironment.production);
      expect(await b.recoverProof('buyer', proof), null);
      key = 'pk_live_a';
      epoch++;
      expect(await b.recoverProof('buyer', proof), null);
      i = (user: 'buyer', revision: 'two', reset: 'reset');
      expect(b.isCurrent(recovered), false);
    },
  );
  test(
    'transient protected I/O recovers and corrupt state is not overwritten',
    () async {
      final state = MemoryState()..failRead = true;
      final a = AutomaticBillingScope(
        state,
        () => 'pk_live_a',
        () => (user: 'buyer', revision: 'one', reset: null),
        () => 0,
      );
      await expectLater(a.capture('buyer'), throwsA(anything));
      state.failRead = false;
      final t = (await a.capture('buyer'))!;
      state.failWrite = true;
      await expectLater(a.authorizeProof(proof, t), throwsA(anything));
      state.failWrite = false;
      expect(await a.recoverProof('buyer', proof), null);
      state.value = '{broken';
      final b = AutomaticBillingScope(
        state,
        () => 'pk_live_a',
        () => (user: 'buyer', revision: 'one', reset: null),
        () => 0,
      );
      await expectLater(b.capture('buyer'), throwsA(anything));
      expect(state.value, '{broken');
    },
  );
  for (final change in ['identity', 'key', 'reset']) {
    test(
      '$change during staging never activates or persists a confirmed candidate',
      () async {
        final state = MemoryState();
        var key = 'pk_live_a', epoch = 0;
        AutomaticIdentity i = (user: 'buyer', revision: 'one', reset: null);
        AutomaticBillingScope make() =>
            AutomaticBillingScope(state, () => key, () => i, () => epoch);
        final a = make(), t = (await a.capture('buyer'))!;
        await a.authorizeProof(proof, t);
        state.gate(1);
        final committing = a.commit(
          t,
          BillingEnvironment.sandbox,
          'buyer',
          acceptedFields: proof,
        );
        await state.entered!.future;
        if (change == 'identity') {
          a.noteTransition();
          i = (user: 'next', revision: 'two', reset: null);
        }
        if (change == 'key') key = 'pk_live_b';
        if (change == 'reset') {
          epoch++;
          i = (user: 'buyer', revision: 'one', reset: 'new');
        }
        state.release!.complete();
        expect(await committing, false);
        expect(a.current(), BillingEnvironment.production);
        final b = make();
        await b.setUser();
        expect(b.current(), BillingEnvironment.production);
        expect(
          (jsonDecode(state.value!)['contexts'] as Map).values,
          isNot(contains('sandbox')),
        );
      },
    );
  }
  test(
    'a transition after activation during finalization is ordered after the successful commit',
    () async {
      final state = MemoryState();
      var epoch = 0;
      final a = AutomaticBillingScope(
        state,
        () => 'pk_live_a',
        () => (user: 'buyer', revision: 'one', reset: null),
        () => epoch,
      );
      final t = (await a.capture('buyer'))!;
      await a.authorizeProof(proof, t);
      state.gate(2);
      final committing = a.commit(
        t,
        BillingEnvironment.sandbox,
        'buyer',
        acceptedFields: proof,
      );
      await state.entered!.future;
      expect(a.current(), BillingEnvironment.sandbox);
      epoch++;
      state.release!.complete();
      expect(await committing, true);
    },
  );
  test(
    'pending-only crash ignores scope and retains exact proof for server recovery',
    () async {
      final state = MemoryState();
      AutomaticBillingScope make() => AutomaticBillingScope(
        state,
        () => 'pk_live_a',
        () => (user: 'buyer', revision: 'one', reset: null),
        () => 0,
      );
      final a = make(), t = (await a.capture('buyer'))!;
      await a.authorizeProof(proof, t);
      state.gate(1);
      final committing = a.commit(
        t,
        BillingEnvironment.sandbox,
        'buyer',
        acceptedFields: proof,
      );
      await state.entered!.future;
      final b = make();
      expect(await b.recoverProof('buyer', proof), isNotNull);
      expect(b.current(), BillingEnvironment.production);
      state.release!.complete();
      await committing;
    },
  );
  test(
    'finalization retry consumes completed proof and originating intent before old redelivery',
    () async {
      final state = MemoryState();
      final a = AutomaticBillingScope(
        state,
        () => 'pk_live_a',
        () => (user: 'buyer', revision: 'one', reset: null),
        () => 0,
      );
      final store = FakeStore();
      final p = store.googlePurchase('exact', 'plan', purchasedAt: now);
      final fields = p.storeFields!;
      final intent = PurchaseIntent(
        appUserId: 'buyer',
        productId: 'plan',
        accountToken: null,
        startedAt: now,
      );
      final t = (await a.capture('buyer'))!;
      await a.authorizeIntent(intent, t);
      await a.authorizeProof(fields, t, intent: intent);
      expect(
        await a.recoverIntent(
          intent,
          store.googlePurchase('other', 'plan', purchasedAt: now),
        ),
        null,
      );
      state.failFinal = true;
      expect(
        await a.commit(
          t,
          BillingEnvironment.sandbox,
          'buyer',
          acceptedFields: fields,
        ),
        true,
      );
      expect(await a.recoverIntent(intent, p), null);
      expect(await a.recoverProof('buyer', fields), null);
      state.failFinal = false;
      await a.setUser();
      final next = (await a.capture('buyer'))!;
      final newer = {...fields, 'purchaseToken': 'production'};
      await a.authorizeProof(newer, next);
      expect(
        await a.commit(
          next,
          BillingEnvironment.production,
          'buyer',
          acceptedFields: newer,
        ),
        true,
      );
      expect(await a.hasAuthorizedProofs('buyer'), false);
      expect(await a.recoverIntent(intent, p), null);
      expect(a.current(), BillingEnvironment.production);
    },
  );
  for (final explicit in [
    null,
    BillingEnvironment.production,
    BillingEnvironment.sandbox,
  ]) {
    test(
      'strict test-key/explicit scope excludes automatic authorization $explicit',
      () async {
        final a = AutomaticBillingScope(
          MemoryState(),
          () => explicit == null ? 'pk_test_a' : 'pk_live_a',
          () => (user: 'buyer', revision: 'one', reset: null),
          () => 0,
          explicit: explicit,
        );
        expect(await a.capture('buyer'), null);
      },
    );
  }
  test(
    'only confirmed anonymous alias inherits, never member-to-member',
    () async {
      final state = MemoryState();
      AutomaticIdentity i = (
        user: r'$ARAnon:one',
        revision: 'one',
        reset: null,
      );
      final a = AutomaticBillingScope(
        state,
        () => 'pk_live_a',
        () => i,
        () => 0,
      );
      final anon = (await a.capture(i.user))!;
      expect(await a.commit(anon, BillingEnvironment.sandbox, i.user), true);
      i = (user: 'member', revision: 'two', reset: null);
      a.noteTransition();
      final t = (await a.capture('member'))!;
      expect(await a.inheritAnonymous(r'$ARAnon:one', t, 'wrong'), false);
      expect(a.current(), BillingEnvironment.production);
      expect(await a.inheritAnonymous(r'$ARAnon:one', t, 'member'), true);
      expect(a.current(), BillingEnvironment.sandbox);
      i = (user: 'other', revision: 'three', reset: null);
      a.noteTransition();
      final other = (await a.capture('other'))!;
      await a.inheritAnonymous('member', other, 'other');
      expect(a.current(), BillingEnvironment.production);
    },
  );
}
