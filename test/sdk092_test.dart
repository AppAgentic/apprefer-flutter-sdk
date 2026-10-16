import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_engine.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:apprefer/src/services/registry.dart';
import 'package:apprefer/src/services/storage.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'billing/support.dart';

const customers = '/api/billing/v1/customers';
const purchases = '/api/billing/v1/purchases';

/// A preferences store whose writes fail, like a full disk.
class FailingWrites092 extends InMemorySharedPreferencesStore {
  FailingWrites092() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await AppReferSDK.disposeForTesting();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await AppReferSDK.disposeForTesting();
    AppReferRegistry.apiKey = null;
  });
  const config = AppReferConfig(apiKey: 'pk_test');
  Future<void> configure() => http.runWithClient(
    () => AppReferSDK.configure(config),
    () => MockClient((r) async => http.Response('{"attribution":null}', 200)),
  );

  group('1. Billing sends no device id while the gate is closed', () {
    test('normal: device id and device attributes are sent', () async {
      final h = await Harness.create(
        appUserId: 'alice',
        server: FakeServer()..online(),
        appreferId: AppReferRegistry.linkableDeviceId,
      );
      await configure();
      final device = (await SharedPreferences.getInstance()).getString(
        'apprefer_device_id',
      );
      expect(device, isNotNull);
      h.engine.setAttributes({r'$email': 'a@b.com', r'$idfv': 'IDFV'});
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      final customer = h.server.bodiesFor(customers).single;
      expect(customer['appreferId'], device);
      expect(customer['attributes'], {r'$email': 'a@b.com', r'$idfv': 'IDFV'});
      expect(h.server.bodiesFor(purchases).single['appreferId'], device);
    });

    test(
      'collection off: no device id, purchases and entitlements still work',
      () async {
        final h = await Harness.create(
          appUserId: 'alice',
          server: FakeServer()..online(active: {'premium': 'pro_yearly'}),
          appreferId: AppReferRegistry.linkableDeviceId,
        );
        await configure();
        await AppReferSDK.setCollectionEnabled(false);
        h.engine.setAttributes({
          r'$email': 'a@b.com',
          r'$idfa': 'IDFA',
          r'$gpsAdId': 'gaid',
        });
        final info = await h.engine.customerInfo(FetchPolicy.fetchCurrent);
        final bought = await h.engine.process(
          h.store.applePurchase('t1', 'pro_yearly'),
        );
        final customer = h.server.bodiesFor(customers).single;
        final purchase = h.server.bodiesFor(purchases).single;
        expect(customer.containsKey('appreferId'), isFalse);
        expect(customer['attributes'], {r'$email': 'a@b.com'});
        expect(purchase.containsKey('appreferId'), isFalse);
        expect(purchase['signedTransaction'], 'jws.payload.sig');
        expect(info.entitlements['premium']?.isActive, isTrue);
        expect(bought.entitlements['premium']?.isActive, isTrue);
        // Turned back on: still closed until configure runs again.
        await AppReferSDK.setCollectionEnabled(true);
        expect(await AppReferRegistry.linkableDeviceId(), isNull);
        expect(await AppReferRegistry.linkAllowed(), isFalse);
        await configure();
        expect(await AppReferRegistry.linkableDeviceId(), isNotNull);
      },
    );

    test('after reset: none until configure, then linked once', () async {
      final h = await Harness.create(
        appUserId: 'bob',
        server: FakeServer()..online(),
        appreferId: AppReferRegistry.linkableDeviceId,
      );
      await configure();
      final device = (await SharedPreferences.getInstance()).getString(
        'apprefer_device_id',
      )!;
      await AppReferSDK.reset();
      expect(await AppReferRegistry.linkableDeviceId(), isNull);
      // Queued before the reset, with the device id on disk.
      await h.queue.add(
        PendingPurchase(
          transactionId: 'tq',
          productId: 'pro_yearly',
          appUserId: 'bob',
          appreferId: device,
          storeFields: const {
            'store': 'app_store',
            'signedTransaction': 'jws.queued.sig',
          },
          enqueuedAt: now,
          attempts: 0,
        ),
      );
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      await h.engine.process(h.store.applePurchase('t2', 'pro_yearly'));
      expect(h.queue.isEmpty, isTrue);
      final before = [
        ...h.server.bodiesFor(customers),
        ...h.server.bodiesFor(purchases),
      ];
      expect(before, hasLength(3));
      expect(before.every((b) => !b.containsKey('appreferId')), isTrue);
      expect(
        h.server
            .bodiesFor(purchases)
            .any((b) => b['signedTransaction'] == 'jws.queued.sig'),
        isTrue,
      );

      await configure(); // the next user
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      await h.engine.process(h.store.applePurchase('t3', 'pro_yearly'));
      final registered = h.server.bodiesFor(customers);
      expect(registered, hasLength(2), reason: 'one re-registration');
      expect(registered.last['appreferId'], device);
      expect(h.server.bodiesFor(purchases).last['appreferId'], device);
    });

    test('an "off" that could not be saved closes the gate', () async {
      await configure();
      expect(await AppReferRegistry.linkableDeviceId(), isNotNull);
      SharedPreferencesStorePlatform.instance = FailingWrites092();
      SharedPreferences.resetStatic();
      await AppReferSDK.setCollectionEnabled(false);
      expect(await AppReferRegistry.linkableDeviceId(), isNull);
    });

    test('Billing-only apps never send it', () async {
      SharedPreferences.setMockInitialValues({'apprefer_device_id': 'dev'});
      expect(await AppReferRegistry.linkableDeviceId(), isNull);
      expect(
        BillingEngine.sendableAttributes({
          r'$displayName': 'Sam',
          r'$ip': '1.2.3.4',
          r'$fbAnonId': 'fb',
        }, linked: false),
        {r'$displayName': 'Sam'},
      );
    });
  });

  group('2. Support clearIdentity', () {
    late Map<String, String> secure;
    late List<http.Request> requests;
    late int minted;
    SupportAPI make() => SupportAPI(
      apiKey: () => 'pk_test',
      read: (k) async => secure[k],
      write: (k, v) async {
        if (v == null) {
          secure.remove(k);
        } else {
          secure[k] = v;
        }
      },
      keys: () async => secure.keys.toList(),
      client: MockClient((r) async {
        requests.add(r);
        if (r.url.path.endsWith('/session') && r.method == 'POST') {
          final header = r.headers['X-AppRefer-Support-Session'];
          return http.Response(
            jsonEncode({'session': header ?? 'ars_092_${++minted}'}),
            200,
          );
        }
        return http.Response('{"conversations":[]}', 200);
      }),
    );
    List<http.Request> sessionPosts() => [
      for (final r in requests)
        if (r.method == 'POST' && r.url.path.endsWith('/session')) r,
    ];
    setUp(() {
      secure = {};
      requests = [];
      minted = 0;
    });

    test('revokes the session and starts an anonymous one', () async {
      await AppReferSDK.setUserId('acct_A');
      final api = make();
      api.name = 'Sam';
      await api.conversations();
      expect(jsonDecode(sessionPosts().last.body)['appUserId'], 'acct_A');
      expect(jsonDecode(sessionPosts().last.body)['name'], 'Sam');
      final old = requests.last.headers['X-AppRefer-Support-Session'];

      // What AppReferSDK.support.clearIdentity() does.
      final storage = AppReferStorage();
      await storage.init();
      await storage.setSupportIdentityCleared(true);
      await api.clearIdentity();
      await api.ensureSession();
      final fresh = sessionPosts().last;
      expect(fresh.headers['X-AppRefer-Support-Session'], isNull);
      final body = jsonDecode(fresh.body) as Map<String, dynamic>;
      expect(body.containsKey('appUserId'), isFalse);
      expect(body.containsKey('name'), isFalse);
      expect(storage.getUserId(), 'acct_A', reason: 'attribution untouched');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        requests.any(
          (r) =>
              r.method == 'DELETE' &&
              r.url.path.endsWith('/session') &&
              r.headers['X-AppRefer-Support-Session'] == old,
        ),
        isTrue,
      );
      final current = requests.last.headers['X-AppRefer-Support-Session'];
      expect(current, isNot(old));

      // Same id stored again (configure on the next launch): still anonymous.
      await AppReferSDK.setUserId('acct_A');
      final posts = sessionPosts().length;
      await api.conversations();
      expect(sessionPosts().length, posts);
      // Another account: linked again.
      await AppReferSDK.setUserId('acct_B');
      await api.conversations();
      expect(jsonDecode(sessionPosts().last.body)['appUserId'], 'acct_B');
    });

    test('returns the push token so it can move to the new session', () async {
      final api = make();
      await api.ensureSession();
      await api.persistPushToken('fcm-1', api.actionGeneration);
      final moved = await api.clearIdentity();
      expect(moved?.token, 'fcm-1');
      expect(moved?.environment, 'production');
      expect(secure.keys.where((k) => k.endsWith('.push')), isEmpty);
    });

    test('keeps the APNs environment of the moved push token', () async {
      final api = make();
      await api.ensureSession();
      await api.persistPushToken(
        'apns-1',
        api.actionGeneration,
        environment: 'sandbox',
      );
      // A relaunch: only the secure store remains.
      final relaunched = make();
      final moved = await relaunched.clearIdentity();
      expect(moved?.token, 'apns-1');
      expect(moved?.environment, 'sandbox');
      expect(secure.keys.where((k) => k.contains('.push')), isEmpty);
      expect(await make().clearIdentity(), isNull);
    });

    test('reset ends an identity clear', () async {
      final storage = AppReferStorage();
      await storage.init();
      await storage.setUserId('acct_A');
      await storage.setSupportIdentityCleared(true);
      expect(
        (await SupportAPI.defaultProfile()).containsKey('appUserId'),
        isFalse,
      );
      await AppReferSDK.reset();
      expect(storage.supportIdentityCleared, isFalse);
    });
  });
}
