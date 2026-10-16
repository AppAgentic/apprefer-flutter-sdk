import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/services/storage.dart';
import 'package:apprefer/src/support/support_api.dart';
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

  group('Round 2 D. the clearIdentity flag lives in the secure store', () {
    const flag = 'apprefer_support_identity_cleared';

    test('clearIdentity saves it next to the session token, not in '
        'preferences', () async {
      await http.runWithClient(() async {
        final support = AppReferSDK.support;
        support.configure(apiKey: 'pk_support');
        await support.clearIdentity();
        expect(secure[flag], '1');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.containsKey(flag), isFalse);
        // A different account ends it in the secure store too.
        await AppReferSDK.setUserId('acct_B');
        expect(secure.containsKey(flag), isFalse);
      }, () => MockClient(server));
    });

    test(
      'a 0.9.2 preferences copy moves to the secure store on first read',
      () async {
        SharedPreferences.setMockInitialValues({flag: true});
        final storage = AppReferStorage();
        await storage.init();
        expect(await storage.isSupportIdentityCleared(), isTrue);
        expect(secure[flag], '1');
        expect(
          (await SharedPreferences.getInstance()).containsKey(flag),
          isFalse,
        );
        expect(await storage.isSupportIdentityCleared(), isTrue);
      },
    );

    test(
      'reinstall: preferences are gone but the Keychain session and flag '
      'survive, so the cleared session stays anonymous and is kept',
      () async {
        SharedPreferences.setMockInitialValues({});
        secure
          ..[flag] = '1'
          ..['support_pk_support.token'] = 'ars_kept'
          ..['support_pk_support.cleared'] = '1'
          ..['support_pk_support.profile'] = '{}';
        await http.runWithClient(() async {
          final support = AppReferSDK.support;
          support.configure(apiKey: 'pk_support');
          support.api.name = null;
          support.api.email = null;
          await support.api.conversations();
          await settle();
          expect(deleteOf('ars_kept'), -1, reason: 'not retired');
          final get = requests.lastWhere((r) => r.method == 'GET');
          expect(get.headers['X-AppRefer-Support-Session'], 'ars_kept');
        }, () => MockClient(server));
      },
    );

    test('an unreadable secure store reads as cleared', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'secure_storage');
          });
      final storage = AppReferStorage();
      await storage.init();
      expect(await storage.isSupportIdentityCleared(), isTrue);
    });
  });

  group('Round 3 E5/E6', () {
    const flag = 'apprefer_support_identity_cleared';
    var flagReadFails = false;
    var flagClearFails = false;
    setUp(() {
      flagReadFails = false;
      flagClearFails = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'read':
                if (call.arguments == flag && flagReadFails) {
                  throw PlatformException(code: 'secure_storage');
                }
                return secure[call.arguments as String];
              case 'write':
                final args = Map<String, dynamic>.from(call.arguments as Map);
                final value = args['value'] as String?;
                if (args['key'] == flag && value == null && flagClearFails) {
                  throw PlatformException(code: 'secure_storage');
                }
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

    test('E5: an unreadable cleared flag mints or adopts no session, so the '
        'real session is never marked cleared or retired', () async {
      await http.runWithClient(() async {
        final support = AppReferSDK.support;
        support.configure(apiKey: 'pk_support');
        support.api.name = null;
        support.api.email = null;
        secure['support_pk_support.token'] = 'ars_real';
        secure['support_pk_support.profile'] = '{"appUserId":"acct_A"}';
        flagReadFails = true;
        await expectLater(
          support.api.conversations(),
          throwsA(isA<SupportException>()),
        );
        expect(requests.where((r) => r.url.path.endsWith('/session')), isEmpty);
        expect(secure.containsKey('support_pk_support.cleared'), isFalse);
        expect(secure['support_pk_support.token'], 'ars_real');

        flagReadFails = false; // unlocked
        await support.api.conversations();
        await settle();
        expect(deleteOf('ars_real'), -1);
        expect(
          requests
              .lastWhere((r) => r.method == 'GET')
              .headers['X-AppRefer-Support-Session'],
          'ars_real',
        );
      }, () => MockClient(server));
    });

    test('E6: setUserId and configure(userId:) never throw when the flag '
        'cannot be removed; Support stays anonymous', () async {
      secure[flag] = '1';
      flagClearFails = true;
      await AppReferSDK.setUserId('acct_B');
      final storage = AppReferStorage();
      await storage.init();
      expect(storage.getUserId(), isNull, reason: 'not stored for Support');
      expect(secure[flag], '1', reason: 'still cleared');
      expect(
        (await SupportAPI.defaultProfile()).containsKey('appUserId'),
        isFalse,
      );
      final attribution = http.runWithClient(
        () => AppReferSDK.configure(
          const AppReferConfig(apiKey: 'pk_test', userId: 'acct_C'),
        ),
        () =>
            MockClient((r) async => http.Response('{"attribution":null}', 200)),
      );
      await expectLater(attribution, completes);
      expect(storage.getUserId(), isNull);
      await AppReferSDK.disposeForTesting();
    });
  });
}
