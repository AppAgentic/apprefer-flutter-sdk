import 'dart:async';
import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/services/registry.dart';
import 'package:apprefer/src/services/storage.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'billing/support.dart';

const customers = '/api/billing/v1/customers';
const purchases = '/api/billing/v1/purchases';
const identify = '/api/billing/v1/identify';
const marker = 'apprefer_billing_reset_user';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  round2C();
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

  Future<Map<String, Object>> disk() async {
    final prefs = await SharedPreferences.getInstance();
    return {for (final k in prefs.getKeys()) k: prefs.get(k)!};
  }

  /// The app is killed and launched again with what was on disk: a new
  /// engine (its in-process account epoch is current again), then configure.
  Future<Harness> relaunch(
    Map<String, Object> saved, {
    String? appUserId,
  }) async {
    await AppReferSDK.disposeForTesting();
    final h = await Harness.create(
      prefs: saved,
      appUserId: appUserId,
      server: FakeServer()..online(),
      appreferId: AppReferRegistry.linkableDeviceId,
      linkAllowed: AppReferRegistry.linkAllowed,
    );
    await configure();
    return h;
  }

  group('Fix 2. the Billing reset gate survives a relaunch', () {
    test('reset() without logOut: after a relaunch the previous user gets no '
        'device id and is not re-linked until logIn', () async {
      final h = await Harness.create(
        appUserId: 'alice',
        server: FakeServer()..online(),
        appreferId: AppReferRegistry.linkableDeviceId,
      );
      await configure();
      final device = (await SharedPreferences.getInstance()).getString(
        'apprefer_device_id',
      )!;
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(h.server.bodiesFor(customers).single['appreferId'], device);

      await AppReferSDK.reset();
      expect((await disk())[marker], 'alice');

      final next = await relaunch(await disk(), appUserId: 'alice');
      next.engine.setAttributes({r'$email': 'a@b.com', r'$idfa': 'IDFA'});
      await next.engine.customerInfo(FetchPolicy.fetchCurrent);
      await next.engine.customerInfo(FetchPolicy.fetchCurrent);
      await next.engine.process(next.store.applePurchase('t1', 'pro_yearly'));
      final registered = next.server.bodiesFor(customers);
      expect(registered, hasLength(1), reason: 'no re-link for alice');
      expect(registered.single.containsKey('appreferId'), isFalse);
      expect(registered.single['attributes'], {r'$email': 'a@b.com'});
      expect(
        next.server.bodiesFor(purchases).single.containsKey('appreferId'),
        isFalse,
      );

      // The app says who the user is now (same id): marker cleared, linked.
      await next.engine.logIn('alice');
      expect((await disk()).containsKey(marker), isFalse);
      await next.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(next.server.bodiesFor(customers).last['appreferId'], device);
    });

    test('an anonymous Billing user at reset() is held too; logOut clears '
        'it', () async {
      final h = await Harness.create(
        server: FakeServer()..online(),
        appreferId: AppReferRegistry.linkableDeviceId,
      );
      await configure();
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      final anon = h.engine.currentAppUserId;
      expect(anon, startsWith(BillingStorage.anonymousPrefix));
      await AppReferSDK.reset();
      expect((await disk())[marker], anon);

      final next = await relaunch(await disk());
      expect(next.engine.currentAppUserId, anon);
      await next.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(
        next.server.bodiesFor(customers).single.containsKey('appreferId'),
        isFalse,
      );
      await next.engine.logOut();
      expect((await disk()).containsKey(marker), isFalse);
      await next.engine.customerInfo(FetchPolicy.fetchCurrent);
      final fresh = next.server.bodiesFor(customers).last;
      expect(fresh['appUserId'], isNot(anon));
      expect(fresh['appreferId'], isNotNull);
    });

    test('a different Billing user clears the marker and is linked', () async {
      final h = await Harness.create(
        appUserId: 'alice',
        server: FakeServer()..online(),
      );
      await h.engine.customerInfo(FetchPolicy.fetchCurrent);
      await AppReferSDK.reset();
      final next = await relaunch(await disk(), appUserId: 'bob');
      expect((await disk()).containsKey(marker), isFalse);
      await next.engine.customerInfo(FetchPolicy.fetchCurrent);
      final bob = next.server.bodiesFor(customers).single;
      expect(bob['appUserId'], 'bob');
      expect(bob['appreferId'], isNotNull);
    });

    test('identify sends link: false while the marker names the current '
        'user', () async {
      final saved = <String, Object>{
        'apprefer_billing_anonymous_id': r'$ARAnon:SPARKLY-1',
        'apprefer_billing_app_user_id': 'alice',
        'apprefer_billing_pending_identifies': jsonEncode([
          {'anonymousId': r'$ARAnon:SPARKLY-1', 'appUserId': 'alice'},
        ]),
        marker: 'alice',
      };
      final next = await relaunch(saved);
      expect(await AppReferRegistry.linkAllowed(), isTrue);
      await next.engine.customerInfo(FetchPolicy.fetchCurrent);
      expect(next.server.bodiesFor(identify).single['link'], isFalse);
    });

    test('reset() before Billing was ever configured stores nothing', () async {
      await configure();
      await AppReferSDK.reset();
      expect((await disk()).containsKey(marker), isFalse);
    });
  });

  group(
    'Round 2 A. the reset marker never names a user set by logIn/logOut',
    () {
      test(
        'logOut() before reset(): the fresh anonymous user is not marked and '
        'is linked after a relaunch',
        () async {
          final h = await Harness.create(
            appUserId: 'alice',
            server: FakeServer()..online(),
            appreferId: AppReferRegistry.linkableDeviceId,
          );
          await configure();
          await h.engine.logOut();
          final fresh = h.engine.currentAppUserId;
          await AppReferSDK.reset();
          expect((await disk()).containsKey(marker), isFalse);
          final next = await relaunch(await disk());
          expect(next.engine.currentAppUserId, fresh);
          await next.engine.customerInfo(FetchPolicy.fetchCurrent);
          expect(
            next.server.bodiesFor(customers).single['appreferId'],
            isNotNull,
          );
        },
      );

      test('logOut() while reset() is still running: no marker', () async {
        final h = await Harness.create(
          appUserId: 'alice',
          server: FakeServer()..online(),
        );
        final resetting = AppReferSDK.reset();
        await h.engine.logOut();
        await resetting;
        expect((await disk()).containsKey(marker), isFalse);
      });

      test('logIn() while reset() is still running: the new user is not '
          'marked', () async {
        final h = await Harness.create(
          appUserId: 'alice',
          server: FakeServer()..online(),
        );
        final resetting = AppReferSDK.reset();
        await h.engine.logIn('bob');
        await resetting;
        expect((await disk()).containsKey(marker), isFalse);
      });

      test('a logIn user is still marked by a later reset(), even after an '
          'earlier logOut', () async {
        final h = await Harness.create(
          appUserId: 'alice',
          server: FakeServer()..online(),
        );
        await h.engine.logOut();
        await h.engine.logIn('carol');
        await AppReferSDK.reset();
        expect((await disk())[marker], 'carol');
      });

      test('an anonymous id not minted by logOut is still marked', () async {
        final h = await Harness.create(server: FakeServer()..online());
        final anon = h.engine.currentAppUserId;
        await AppReferSDK.reset();
        expect((await disk())[marker], anon);
      });
    },
  );

  group('Fix 3. a re-registered push token held by a pending revocation', () {
    late Map<String, String> secure;
    late List<http.Request> requests;
    late int minted;
    late int deleteStatus;
    Completer<void>? deleteGate;
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
            jsonEncode({'session': header ?? 'ars_093_${++minted}'}),
            200,
          );
        }
        if (r.url.path.endsWith('/session') && r.method == 'DELETE') {
          await deleteGate?.future;
          return http.Response('{}', deleteStatus);
        }
        return http.Response('{"conversations":[]}', 200);
      }),
    );
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

    /// What `AppReferSupport.registerPushToken` does with the API.
    Future<void> register(
      SupportAPI api,
      String token,
      String environment,
    ) async {
      final epoch = api.actionGeneration;
      if (await api.deferPushRegistration(
        token,
        epoch,
        environment: environment,
      )) {
        api.resumeRevocations();
        return;
      }
      await api.call('POST', '/push-token', {
        'platform': 'ios',
        'token': token,
        'environment': environment,
      }, epoch);
      await api.persistPushToken(token, epoch, environment: environment);
    }

    setUp(() {
      secure = {};
      requests = [];
      minted = 0;
      deleteStatus = 200;
      deleteGate = null;
    });

    test('a token saved by 0.9.1 (no environment) waits for the revocation, '
        'then moves with the environment now known', () async {
      secure['apprefer_revocations'] = jsonEncode([
        {
          'token': 'ars_old',
          'key': 'pk_test',
          'push': 'apns-091',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'attempts': 0,
        },
      ]);
      secure['support_pk_test.push'] = 'apns-091';
      deleteStatus = 503;
      final api = make();
      await register(api, 'apns-091', 'sandbox');
      await settle();
      expect(deleteOf('ars_old'), isNot(-1));
      expect(pushPosts(), isEmpty, reason: 'the old session still holds it');
      final entry =
          (jsonDecode(secure['apprefer_revocations']!) as List).single;
      expect(entry['move'], isTrue);
      expect(entry['environment'], 'sandbox');
      expect(secure['support_pk_test.pushEnv'], 'sandbox');

      deleteStatus = 200;
      requests.clear();
      api.resumeRevocations();
      await settle();
      final push = pushPosts().single;
      expect(deleteOf('ars_old'), lessThan(requests.indexOf(push)));
      expect(jsonDecode(push.body)['token'], 'apns-091');
      expect(jsonDecode(push.body)['environment'], 'sandbox');
      expect(push.headers['X-AppRefer-Support-Session'], isNot('ars_old'));
    });

    test('registered while the revocation request is in flight: moved once it '
        'succeeds, never lost or posted early', () async {
      secure['apprefer_revocations'] = jsonEncode([
        {
          'token': 'ars_old',
          'key': 'pk_test',
          'push': 'fcm-1',
          'createdAt': DateTime.now().millisecondsSinceEpoch,
          'attempts': 0,
        },
      ]);
      deleteGate = Completer<void>();
      final api = make();
      api.resumeRevocations();
      await settle();
      expect(deleteOf('ars_old'), isNot(-1));
      await register(api, 'fcm-1', 'production');
      await settle();
      expect(pushPosts(), isEmpty);
      deleteGate!.complete();
      await settle();
      final push = pushPosts().single;
      expect(deleteOf('ars_old'), lessThan(requests.indexOf(push)));
      expect(jsonDecode(push.body)['environment'], 'production');
      expect(jsonDecode(secure['apprefer_revocations']!), isEmpty);
    });

    test('no pending revocation holds it: posted at once', () async {
      final api = make();
      await register(api, 'fcm-2', 'production');
      expect(pushPosts(), hasLength(1));
    });
  });

  group('Fix 1 (already in Flutter). a revocation queued during a pass runs '
      'in the same session', () {
    test('a cleared session retired while a pass runs is revoked after '
        'it', () async {
      final secure = <String, String>{};
      final requests = <http.Request>[];
      var minted = 0;
      var gate = Completer<void>();
      final api = SupportAPI(
        apiKey: () => 'pk_test',
        read: (k) async => secure[k],
        write: (k, v) async => v == null ? secure.remove(k) : secure[k] = v,
        keys: () async => secure.keys.toList(),
        client: MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/session') && r.method == 'POST') {
            final header = r.headers['X-AppRefer-Support-Session'];
            return http.Response(
              jsonEncode({'session': header ?? 'ars_r_${++minted}'}),
              200,
            );
          }
          if (r.method == 'DELETE') await gate.future;
          return http.Response('{"conversations":[]}', 200);
        }),
      );
      await AppReferSDK.setUserId('acct_A');
      await api.conversations();
      final storage = AppReferStorage();
      await storage.init();
      await storage.setSupportIdentityCleared(true);
      await api.clearIdentity(); // pass 1 starts: DELETE ars_r_1 waits
      await api.conversations(); // anonymous ars_r_2
      final cleared = requests.last.headers['X-AppRefer-Support-Session'];
      expect(cleared, 'ars_r_2');
      await AppReferSDK.setUserId('acct_B');
      await api.conversations(); // retires ars_r_2 while pass 1 runs
      gate.complete();
      gate = Completer<void>()..complete();
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        requests.any(
          (r) =>
              r.method == 'DELETE' &&
              r.headers['X-AppRefer-Support-Session'] == cleared,
        ),
        isTrue,
      );
    });
  });
}

