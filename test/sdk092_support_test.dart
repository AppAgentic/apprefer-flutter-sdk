import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/services/storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The public `AppReferSDK.support.clearIdentity()`, over the mocked secure
/// store channel and HTTP.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.apprefer.sdk/support');
  final secure = <String, String>{};
  final requests = <http.Request>[];
  var minted = 0;
  setUp(() {
    SharedPreferences.setMockInitialValues({'apprefer_user_id': 'acct_A'});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'read':
              return secure[call.arguments as String];
            case 'write':
              final args = Map<String, dynamic>.from(call.arguments as Map);
              final value = args['value'] as String?;
              if (value == null) {
                secure.remove(args['key']);
              } else {
                secure[args['key'] as String] = value;
              }
              return null;
            case 'keys':
              return secure.keys.toList();
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'clearIdentity moves the push token to a new anonymous session',
    () async {
      await http.runWithClient(
        () async {
          final support = AppReferSDK.support;
          support.configure(apiKey: 'pk_support');
          await support.identify(name: 'Sam', email: 'sam@example.test');
          await support.registerPushToken('fcm-1', environment: 'sandbox');
          final first = requests.firstWhere(
            (r) => r.url.path.endsWith('/session'),
          );
          expect(jsonDecode(first.body)['appUserId'], 'acct_A');
          final old = requests.last.headers['X-AppRefer-Support-Session'];
          final generation = support.accountGeneration.value;

          await support.clearIdentity();
          expect(support.accountGeneration.value, generation + 1);
          final sessions = [
            for (final r in requests)
              if (r.method == 'POST' && r.url.path.endsWith('/session')) r,
          ];
          final fresh = jsonDecode(sessions.last.body) as Map<String, dynamic>;
          expect(sessions.last.headers['X-AppRefer-Support-Session'], isNull);
          expect(fresh.containsKey('appUserId'), isFalse);
          expect(fresh.containsKey('name'), isFalse);
          expect(fresh.containsKey('email'), isFalse);
          final push = requests.last;
          expect(push.url.path, '/api/support/v1/push-token');
          expect(jsonDecode(push.body)['token'], 'fcm-1');
          expect(jsonDecode(push.body)['environment'], 'sandbox');
          expect(push.headers['X-AppRefer-Support-Session'], isNot(old));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(
            requests.any(
              (r) =>
                  r.method == 'DELETE' &&
                  r.headers['X-AppRefer-Support-Session'] == old,
            ),
            isTrue,
          );
          final storage = AppReferStorage();
          await storage.init();
          expect(storage.supportIdentityCleared, isTrue);
          expect(storage.getUserId(), 'acct_A');
        },
        () => MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/session') && r.method == 'POST') {
            final header = r.headers['X-AppRefer-Support-Session'];
            return http.Response(
              jsonEncode({'session': header ?? 'ars_${++minted}'}),
              200,
            );
          }
          return http.Response('{"conversations":[]}', 200);
        }),
      );
    },
  );
}
