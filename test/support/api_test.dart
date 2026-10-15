import 'dart:convert';
import 'dart:typed_data';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> store;
  late List<http.Request> requests;
  late int minted;
  SupportAPI make(Future<http.Response> Function(http.Request) handler) =>
      SupportAPI(
        client: MockClient((r) async {
          requests.add(r);
          return handler(r);
        }),
        apiKey: () => 'sdk-key',
        read: (k) async => store[k],
        write: (k, v) async {
          if (v == null) {
            store.remove(k);
          } else {
            store[k] = v;
          }
        },
        profile: () async => {'appUserId': 'user', 'deviceId': 'device'},
      );
  http.Response session(http.Request r) {
    minted++;
    return http.Response(jsonEncode({'session': 'token$minted'}), 200);
  }

  setUp(() {
    store = {};
    requests = [];
    minted = 0;
  });
  test(
    'session headers, profile and mint once; changed identity resends only once',
    () async {
      final api = make(
        (r) async => r.url.path.endsWith('/session')
            ? session(r)
            : http.Response('{"conversations":[]}', 200),
      );
      await api.conversations();
      await api.conversations();
      expect(minted, 1);
      expect(requests.first.headers['X-AppRefer-Key'], 'sdk-key');
      expect(
        requests.first.headers.containsKey('X-AppRefer-Support-Session'),
        false,
      );
      expect(jsonDecode(requests.first.body), {
        'appUserId': 'user',
        'deviceId': 'device',
      });
      expect(requests.last.headers['X-AppRefer-Support-Session'], 'token1');
      api.name = 'Maria';
      await api.conversations();
      await api.conversations();
      expect(minted, 2);
      final update = requests
          .where((r) => r.url.path.endsWith('/session'))
          .last;
      expect(update.headers['X-AppRefer-Support-Session'], 'token1');
      expect(jsonDecode(update.body)['name'], 'Maria');
    },
  );
  test('401 support session drops token and retries exactly once', () async {
    var calls = 0;
    final api = make((r) async {
      if (r.url.path.endsWith('/session')) return session(r);
      calls++;
      return http.Response('{"error":"Invalid support session"}', 401);
    });
    await expectLater(api.conversations(), throwsA(isA<SupportException>()));
    expect(calls, 2);
    expect(minted, 2);
  });
  test(
    '401 from profile update is recovered; other 401 does not remint',
    () async {
      var reject = false;
      final api = make((r) async {
        if (r.url.path.endsWith('/session')) {
          if (reject && r.headers.containsKey('X-AppRefer-Support-Session'))
            return http.Response('{"error":"support session expired"}', 401);
          return session(r);
        }
        return http.Response('{"conversations":[]}', 200);
      });
      await api.conversations();
      reject = true;
      api.email = 'a@b.com';
      await api.conversations();
      expect(minted, 2);
      store.clear();
      final other = make(
        (r) async => r.url.path.endsWith('/session')
            ? session(r)
            : http.Response('{"error":"Invalid SDK key"}', 401),
      );
      await expectLater(
        other.conversations(),
        throwsA(isA<SupportException>()),
      );
      expect(minted, 3);
    },
  );
  test('concurrent requests share session creation', () async {
    final api = make(
      (r) async => r.url.path.endsWith('/session')
          ? session(r)
          : http.Response('{"conversations":[]}', 200),
    );
    await Future.wait([api.conversations(), api.conversations()]);
    expect(minted, 1);
  });
  test(
    'conversation, attachment-only message, encoded cursor and push shapes',
    () async {
      final api = make(
        (r) async => r.url.path.endsWith('/session')
            ? session(r)
            : http.Response(
                '{"conversation":{"id":"c"},"messages":[],"message":{"id":"m"}}',
                200,
              ),
      );
      await api.start('hello', ['a'], {'platform': 'android'});
      expect(jsonDecode(requests.last.body), {
        'text': 'hello',
        'attachmentIds': ['a'],
        'context': {'platform': 'android'},
      });
      await api.send('a/b', '', ['a']);
      expect(
        requests.last.url.toString(),
        contains('/api/support/v1/conversations/a%2Fb/messages'),
      );
      expect(jsonDecode(requests.last.body), {
        'text': '',
        'attachmentIds': ['a'],
      });
      await api.thread('c', after: '2026-10-15T10:00:00+01:00');
      expect(
        requests.last.url.queryParameters['after'],
        '2026-10-15T10:00:00+01:00',
      );
      await api.call('POST', '/push-token', {
        'platform': 'android',
        'token': 'push',
        'environment': 'production',
      });
      expect(jsonDecode(requests.last.body)['token'], 'push');
      await api.call('DELETE', '/push-token', {'token': 'push'});
      expect(requests.last.method, 'DELETE');
    },
  );
  test(
    'upload uses exact bytes and slot headers without SDK credentials',
    () async {
      final api = make((r) async {
        if (r.url.path.endsWith('/session')) return session(r);
        if (r.url.path.endsWith('/attachments'))
          return http.Response(
            '{"attachmentId":"a","uploadUrl":"https://storage.example/upload","headers":{"Content-Type":"image/jpeg"}}',
            200,
          );
        return http.Response('', 200);
      });
      final bytes = Uint8List.fromList([255, 216, 1, 2, 255, 217]);
      expect(await api.upload(bytes), 'a');
      final slot = requests[1];
      expect(jsonDecode(slot.body)['size'], bytes.length);
      final put = requests.last;
      expect(put.method, 'PUT');
      expect(put.bodyBytes, bytes);
      expect(put.contentLength, bytes.length);
      expect(put.headers.containsKey('X-AppRefer-Key'), false);
    },
  );
}
