import 'dart:convert';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// support.verifyIdentity (0.12.0): session-bound, single-use identity tokens.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> store;
  late List<http.Request> requests;
  late String userId;
  late bool cleared;
  const verified =
      '{"identity":{"verified":true,"appUserId":"user_42","verifiedAt":"2026-10-19T12:00:00.000Z"}}';
  SupportAPI make(Future<http.Response> Function(http.Request) handler) =>
      SupportAPI(
          client: MockClient((r) async {
            requests.add(r);
            return handler(r);
          }),
          apiKey: () => 'pk_live_key',
          read: (k) async => store[k],
          write: (k, v) async {
            if (v == null) {
              store.remove(k);
            } else {
              store[k] = v;
            }
          },
          keys: () async => store.keys.toList(),
          profile: () async => {'appUserId': userId},
          identityCleared: () async => cleared,
        )
        ..verifyRetryDelays = const [
          Duration(milliseconds: 1),
          Duration(milliseconds: 1),
        ];
  bool isVerify(http.Request r) => r.url.path == '/api/support/v1/session/identity';
  bool isSession(http.Request r) =>
      r.url.path == '/api/support/v1/session' && r.method == 'POST';
  http.Response json(String body, [int status = 200]) =>
      http.Response(body, status);

  setUp(() {
    store = {};
    requests = [];
    userId = 'user_42';
    cleared = false;
  });

  test('verifies the current session once; the token is never stored', () async {
    final api = make((r) async {
      if (isSession(r)) return json('{"session":"ars_one","created":true}', 201);
      if (r.url.path.endsWith('/conversations')) return json('{"conversations":[]}');
      return json(verified);
    });
    await api.conversations();
    final result = await api.verifyIdentity('sit1.payload.sig');
    expect(
      result,
      const AppReferSupportIdentityVerification(
        verified: true,
        appUserId: 'user_42',
      ),
    );
    final verify = requests.where(isVerify).single;
    expect(verify.method, 'POST');
    expect(verify.headers['X-AppRefer-Support-Session'], 'ars_one');
    expect(jsonDecode(verify.body), {'identityToken': 'sit1.payload.sig'});
    expect(requests.where(isSession).length, 1);
    expect(store.values.any((v) => v.contains('sit1')), isFalse);
  });

  test('a lost answer is retried with the same token on the same session', () async {
    var calls = 0;
    final api = make((r) async {
      if (isSession(r)) return json('{"session":"ars_one"}', 201);
      calls++;
      if (calls == 1) return json('{"error":"try again","reason":"unavailable"}', 503);
      if (calls == 2) throw http.ClientException('connection reset');
      return json(verified);
    });
    expect((await api.verifyIdentity('sit1.a.b')).verified, isTrue);
    final verifies = requests.where(isVerify).toList();
    expect(verifies.length, 3);
    expect(verifies.every((r) => r.body.contains('sit1.a.b')), isTrue);
    expect(
      verifies.map((r) => r.headers['X-AppRefer-Support-Session']).toSet(),
      {'ars_one'},
    );
  });

  test('throws after the retries; refusals come back without retrying', () async {
    var refuse = false;
    final api = make((r) async {
      if (isSession(r)) return json('{"session":"ars_one"}', 201);
      return refuse
          ? json('{"identity":{"verified":false,"reason":"already_used"}}')
          : json('{"error":"down"}', 503);
    });
    await expectLater(
      api.verifyIdentity('sit1.a.b'),
      throwsA(isA<SupportException>().having((e) => e.status, 'status', 503)),
    );
    expect(requests.where(isVerify).length, 3);
    requests.clear();
    refuse = true;
    expect(
      await api.verifyIdentity('sit1.a.b'),
      const AppReferSupportIdentityVerification.refused('already_used'),
    );
    expect(requests.where(isVerify).length, 1);
  });

  test('an unknown session is replaced, then verified', () async {
    var sessions = 0;
    var first = true;
    final api = make((r) async {
      if (isSession(r)) return json('{"session":"ars_${++sessions}"}', 201);
      if (first) {
        first = false;
        return json('{"error":"Unknown support session"}', 401);
      }
      return json(verified);
    });
    expect((await api.verifyIdentity('sit1.a.b')).verified, isTrue);
    expect(requests.where(isVerify).last.headers['X-AppRefer-Support-Session'], 'ars_2');
  });

  test('reset while verifying answers account_changed', () async {
    late SupportAPI api;
    api = make((r) async {
      if (isSession(r)) return json('{"session":"ars_one"}', 201);
      if (isVerify(r)) {
        await api.reset();
        return json(verified);
      }
      return json('{"ok":true}');
    });
    expect(
      await api.verifyIdentity('sit1.a.b'),
      const AppReferSupportIdentityVerification.refused('account_changed'),
    );
  });

  test('another user while verifying answers account_changed', () async {
    final api = make((r) async {
      if (isSession(r)) return json('{"session":"ars_one"}', 201);
      userId = 'user_77';
      return json(verified);
    });
    expect((await api.verifyIdentity('sit1.a.b')).reason, 'account_changed');
  });

  test('nothing is sent for a cleared identity or an empty token', () async {
    final api = make((r) async => json(verified));
    expect((await api.verifyIdentity('  ')).reason, 'malformed');
    cleared = true;
    expect((await api.verifyIdentity('sit1.a.b')).reason, 'identity_cleared');
    expect(requests, isEmpty);
  });
}
