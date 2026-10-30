import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:apprefer/src/billing/billing_engine.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/customer_info.dart';
import 'support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final store in [BillingStore.appStore, BillingStore.playStore]) {
    test(
      'legacy ${store.name} unlocks online and retries old import once',
      () async {
        const user = '6F9619FF-8B86-D011-B42D-00C04FC964FF';
        final h = await Harness.create(
          appUserId: user,
          prefs: {
            'apprefer_billing_migration:${Uri.encodeComponent(user)}': 'done',
          },
        );
        h.server.handler = (request) {
          return (
            200,
            {
              ...customerJson(user),
              'legacyAppAccountToken': user.toLowerCase(),
            },
          );
        };
        expect(h.storage.migrationSynced(user), isFalse);
        final tag = store == BillingStore.appStore
            ? user.toLowerCase()
            : base64Encode(sha256.convert(utf8.encode(user)).bytes);
        h.store.entitlements = [
          StoreEntitlement(
            productId: 'pro_yearly',
            originalId: 'legacy',
            kind: StoreProductKind.autoRenewable,
            store: store,
            expirationDate: now.add(const Duration(days: 3)),
            accountToken: tag,
          ),
        ];
        h.store.restoreList = [
          store == BillingStore.appStore
              ? h.store.applePurchase(
                  'legacy',
                  'pro_yearly',
                  status: StorePurchaseStatus.restored,
                  accountToken: tag,
                )
              : h.store.googlePurchase(
                  'legacy',
                  'pro_yearly',
                  isAcknowledged: true,
                  accountToken: tag,
                ),
        ];
        final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
        expect(info.entitlements['premium']?.isActive, isTrue);
        await h.engine.migrationSync();
        await h.engine.migrationSync();
        final bodies = h.server.bodiesFor('/api/billing/v1/purchases');
        expect(bodies, hasLength(1));
        expect(bodies.single['appUserId'], user);
        expect(bodies.single['restore'], isNot(true));
        expect(h.store.completed, isEmpty);
        expect(h.store.acknowledged, isEmpty);
      },
    );
  }
  test(
    'UUID case variant needs its own server-confirmed legacy binding',
    () async {
      const upper = '6F9619FF-8B86-D011-B42D-00C04FC964FF';
      final lower = upper.toLowerCase();
      final h = await Harness.create(appUserId: upper);
      h.server.handler = (request) {
        final body = request.body.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(request.body) as Map<String, dynamic>;
        final user =
            body['appUserId'] as String? ??
            request.url.queryParameters['appUserId'] ??
            upper;
        return (
          200,
          {
            ...customerJson(user),
            'legacyAppAccountToken': user == upper ? lower : null,
          },
        );
      };
      h.store.entitlements = [activeSub('pro_yearly', accountToken: lower)];
      expect(
        (await h.engine.customerInfo(
          FetchPolicy.fetchCurrent,
        )).entitlements['premium']?.isActive,
        isTrue,
      );
      await h.engine.logIn(lower);
      expect(
        (await h.engine.customerInfo(
          FetchPolicy.fetchCurrent,
        )).entitlements['premium']?.isActive,
        isNot(true),
      );
    },
  );
  test(
    'permanent ownership rejection cannot grant or block next purchase',
    () async {
      const user = '6f9619ff-8b86-d011-b42d-00c04fc964ff';
      final h = await Harness.create(appUserId: user);
      h.store.entitlements = [
        activeSub('pro_yearly', accountToken: user, transactionId: 'renewal'),
      ];
      h.server.handler = (request) => request.url.path.endsWith('/purchases')
          ? (422, <String, dynamic>{})
          : (200, customerJson(user));
      final result = await h.engine.process(
        h.store.applePurchase(
          'renewal',
          'pro_yearly',
          accountToken: user,
          originalTransactionId: 'original',
        ),
      );
      expect(h.queue.entries, isEmpty);
      expect(result.entitlements['premium']?.isActive, isNot(true));
      expect(
        (await h.engine.customerInfo(
          FetchPolicy.fetchCurrent,
        )).entitlements['premium']?.isActive,
        isNot(true),
      );
      h.server.online();
      await h.engine.process(
        h.store.applePurchase('valid-next', 'pro_yearly', accountToken: token),
      );
      expect(h.queue.entries, isEmpty);
      expect(h.server.bodiesFor('/api/billing/v1/purchases'), hasLength(2));
    },
  );
}
