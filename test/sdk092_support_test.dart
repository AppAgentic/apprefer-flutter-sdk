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

  var deleteStatus = 200;
  Future<http.Response> server(http.Request r) async {
    requests.add(r);
    if (r.url.path.endsWith('/session') && r.method == 'POST') {
      final header = r.headers['X-AppRefer-Support-Session'];
      return http.Response(
        jsonEncode({'session': header ?? 'ars_${++minted}'}),
        200,
      );
    }
    if (r.url.path.endsWith('/session') && r.method == 'DELETE') {
      return http.Response('{}', deleteStatus);
    }
    return http.Response('{"conversations":[]}', 200);
  }

  Future<void> settle() async {
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

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
  setUp(() {
    secure.clear();
    requests.clear();
    deleteStatus = 200;
  });

  test('clearIdentity moves the push token to a new anonymous session after '
      'the old one is revoked', () async {
    await http.runWithClient(() async {
      final support = AppReferSDK.support;
      support.configure(apiKey: 'pk_support');
      await support.identify(name: 'Sam', email: 'sam@example.test');
      await support.registerPushToken('fcm-1', environment: 'sandbox');
      final first = requests.firstWhere((r) => r.url.path.endsWith('/session'));
      expect(jsonDecode(first.body)['appUserId'], 'acct_A');
      final old = requests.last.headers['X-AppRefer-Support-Session'];
      final generation = support.accountGeneration.value;
      requests.clear();

      await support.clearIdentity();
      expect(support.accountGeneration.value, generation + 1);
      final sessions = [
        for (final r in requests)
          if (r.method == 'POST' && r.url.path.endsWith('/session')) r,
      ];
      final fresh = jsonDecode(sessions.last.body) as Map<String, dynamic>;
      expect(sessions.last.headers['X-AppRefer-Support-Session'], isNull);
      expect(fresh.containsKey('appUserId'), isFalse);
      expect(fresh.containsKey('deviceId'), isFalse);
      expect(fresh.containsKey('name'), isFalse);
      expect(fresh.containsKey('email'), isFalse);
      await settle();
      final push = pushPosts().single;
      expect(deleteOf(old), isNot(-1));
      expect(deleteOf(old), lessThan(requests.indexOf(push)));
      expect(jsonDecode(push.body)['token'], 'fcm-1');
      expect(jsonDecode(push.body)['environment'], 'sandbox');
      expect(push.headers['X-AppRefer-Support-Session'], isNot(old));
      final storage = AppReferStorage();
      await storage.init();
      expect(await storage.isSupportIdentityCleared(), isTrue);
      expect(storage.getUserId(), 'acct_A');
    }, () => MockClient(server));
  });

  test(
    'registerPushToken waits for the move while the old session is not revoked',
    () async {
      await http.runWithClient(() async {
        final support = AppReferSDK.support;
        support.configure(apiKey: 'pk_support');
        await support.registerPushToken('fcm-2', environment: 'production');
        final old = requests.last.headers['X-AppRefer-Support-Session'];
        deleteStatus = 503;
        requests.clear();
        await support.clearIdentity();
        await settle();
        expect(deleteOf(old), isNot(-1));
        expect(pushPosts(), isEmpty);

        // The app registers the same token again (e.g. on launch).
        await support.registerPushToken('fcm-2', environment: 'production');
        await settle();
        expect(pushPosts(), isEmpty, reason: 'still on the old session');

        deleteStatus = 200;
        requests.clear();
        await support.registerPushToken('fcm-2', environment: 'production');
        await settle();
        final push = pushPosts().single;
        expect(deleteOf(old), lessThan(requests.indexOf(push)));
        expect(push.headers['X-AppRefer-Support-Session'], isNot(old));

        // Not pending any more: registered directly.
        requests.clear();
        await support.registerPushToken('fcm-2', environment: 'production');
        expect(pushPosts(), hasLength(1));
      }, () => MockClient(server));
    },
  );
}
