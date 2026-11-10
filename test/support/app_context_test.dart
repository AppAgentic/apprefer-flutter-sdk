import 'dart:async';
import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 0.14.0: the app's hidden conversation data (`context.app`), `send()` and
/// `compose(appContext:)`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('supportCleanAppContext', () {
    test('keeps valid keys sorted, cleans and cuts values', () {
      final cleaned = supportCleanAppContext({
        'source': '  map sheet ',
        'course_id': '8812',
        'Club': 'upper case key',
        'bad-key': 'dash',
        'has space': 'x',
        '': 'empty key',
        'k' * 41: 'too long key',
        'k' * 40: 'longest key',
        'note': 'line one\nline\ttwo\u0000end',
        'long': '${'a' * 499}  bcd',
        'empty': '   ',
        'controls': '\n\t',
      });
      expect(cleaned.keys.toList(), [
        'course_id',
        'k' * 40,
        'long',
        'note',
        'source',
      ]);
      expect(cleaned['source'], 'map sheet');
      expect(cleaned['note'], 'line one line two end');
      // Cut to 500, then trimmed again (the server does the same).
      expect(cleaned['long'], 'a' * 499);
    });

    test('keeps the first 20 valid keys in sorted order', () {
      final raw = {
        for (var i = 0; i < 30; i++)
          'key_${i.toString().padLeft(2, '0')}': 'v$i',
        'aaa_empty': ' ',
      };
      final cleaned = supportCleanAppContext(raw);
      expect(cleaned.length, 20);
      expect(cleaned.keys.first, 'key_00');
      expect(cleaned.keys.last, 'key_19');
    });

    test('nothing valid leaves an empty map', () {
      expect(supportCleanAppContext({'Bad': 'x', 'ok': ''}), isEmpty);
      expect(supportCleanAppContext(const {}), isEmpty);
    });
  });

  group('startConversation (support.send)', () {
    late List<http.Request> posts;
    SupportAPI make(
      Future<http.Response> Function(http.Request) handler, {
      Future<bool> Function()? identityCleared,
    }) =>
        SupportAPI(
            client: MockClient((r) async {
              if (r.url.path == '/api/support/v1/session') {
                return http.Response('{"session":"ars_one"}', 201);
              }
              posts.add(r);
              return handler(r);
            }),
            apiKey: () => 'pk_live_key',
            read: (_) async => null,
            write: (_, __) async {},
            keys: () async => [],
            profile: () async => {},
            identityCleared: identityCleared ?? () async => false,
          )
          ..sendRetryDelays = const [
            Duration(milliseconds: 1),
            Duration(milliseconds: 1),
          ];
    http.Response created([String id = 'cv_1']) => http.Response(
      jsonEncode({
        'conversation': {'id': id},
        'messages': [],
      }),
      201,
    );

    setUp(() => posts = []);

    test('posts the text, subject and cleaned context.app', () async {
      final api = make((_) async => created());
      final id = await api.startConversation(
        '  The green is in the wrong place  ',
        subject: 'Map issue',
        appContext: {'course_id': '8812', 'club': '7i', 'Bad': 'dropped'},
        metadata: () async => {'platform': 'ios', 'appVersion': '3.0'},
      );
      expect(id, 'cv_1');
      final post = posts.single;
      expect(post.url.path, '/api/support/v1/conversations');
      expect(post.method, 'POST');
      final body = jsonDecode(post.body) as Map<String, dynamic>;
      expect(body['text'], 'The green is in the wrong place');
      expect(body['subject'], 'Map issue');
      expect(body['context'], {
        'platform': 'ios',
        'appVersion': '3.0',
        'app': {'club': '7i', 'course_id': '8812'},
      });
      expect(
        body['clientMessageId'],
        matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')),
      );
      expect(body.containsKey('attachmentIds'), isFalse);
    });

    test('no app data: context has no app key', () async {
      final api = make((_) async => created());
      await api.startConversation('hello', appContext: {'Bad': 'x'});
      final body = jsonDecode(posts.single.body) as Map<String, dynamic>;
      expect((body['context'] as Map).containsKey('app'), isFalse);
      expect(body.containsKey('subject'), isFalse);
    });

    test('retries transient failures with the same clientMessageId', () async {
      var calls = 0;
      final api = make((_) async {
        calls++;
        if (calls == 1) return http.Response('{"error":"down"}', 503);
        if (calls == 2) throw http.ClientException('lost response');
        return created('cv_stored');
      });
      expect(
        await api.startConversation('hi', appContext: {'course_id': '1'}),
        'cv_stored',
      );
      expect(posts.length, 3);
      final bodies = posts.map((r) => jsonDecode(r.body) as Map).toList();
      expect(bodies.map((b) => b['clientMessageId']).toSet().length, 1);
      expect(bodies.every((b) => (b['context'] as Map)['app'] != null), isTrue);
    });

    test('each call gets its own clientMessageId', () async {
      final api = make((_) async => created());
      await api.startConversation('one');
      await api.startConversation('two');
      final ids = posts.map((r) => jsonDecode(r.body)['clientMessageId']);
      expect(ids.toSet().length, 2);
    });

    test('throws after two retries; refusals are not retried', () async {
      var status = 503;
      final api = make((_) async => http.Response('{"error":"nope"}', status));
      await expectLater(
        api.startConversation('hi'),
        throwsA(isA<SupportException>().having((e) => e.status, 'status', 503)),
      );
      expect(posts.length, 3);
      posts.clear();
      status = 400;
      await expectLater(
        api.startConversation('hi'),
        throwsA(isA<SupportException>().having((e) => e.status, 'status', 400)),
      );
      expect(posts.length, 1);
    });

    test('network failures end in an unavailable error', () async {
      final api = make((_) async => throw http.ClientException('offline'));
      await expectLater(
        api.startConversation('hi'),
        throwsA(
          isA<SupportException>().having(
            (e) => e.reason,
            'reason',
            SupportErrorReason.unavailable,
          ),
        ),
      );
      expect(posts.length, 3);
    });

    test('empty text throws without a request', () async {
      final api = make((_) async => created());
      await expectLater(
        api.startConversation('   \n'),
        throwsA(isA<SupportException>()),
      );
      await expectLater(
        AppReferSupport.instance.send(' '),
        throwsA(isA<SupportException>()),
      );
      expect(posts, isEmpty);
    });

    test('a reset while device details load: nothing is posted', () async {
      final details = Completer<Map<String, dynamic>>();
      final api = make((_) async => created());
      final future = api.startConversation(
        'account A only',
        appContext: {'course_id': 'a'},
        metadata: () => details.future,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await api.reset();
      details.complete({'platform': 'ios'});
      await expectLater(
        future,
        throwsA(
          isA<SupportException>().having(
            (e) => e.reason,
            'reason',
            SupportErrorReason.reset,
          ),
        ),
      );
      expect(posts, isEmpty);
    });

    test('slow device details never hold the message back', () async {
      final api = make((_) async => created());
      final id = await api.startConversation(
        'hi',
        metadata: () => Completer<Map<String, dynamic>>().future,
        metadataTimeout: const Duration(milliseconds: 10),
      );
      expect(id, 'cv_1');
      expect(jsonDecode(posts.single.body)['context'], isEmpty);
    });

    test('a locked store is not retried', () async {
      var checks = 0;
      final api = make(
        (_) async => created(),
        identityCleared: () async {
          checks++;
          throw SupportException(
            0,
            'Support storage is unavailable; try again.',
            reason: SupportErrorReason.locked,
          );
        },
      );
      await expectLater(
        api.startConversation('hi'),
        throwsA(
          isA<SupportException>().having(
            (e) => e.reason,
            'reason',
            SupportErrorReason.locked,
          ),
        ),
      );
      expect(checks, 1);
      expect(posts, isEmpty);
    });

    test('a malformed 2xx answer is not retried', () async {
      final api = make((_) async => http.Response('{"oops":true}', 201));
      await expectLater(
        api.startConversation('hi'),
        throwsA(isA<SupportException>().having((e) => e.status, 'status', 0)),
      );
      expect(posts.length, 1);
      posts.clear();
      final garbled = make((_) async => http.Response('not json', 200));
      await expectLater(
        garbled.startConversation('hi'),
        throwsA(isA<SupportException>()),
      );
      expect(posts.length, 1);
    });

    test('a 408 and a 429 are retried', () async {
      var calls = 0;
      final api = make((_) async {
        calls++;
        if (calls == 1) return http.Response('{"error":"slow"}', 408);
        if (calls == 2) return http.Response('{"error":"busy"}', 429);
        return created();
      });
      expect(await api.startConversation('hi'), 'cv_1');
      expect(posts.length, 3);
    });

    test('a reset during the retry wait stops it', () async {
      var calls = 0;
      late SupportAPI api;
      api = make((_) async {
        calls++;
        return http.Response('{"error":"down"}', 503);
      });
      api.sendRetryDelays = const [
        Duration(milliseconds: 50),
        Duration(milliseconds: 50),
      ];
      final future = api.startConversation('hi');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await api.reset();
      await expectLater(
        future,
        throwsA(
          isA<SupportException>().having(
            (e) => e.reason,
            'reason',
            SupportErrorReason.reset,
          ),
        ),
      );
      expect(calls, 1);
    });
  });

  group('compose(appContext:)', () {
    testWidgets(
      'only the first new conversation carries context.app, never shown',
      (tester) async {
        final bodies = <Map<String, dynamic>>[];
        var n = 0;
        final api = SupportAPI(
          client: MockClient((r) async {
            if (r.url.path.endsWith('/session')) {
              return http.Response('{"session":"s"}', 200);
            }
            if (r.url.path.endsWith('/status') ||
                r.url.path.startsWith('/api/support/v1/articles')) {
              return http.Response('{"error":"not here"}', 404);
            }
            if (r.method == 'POST' && r.url.path.endsWith('/conversations')) {
              bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
              n++;
              return http.Response(
                jsonEncode({
                  'conversation': {'id': 'new$n', 'status': 'open'},
                  'messages': [],
                }),
                201,
              );
            }
            if (r.url.path.endsWith('/conversations')) {
              return http.Response('{"conversations":[]}', 200);
            }
            return http.Response(
              jsonEncode({
                'conversation': {'id': 'new$n', 'status': 'open'},
                'messages': [],
              }),
              200,
            );
          }),
          apiKey: () => 'key',
          read: (_) async => 's',
          write: (_, __) async {},
          profile: () async => {},
        );
        await tester.pumpWidget(
          MaterialApp(
            home: AppReferSupportView(
              api: api,
              composing: 'Wrong green',
              composingContext: const {'course_id': 'secret_8812'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('secret_8812'), findsNothing);
        await tester.tap(find.byTooltip('Send'));
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(bodies.length, 1);
        expect(bodies.single['context']['app'], {'course_id': 'secret_8812'});
        expect(find.textContaining('secret_8812'), findsNothing);

        // Back to the home and a second conversation: no app data.
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'Another thing');
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(bodies.length, 2);
        expect((bodies[1]['context'] as Map).containsKey('app'), isFalse);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('compose without app data sends no app key', (tester) async {
      final bodies = <Map<String, dynamic>>[];
      final api = SupportAPI(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/session')) {
            return http.Response('{"session":"s"}', 200);
          }
          if (r.method == 'POST' && r.url.path.endsWith('/conversations')) {
            bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
            return http.Response(
              '{"conversation":{"id":"c1","status":"open"},"messages":[]}',
              201,
            );
          }
          if (r.url.path.endsWith('/conversations')) {
            return http.Response('{"conversations":[]}', 200);
          }
          if (r.url.path.endsWith('/conversations/c1')) {
            return http.Response(
              '{"conversation":{"id":"c1","status":"open"},"messages":[]}',
              200,
            );
          }
          return http.Response('{"error":"not here"}', 404);
        }),
        apiKey: () => 'key',
        read: (_) async => 's',
        write: (_, __) async {},
        profile: () async => {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AppReferSupportView(api: api, composing: 'Hi'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Send'));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(bodies.length, 1);
      expect((bodies.single['context'] as Map).containsKey('app'), isFalse);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
