import 'dart:async';
import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:flutter/foundation.dart';
import 'package:apprefer/src/services/identity_sync.dart';
import 'package:apprefer/src/services/http_client.dart';
import 'package:apprefer/src/services/logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await AppReferSDK.disposeForTesting();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await AppReferSDK.disposeForTesting();
    debugDefaultTargetPlatformOverride = null;
  });
  AppReferHttpClient client() => AppReferHttpClient(
    baseUrl: 'https://apprefer.com',
    apiKey: 'pk_test',
    logger: const AppReferLogger(),
  );
  test(
    'logout persists a later revision while A is in flight; old ack cannot clear pending logout',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final bodies = <Map<String, dynamic>>[];
      await http.runWithClient(
        () async {
          final a = IdentitySync.replace(client(), 'device', 'A', {
            'em': 'a' * 64,
          });
          await entered.future;
          final logout = expectLater(
            IdentitySync.replace(client(), 'device', null, {}),
            throwsStateError,
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final prefs = await SharedPreferences.getInstance();
          expect(
            jsonDecode(
              prefs.getString('apprefer_identity_pending')!,
            )['user_id'],
            isNull,
          );
          release.complete();
          await Future.wait([a, logout]);
          expect(
            bodies[1]['revision'],
            greaterThan(bodies[0]['revision'] as int),
          );
        },
        () => MockClient((r) async {
          final body = Map<String, dynamic>.from(jsonDecode(r.body));
          bodies.add(body);
          if (body['user_id'] == 'A') {
            entered.complete();
            await release.future;
          }
          if (body['user_id'] == null)
            return http.Response(
              '{}',
              200,
            ); // preserve failed logout for relaunch
          return http.Response(jsonEncode({'revision': body['revision']}), 200);
        }),
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('apprefer_identity_pending'), isNotNull);
      await http.runWithClient(
        () => IdentitySync.retry(client()),
        () => MockClient((r) async {
          final body = jsonDecode(r.body);
          expect(body['user_id'], isNull);
          return http.Response(jsonEncode({'revision': body['revision']}), 200);
        }),
      );
      expect(prefs.getString('apprefer_identity_pending'), isNull);
    },
  );
  test(
    'real SDK signed-out upgrade clears account; A to B snapshots omit old hashes; reset is not blocked by HTTP',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      SharedPreferences.setMockInitialValues({
        'apprefer_user_id': 'old-A',
        'apprefer_device_id': 'preserved-device',
      });
      final snapshots = <Map<String, dynamic>>[];
      final clearEntered = Completer<void>(), clearRelease = Completer<void>();
      var delayLogout = false;
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(
            const AppReferConfig(
              apiKey: 'pk_test',
              synchronizeIdentity: true,
              automaticConversionValues: false,
            ),
          );
          expect(snapshots.last['user_id'], isNull);
          await AppReferSDK.setIdentity(
            userId: 'A',
            email: 'a@example.invalid',
            lastName: 'Alpha',
          );
          await AppReferSDK.setIdentity(userId: 'B', firstName: 'Beta');
          expect((snapshots.last['advanced_matching'] as Map).keys, ['fn']);
          delayLogout = true;
          await AppReferSDK.reset().timeout(const Duration(seconds: 2));
          await clearEntered.future;
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('apprefer_user_id'), isNull);
          expect(prefs.getString('apprefer_device_id'), 'preserved-device');
          clearRelease.complete();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        },
        () => MockClient((r) async {
          if (r.url.path.endsWith('/identity')) {
            final body = Map<String, dynamic>.from(jsonDecode(r.body));
            snapshots.add(body);
            if (delayLogout && body['user_id'] == null) {
              clearEntered.complete();
              await clearRelease.future;
            }
            return http.Response(
              jsonEncode({'revision': body['revision']}),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
    },
  );
  test('concurrent configure A then B never commits A after B', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final entered = Completer<void>(), release = Completer<void>();
    final snapshots = <Map<String, dynamic>>[];
    await http.runWithClient(
      () async {
        final a = AppReferSDK.configure(
          const AppReferConfig(
            apiKey: 'pk_test',
            userId: 'A',
            synchronizeIdentity: true,
            automaticConversionValues: false,
          ),
        );
        await entered.future;
        await AppReferSDK.configure(
          const AppReferConfig(
            apiKey: 'pk_test',
            userId: 'B',
            synchronizeIdentity: true,
            automaticConversionValues: false,
          ),
        );
        release.complete();
        await a;
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('apprefer_user_id'), 'B');
        expect(snapshots.last['user_id'], 'B');
        expect(snapshots.where((s) => s['user_id'] == 'A'), isEmpty);
      },
      () => MockClient((r) async {
        final body = Map<String, dynamic>.from(jsonDecode(r.body));
        if (r.url.path.endsWith('/configure') &&
            body['customer_user_id'] == 'A') {
          entered.complete();
          await release.future;
        }
        if (r.url.path.endsWith('/identity')) {
          snapshots.add(body);
          return http.Response(jsonEncode({'revision': body['revision']}), 200);
        }
        return http.Response('{}', 200);
      }),
    );
  });
  test(
    'newer sign in wins concurrent reset local and remote cleanup',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final snapshots = <Map<String, dynamic>>[];
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(
            const AppReferConfig(
              apiKey: 'pk_test',
              userId: 'A',
              synchronizeIdentity: true,
              automaticConversionValues: false,
            ),
          );
          final reset = AppReferSDK.reset();
          final signin = AppReferSDK.setIdentity(userId: 'B');
          await Future.wait([reset, signin]);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('apprefer_user_id'), 'B');
          expect(snapshots.last['user_id'], 'B');
        },
        () => MockClient((r) async {
          if (r.url.path.endsWith('/identity')) {
            final body = Map<String, dynamic>.from(jsonDecode(r.body));
            snapshots.add(body);
            return http.Response(
              jsonEncode({'revision': body['revision']}),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
    },
  );
  test(
    'revision conflict is explicit; next authoritative call advances above server',
    () async {
      var conflict = true;
      var serverRevision = 0;
      final bodies = <Map<String, dynamic>>[];
      await http.runWithClient(
        () async {
          await expectLater(
            IdentitySync.replace(client(), 'device', null, {}),
            throwsStateError,
          );
          conflict = false;
          await IdentitySync.replace(client(), 'device', null, {});
          expect(bodies.last['revision'], greaterThan(serverRevision));
        },
        () => MockClient((r) async {
          final body = Map<String, dynamic>.from(jsonDecode(r.body));
          bodies.add(body);
          if (conflict) {
            serverRevision = (body['revision'] as int) + 1000;
            return http.Response(jsonEncode({'revision': serverRevision}), 200);
          }
          return http.Response(jsonEncode({'revision': body['revision']}), 200);
        }),
      );
    },
  );
  test(
    'cold simultaneous identical opt-in configure initializes an owner',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final snapshots = <Map<String, dynamic>>[];
      await http.runWithClient(
        () async {
          const config = AppReferConfig(
            apiKey: 'pk_test',
            userId: 'B',
            synchronizeIdentity: true,
            automaticConversionValues: false,
          );
          await Future.wait([
            AppReferSDK.configure(config),
            AppReferSDK.configure(config),
          ]);
          await AppReferSDK.setIdentity(userId: 'B');
          expect(snapshots.last['user_id'], 'B');
        },
        () => MockClient((r) async {
          if (r.url.path.endsWith('/identity')) {
            final body = Map<String, dynamic>.from(jsonDecode(r.body));
            snapshots.add(body);
            return http.Response(
              jsonEncode({'revision': body['revision']}),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
    },
  );
  test(
    'retry after denied consent strips persisted matching before first-party delivery',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('apprefer_tracking_consent', 'denied');
      await prefs.setInt('apprefer_identity_revision', 7);
      await prefs.setString(
        'apprefer_identity_pending',
        jsonEncode({
          'device_id': 'device',
          'revision': 7,
          'user_id': 'B',
          'advanced_matching': {'em': 'a' * 64},
        }),
      );
      await http.runWithClient(
        () => IdentitySync.retry(client()),
        () => MockClient((r) async {
          final body = jsonDecode(r.body);
          expect(body['advanced_matching'], isEmpty);
          return http.Response(jsonEncode({'revision': 7}), 200);
        }),
      );
    },
  );
}
