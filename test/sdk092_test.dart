import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_api_client.dart';
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

    test(
      'after reset: none until configure, then the next user is linked once',
      () async {
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

        await configure(); // the next user, but Billing still serves bob
        await h.engine.customerInfo(FetchPolicy.fetchCurrent);
        await h.engine.process(h.store.applePurchase('t3', 'pro_yearly'));
        expect(
          h.server.bodiesFor(customers),
          hasLength(1),
          reason: 'no re-link',
        );
        expect(
          h.server.bodiesFor(purchases).last.containsKey('appreferId'),
          isFalse,
        );

        await h.engine.logIn('carol');
        await h.engine.customerInfo(FetchPolicy.fetchCurrent);
        await h.engine.process(h.store.applePurchase('t4', 'pro_yearly'));
        final registered = h.server.bodiesFor(customers);
        expect(registered, hasLength(2), reason: 'carol registered once');
        expect(registered.last['appUserId'], 'carol');
        expect(registered.last['appreferId'], device);
        expect(h.server.bodiesFor(purchases).last['appreferId'], device);
      },
    );

    test('after reset, logIn for the same user links it once', () async {
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
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      await configure();
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.server.bodiesFor(customers), hasLength(1));
      expect(
        h.server.bodiesFor(customers).single.containsKey('appreferId'),
        isFalse,
      );
      await h.engine.logIn('bob');
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      final registered = h.server.bodiesFor(customers);
      expect(registered, hasLength(2), reason: 'linked once');
      expect(registered.last['appreferId'], device);
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
    // 0 = the DELETE /session can't reach the server.
    late int deleteStatus;
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
        if (r.url.path.endsWith('/session') && r.method == 'DELETE') {
          if (deleteStatus == 0) throw http.ClientException('offline');
          return http.Response('{}', deleteStatus);
        }
        return http.Response('{"conversations":[]}', 200);
      }),
    );
    List<http.Request> sessionPosts() => [
      for (final r in requests)
        if (r.method == 'POST' && r.url.path.endsWith('/session')) r,
    ];
    List<http.Request> pushPosts() => [
      for (final r in requests)
        if (r.method == 'POST' && r.url.path.endsWith('/push-token')) r,
    ];
    int deleteOf(String? session) => requests.indexWhere(
      (r) =>
          r.method == 'DELETE' &&
          r.url.path.endsWith('/session') &&
          r.headers['X-AppRefer-Support-Session'] == session,
    );
    Future<void> settle() async {
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    /// What `AppReferSDK.support.clearIdentity()` does to the API.
    Future<void> clearIdentity(SupportAPI api) async {
      final storage = AppReferStorage();
      await storage.init();
      await storage.setSupportIdentityCleared(true);
      await api.clearIdentity();
      await api.ensureSession();
    }

    setUp(() {
      secure = {};
      requests = [];
      minted = 0;
      deleteStatus = 200;
    });

    test('revokes the session and starts an anonymous one', () async {
      await AppReferSDK.setUserId('acct_A');
      final api = make();
      api.name = 'Sam';
      await api.conversations();
      expect(jsonDecode(sessionPosts().last.body)['appUserId'], 'acct_A');
      expect(jsonDecode(sessionPosts().last.body)['name'], 'Sam');
      final old = requests.last.headers['X-AppRefer-Support-Session'];

      await clearIdentity(api);
      final fresh = sessionPosts().last;
      expect(fresh.headers['X-AppRefer-Support-Session'], isNull);
      final body = jsonDecode(fresh.body) as Map<String, dynamic>;
      expect(body.containsKey('appUserId'), isFalse);
      expect(body.containsKey('name'), isFalse);
      final storage = AppReferStorage();
      await storage.init();
      expect(storage.getUserId(), 'acct_A', reason: 'attribution untouched');
      await settle();
      expect(deleteOf(old), isNot(-1));
      await api.conversations();
      final current = requests.last.headers['X-AppRefer-Support-Session'];
      expect(current, isNot(old));

      // Same id stored again (configure on the next launch): still anonymous,
      // on the same session.
      await AppReferSDK.setUserId('acct_A');
      final posts = sessionPosts().length;
      await api.conversations();
      expect(sessionPosts().length, posts);
      expect(requests.last.headers['X-AppRefer-Support-Session'], current);
    });

    test('another account later gets a fresh session; the cleared one is '
        'revoked and never sent with its id', () async {
      await AppReferSDK.setUserId('acct_A');
      final api = make();
      await api.conversations();
      await clearIdentity(api);
      await api.conversations(); // A keeps chatting anonymously
      final cleared = requests.last.headers['X-AppRefer-Support-Session']!;
      expect(secure['support_pk_test.cleared'], '1');

      // Another account signs in without reset().
      await AppReferSDK.setUserId('acct_B');
      final generation = api.actionGeneration;
      await api.conversations();
      await settle();
      final bPost = sessionPosts().last;
      expect(bPost.headers['X-AppRefer-Support-Session'], isNull);
      expect(jsonDecode(bPost.body)['appUserId'], 'acct_B');
      expect(
        requests.any(
          (r) =>
              r.headers['X-AppRefer-Support-Session'] == cleared &&
              r.method == 'POST' &&
              r.url.path.endsWith('/session') &&
              (jsonDecode(r.body) as Map).containsKey('appUserId'),
        ),
        isFalse,
      );
      expect(deleteOf(cleared), isNot(-1));
      final last = requests.lastWhere((r) => r.method == 'GET');
      expect(last.headers['X-AppRefer-Support-Session'], isNot(cleared));
      expect(
        api.actionGeneration,
        generation,
        reason: 'UI calls not cancelled',
      );
      expect(secure.containsKey('support_pk_test.cleared'), isFalse);
      // Its session now carries B and is kept.
      final posts = sessionPosts().length;
      await api.conversations();
      expect(sessionPosts().length, posts);
    });

    test(
      'the cleared session sends no device id, even when configured',
      () async {
        await configure();
        await AppReferSDK.setUserId('acct_A');
        expect(await AppReferRegistry.linkableDeviceId(), isNotNull);
        expect((await SupportAPI.defaultProfile())['deviceId'], isNotNull);
        final api = make();
        await api.conversations();
        expect(jsonDecode(sessionPosts().last.body)['deviceId'], isNotNull);

        await clearIdentity(api);
        final body = jsonDecode(sessionPosts().last.body) as Map;
        expect(body.containsKey('deviceId'), isFalse);
        expect(body.containsKey('appUserId'), isFalse);
        expect(await SupportAPI.defaultProfile(), isEmpty);
      },
    );

    test(
      'the push token moves only after the old session is revoked',
      () async {
        final api = make();
        await api.ensureSession();
        final old = requests.last.headers['X-AppRefer-Support-Session'];
        await api.persistPushToken(
          'apns-1',
          api.actionGeneration,
          environment: 'sandbox',
        );
        deleteStatus = 500;
        await clearIdentity(api);
        await settle();
        expect(deleteOf(old), isNot(-1), reason: 'revocation attempted');
        expect(pushPosts(), isEmpty, reason: 'not moved before revocation');
        expect(secure['support_pk_test.push'], 'apns-1', reason: 'kept');
        expect(await api.pushMovePending('apns-1'), isTrue);

        deleteStatus = 0; // offline
        api.resumeRevocations();
        await settle();
        expect(pushPosts(), isEmpty);

        deleteStatus = 200;
        requests.clear();
        api.resumeRevocations();
        await settle();
        final push = pushPosts().single;
        expect(deleteOf(old), lessThan(requests.indexOf(push)));
        expect(jsonDecode(push.body)['token'], 'apns-1');
        expect(jsonDecode(push.body)['environment'], 'sandbox');
        expect(push.headers['X-AppRefer-Support-Session'], isNot(old));
        expect(push.headers['X-AppRefer-Support-Session'], isNotNull);
        expect(await api.pushMovePending('apns-1'), isFalse);
      },
    );

    test('a 404 (already gone) also moves it', () async {
      final api = make();
      await api.ensureSession();
      await api.persistPushToken(
        'fcm-1',
        api.actionGeneration,
        environment: 'production',
      );
      deleteStatus = 404;
      await clearIdentity(api);
      await settle();
      expect(jsonDecode(pushPosts().single.body)['token'], 'fcm-1');
    });

    test('a reset before the revocation succeeds never moves it', () async {
      final api = make();
      await api.ensureSession();
      await api.persistPushToken(
        'apns-1',
        api.actionGeneration,
        environment: 'production',
      );
      deleteStatus = 500;
      await clearIdentity(api);
      await settle();
      await api.reset();
      expect(await api.pushMovePending('apns-1'), isFalse);
      // The next account registers the same device token: sent at once.
      await api.persistPushToken(
        'apns-1',
        api.actionGeneration,
        environment: 'production',
      );
      expect(await api.pushMovePending('apns-1'), isFalse);
      await api.persistPushToken(null, api.actionGeneration);
      deleteStatus = 200;
      api.resumeRevocations();
      await settle();
      expect(pushPosts(), isEmpty);
      expect(secure.keys.where((k) => k.contains('.push')), isEmpty);
    });

    test('a revocation dropped for age never moves it', () async {
      secure['apprefer_revocations'] = jsonEncode([
        {
          'token': 'ancient',
          'key': 'pk_test',
          'push': 'apns-1',
          'move': true,
          'environment': 'production',
          'createdAt': DateTime.now().millisecondsSinceEpoch - 401 * 86400000,
        },
      ]);
      secure['support_pk_test.push'] = 'apns-1';
      final api = make();
      api.resumeRevocations();
      await settle();
      expect(requests, isEmpty);
      expect(jsonDecode(secure['apprefer_revocations']!), isEmpty);
    });

    test('a token saved before 0.9.2 (no environment) is not moved', () async {
      final api = make();
      await api.ensureSession();
      final old = requests.last.headers['X-AppRefer-Support-Session'];
      secure['support_pk_test.push'] = 'apns-091';
      await clearIdentity(api);
      await settle();
      expect(deleteOf(old), isNot(-1));
      expect(pushPosts(), isEmpty);
    });

    test(
      'a different account moves the push token after revocation too',
      () async {
        await AppReferSDK.setUserId('acct_A');
        final api = make();
        await clearIdentity(api);
        await api.persistPushToken(
          'fcm-1',
          api.actionGeneration,
          environment: 'production',
        );
        final cleared = requests.last.headers['X-AppRefer-Support-Session'];
        requests.clear();
        await AppReferSDK.setUserId('acct_B');
        await api.conversations();
        await settle();
        final push = pushPosts().single;
        expect(deleteOf(cleared), lessThan(requests.indexOf(push)));
        expect(push.headers['X-AppRefer-Support-Session'], isNot(cleared));
      },
    );

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
      expect(await storage.isSupportIdentityCleared(), isFalse);
    });
  });

  group('3. Billing device id follows the account', () {
    test('the user served before a reset is never linked', () async {
      var epoch = 0;
      final h = await Harness.create(
        appUserId: 'alice',
        server: FakeServer()..online(),
        accountEpoch: () => epoch,
      );
      h.engine.setAttributes({r'$idfv': 'IDFV'});
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.server.bodiesFor(customers).single['appreferId'], 'device-1');

      epoch++; // reset(), then configure again for the next user
      h.engine.setAttributes({r'$email': 'a@b.com', r'$idfa': 'IDFA'});
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      await h.engine.process(h.store.applePurchase('t1', 'pro_yearly'));
      await h.queue.add(
        PendingPurchase(
          transactionId: 'tq',
          productId: 'pro_yearly',
          appUserId: 'alice',
          appreferId: 'device-1',
          storeFields: const {
            'store': 'app_store',
            'signedTransaction': 'jws.queued.sig',
          },
          enqueuedAt: h.time,
          attempts: 0,
        ),
      );
      await h.engine.drainQueue();
      final after = [
        ...h.server.bodiesFor(customers).skip(1),
        ...h.server.bodiesFor(purchases),
      ];
      expect(after, hasLength(3));
      expect(after.every((b) => !b.containsKey('appreferId')), isTrue);
      expect(h.server.bodiesFor(customers).last['attributes'], {
        r'$email': 'a@b.com',
      });

      await h.engine.logOut();
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      final anonymous = h.server.bodiesFor(customers).last;
      expect(anonymous['appUserId'], startsWith(r'$ARAnon:'));
      expect(anonymous['appreferId'], 'device-1');
    });

    test(
      'a user registered unlinked before a reset is not linked after it',
      () async {
        var epoch = 0;
        var open = false;
        final h = await Harness.create(
          appUserId: 'alice',
          server: FakeServer()..online(),
          accountEpoch: () => epoch,
          appreferId: () async => open ? 'device-1' : null,
        );
        await h.engine.customerInfo(FetchPolicy.fetchCurrent); // collection off
        epoch++;
        open = true; // configure for the next user, Billing still on alice
        await h.engine.customerInfo(FetchPolicy.fetchCurrent);
        await h.engine.customerInfo(FetchPolicy.fetchCurrent);
        expect(
          h.server.bodiesFor(customers),
          hasLength(1),
          reason: 'no re-link',
        );
        await h.engine.logIn('bob');
        await h.engine.customerInfo(FetchPolicy.fetchCurrent);
        final bob = h.server.bodiesFor(customers).last;
        expect(bob['appUserId'], 'bob');
        expect(bob['appreferId'], 'device-1');
        expect(h.server.bodiesFor(customers), hasLength(2));
      },
    );

    test('a purchase owned by someone else gets no device id', () async {
      final h = await Harness.create(
        appUserId: 'alice',
        server: FakeServer()..online(),
      );
      await h.engine.process(
        h.store.applePurchase('t1', 'pro_yearly'),
        appUserId: 'zoe',
      );
      final purchase = h.server.bodiesFor(purchases).single;
      expect(purchase['appUserId'], 'zoe');
      expect(purchase.containsKey('appreferId'), isFalse);
      await h.engine.process(h.store.applePurchase('t2', 'pro_yearly'));
      expect(h.server.bodiesFor(purchases).last['appreferId'], 'device-1');
    });
  });

  group('4. identify sends link', () {
    const identify = '/api/billing/v1/identify';
    Future<Harness> anonymous() => Harness.create(
      server: FakeServer()..online(),
      appreferId: AppReferRegistry.linkableDeviceId,
      linkAllowed: AppReferRegistry.linkAllowed,
    );

    test('true when configured', () async {
      await configure();
      final h = await anonymous();
      await h.engine.logIn('u1');
      expect(h.server.bodiesFor(identify).single['link'], isTrue);
    });

    test('false while collection is off', () async {
      await configure();
      await AppReferSDK.setCollectionEnabled(false);
      final h = await anonymous();
      await h.engine.logIn('u1');
      expect(h.server.bodiesFor(identify).single['link'], isFalse);
    });

    test(
      'false after reset until configure, and in Billing-only apps',
      () async {
        final billingOnly = await anonymous();
        await billingOnly.engine.logIn('u0');
        expect(billingOnly.server.bodiesFor(identify).single['link'], isFalse);
        await configure();
        await AppReferSDK.reset();
        final h = await anonymous();
        await h.engine.logIn('u1');
        expect(h.server.bodiesFor(identify).single['link'], isFalse);
      },
    );

    test('a gate that throws sends false', () async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        linkAllowed: () async => throw StateError('prefs'),
      );
      await h.engine.logIn('u1');
      expect(h.server.bodiesFor(identify).single['link'], isFalse);
    });
  });

  group('5. BillingApiClient gate errors', () {
    test(
      'a failing gate is read as closed and never breaks the request',
      () async {
        final hosts = <String>[];
        final client = BillingApiClient(
          baseUrls: const ['https://trk.apprefer.com', 'https://apprefer.com'],
          apiKey: () => 'pk_test',
          keyWaitAttempts: 0,
          linkAllowed: () async => throw StateError('prefs unreadable'),
          client: MockClient((r) async {
            hosts.add(r.url.origin);
            return http.Response(
              jsonEncode({'appUserId': 'u1', 'entitlements': {}}),
              200,
            );
          }),
        );
        final json = await client.sendRaw(const GetCustomer('u1'));
        expect(json['appUserId'], 'u1');
        expect(hosts, ['https://apprefer.com']);
      },
    );
  });
}
