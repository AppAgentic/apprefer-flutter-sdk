import 'dart:convert';

import 'package:apprefer/apprefer.dart';
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

  test(
    'registerPushToken: a token saved by 0.9.1 (no environment) that the '
    'old session still holds is not posted until its revocation succeeds',
    () async {
      await http.runWithClient(() async {
        final support = AppReferSDK.support;
        support.configure(apiKey: 'pk_support');
        // What 0.9.1 left behind: the old session's revocation holds the
        // token, with no environment and no move flag.
        secure['apprefer_revocations'] = jsonEncode([
          {
            'token': 'ars_091',
            'key': 'pk_support',
            'push': 'apns-091',
            'createdAt': DateTime.now().millisecondsSinceEpoch,
            'attempts': 0,
          },
        ]);
        secure['support_pk_support.push'] = 'apns-091';
        deleteStatus = 503;
        await support.registerPushToken('apns-091', environment: 'sandbox');
        await settle();
        expect(deleteOf('ars_091'), isNot(-1));
        expect(pushPosts(), isEmpty, reason: 'old session still holds it');

        deleteStatus = 200;
        requests.clear();
        await support.registerPushToken('apns-091', environment: 'sandbox');
        await settle();
        final push = pushPosts().single;
        expect(deleteOf('ars_091'), lessThan(requests.indexOf(push)));
        expect(jsonDecode(push.body)['environment'], 'sandbox');
        expect(push.headers['X-AppRefer-Support-Session'], isNot('ars_091'));
      }, () => MockClient(server));
    },
  );
}
