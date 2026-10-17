import 'dart:async';
import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 0.10.1: the APNs environment comes from the iOS plugin's reading of the
/// app's signing (never DEBUG); explicit choices still win.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> secure;
  late List<http.Request> requests;
  var minted = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    secure = {};
    requests = [];
    minted = 0;
  });

  SupportAPI make({
    bool isIOS = true,
    Future<String?> Function()? detect,
    Map<String, dynamic>? status,
  }) => SupportAPI(
    apiKey: () => 'pk_test',
    isIOS: isIOS,
    detectPushEnvironment: detect,
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
          jsonEncode({'session': header ?? 'ars_${++minted}'}),
          200,
        );
      }
      if (r.url.path.endsWith('/status')) {
        return http.Response(jsonEncode(status ?? {}), 200, headers: {
          'cache-control': 'private, max-age=300',
        });
      }
      return http.Response('{}', 200);
    }),
  );

  List<http.Request> pushPosts() => [
    for (final r in requests)
      if (r.method == 'POST' && r.url.path.endsWith('/push-token')) r,
  ];
  String? postedEnvironment() =>
      jsonDecode(pushPosts().single.body)['environment'] as String?;

  group('detected environment', () {
    // Fixture readings from the iOS plugin (PushEnvironmentDetector):
    // development-signed Release → sandbox; production-signed Debug or
    // Release → production; no/malformed profile → production; Simulator →
    // sandbox.
    for (final c in [
      ('development-signed Release', 'sandbox'),
      ('production-signed Debug', 'production'),
      ('production-signed Release', 'production'),
      ('absent or malformed profile', 'production'),
      ('Simulator', 'sandbox'),
    ]) {
      test('${c.$1} registers ${c.$2}', () async {
        final api = make(detect: () async => c.$2);
        await api.registerPushToken('apns-1', api.actionGeneration);
        expect(postedEnvironment(), c.$2);
        expect(jsonDecode(pushPosts().single.body)['platform'], 'ios');
        expect(secure['support_pk_test.pushEnv'], c.$2);
      });
    }

    test('a failed or unknown plugin answer is production, and is retried',
        () async {
      var calls = 0;
      final answers = <Future<String?> Function()>[
        () async => throw PlatformException(code: 'x'),
        () async => 'staging',
        () async => 'sandbox',
      ];
      final api = make(detect: () => answers[calls++]());
      expect(await api.pushEnvironment(), 'production');
      expect(await api.pushEnvironment(), 'production');
      expect(await api.pushEnvironment(), 'sandbox');
      expect(await api.pushEnvironment(), 'sandbox');
      expect(calls, 3, reason: 'a valid answer is cached');
    });

    test('a missing plugin method is production', () async {
      final api = make(
        detect: () async => throw MissingPluginException('pushEnvironment'),
      );
      expect(await api.pushEnvironment(), 'production');
    });

    test('Android never asks the plugin and stays production', () async {
      var asked = false;
      final api = make(
        isIOS: false,
        detect: () async {
          asked = true;
          return 'sandbox';
        },
      );
      await api.registerPushToken('fcm-1', api.actionGeneration);
      expect(asked, isFalse);
      expect(postedEnvironment(), 'production');
      expect(jsonDecode(pushPosts().single.body)['platform'], 'android');
    });
  });

  group('explicit overrides', () {
    test('a per-call environment wins over detection and the app setting',
        () async {
      var asked = false;
      final api = make(
        detect: () async {
          asked = true;
          return 'sandbox';
        },
      )..pushEnvironmentOverride = 'sandbox';
      await api.registerPushToken(
        'apns-1',
        api.actionGeneration,
        environment: 'production',
      );
      expect(postedEnvironment(), 'production');
      expect(asked, isFalse);
    });

    test('the app setting wins over detection', () async {
      final api = make(detect: () async => 'sandbox')
        ..pushEnvironmentOverride = 'production';
      await api.registerPushToken('apns-1', api.actionGeneration);
      expect(postedEnvironment(), 'production');
      api.pushEnvironmentOverride = null;
      expect(await api.pushEnvironment(), 'sandbox');
    });

    test('AppReferSupport.pushEnvironment validates and sets the override',
        () {
      final support = AppReferSDK.support;
      final before = support.pushEnvironment;
      addTearDown(() => support.pushEnvironment = before);
      support.pushEnvironment = 'sandbox';
      expect(support.api.pushEnvironmentOverride, 'sandbox');
      support.pushEnvironment = null;
      expect(support.api.pushEnvironmentOverride, isNull);
      expect(() => support.pushEnvironment = 'staging', throwsArgumentError);
    });
  });

  group('readiness uses the same environment', () {
    Map<String, dynamic> statusJson(bool production, bool sandbox) => {
      'push': {
        'ios': {
          'configured': true,
          'verified': true,
          'environments': {'production': production, 'sandbox': sandbox},
        },
        'android': {'configured': true, 'verified': true},
      },
    };

    test('development-signed build: only the sandbox verdict counts', () async {
      final api = make(
        detect: () async => 'sandbox',
        status: statusJson(false, true),
      );
      final status = await api.help.status();
      expect(status.pushEnvironment, 'sandbox');
      expect(status.pushReady, isTrue);
    });

    test('production build with sandbox rejected is still ready', () async {
      final api = make(
        detect: () async => 'production',
        status: statusJson(true, false),
      );
      expect((await api.help.status()).pushReady, isTrue);
    });

    test('the override applies to a cached status too', () async {
      final api = make(
        detect: () async => 'production',
        status: statusJson(true, false),
      );
      expect((await api.help.status()).pushReady, isTrue);
      api.pushEnvironmentOverride = 'sandbox';
      expect((await api.help.status()).pushReady, isFalse);
      expect(
        requests.where((r) => r.url.path.endsWith('/status')),
        hasLength(1),
        reason: 'served from the cache',
      );
    });

    test('unknown environment fails closed on either rejection', () {
      final status = AppReferSupportStatus.fromJson(
        statusJson(true, false),
        isIOS: true,
      );
      expect(status.pushEnvironment, isNull);
      expect(status.pushReady, isFalse);
      expect(status.withPushEnvironment('production').pushReady, isTrue);
    });

    test('Android readiness ignores APNs environments', () async {
      final api = make(isIOS: false, status: statusJson(false, false));
      final status = await api.help.status();
      expect(status.pushEnvironment, isNull);
      expect(status.pushReady, isTrue);
    });
  });

  group('reset and account switch while the plugin answers', () {
    for (final c in [
      ('reset()', (SupportAPI api) => api.reset()),
      ('clearIdentity()', (SupportAPI api) => api.clearIdentity()),
    ]) {
      test('${c.$1} during detection: nothing is posted or saved', () async {
        final gate = Completer<String?>();
        final api = make(detect: () => gate.future);
        final epoch = api.actionGeneration;
        final registering = api.registerPushToken('apns-old', epoch);
        await Future<void>.delayed(Duration.zero);
        await c.$2(api);
        expect(api.actionGeneration, epoch + 1);
        gate.complete('sandbox');
        await expectLater(
          registering,
          throwsA(
            isA<SupportException>().having(
              (e) => e.reason,
              'reason',
              SupportErrorReason.reset,
            ),
          ),
        );
        expect(pushPosts(), isEmpty);
        expect(secure['support_pk_test.push'], isNull);
        expect(secure['support_pk_test.pushEnv'], isNull);

        // The next account's own registration uses the detected environment.
        await api.registerPushToken('apns-new', api.actionGeneration);
        expect(jsonDecode(pushPosts().single.body)['token'], 'apns-new');
        expect(postedEnvironment(), 'sandbox');
      });
    }

    test('concurrent registrations share one plugin call', () async {
      var calls = 0;
      final gate = Completer<String?>();
      final api = make(
        detect: () {
          calls++;
          return gate.future;
        },
      );
      final a = api.registerPushToken('apns-1', api.actionGeneration);
      final b = api.registerPushToken('apns-1', api.actionGeneration);
      gate.complete('sandbox');
      await Future.wait([a, b]);
      expect(calls, 1);
      expect(pushPosts(), hasLength(2));
      for (final p in pushPosts()) {
        expect(jsonDecode(p.body)['environment'], 'sandbox');
      }
    });
  });
}