void round2C() {
  group('Round 2 C. a revocation requested as a pass ends still runs', () {
    test('every point in the hand-off window', () async {
      for (var hops = 0; hops < 40; hops++) {
        final secure = <String, String>{
          'apprefer_revocations': jsonEncode([
            {
              'token': 'ars_first',
              'key': 'pk_test',
              'createdAt': DateTime.now().millisecondsSinceEpoch,
              'attempts': 0,
            },
          ]),
        };
        final deleted = <String?>[];
        late SupportAPI api;
        var armed = true;
        api = SupportAPI(
          apiKey: () => 'pk_test',
          read: (k) async => secure[k],
          write: (k, v) async {
            v == null ? secure.remove(k) : secure[k] = v;
            if (k == 'apprefer_revocations' && v == '[]' && armed) {
              armed = false;
              // A second revocation is queued a few microtasks later.
              Future<void> later(int n) async {
                for (var i = 0; i < n; i++) {
                  await Future<void>.value();
                }
                secure['apprefer_revocations'] = jsonEncode([
                  {
                    'token': 'ars_second',
                    'key': 'pk_test',
                    'createdAt': DateTime.now().millisecondsSinceEpoch,
                    'attempts': 0,
                  },
                ]);
                api.resumeRevocations();
              }

              unawaited(later(hops));
            }
          },
          keys: () async => secure.keys.toList(),
          client: MockClient((r) async {
            if (r.method == 'DELETE') {
              deleted.add(r.headers['X-AppRefer-Support-Session']);
            }
            return http.Response('{}', 200);
          }),
        );
        api.resumeRevocations();
        for (var i = 0; i < 100; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(deleted, ['ars_first', 'ars_second'], reason: 'hops=$hops');
      }
    });
  });
}
