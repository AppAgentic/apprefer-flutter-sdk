import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final shotKey = GlobalKey();
Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['APPREFER_SUPPORT_SCREENSHOTS'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        shotKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/flutter-$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Widget root(Widget child) => RepaintBoundary(key: shotKey, child: child);
void main() {
  final conversation = {
    'id': 'c',
    'subject': "My weekly quest isn't counting…",
    'status': 'open',
    'preview': 'That fixed it, thank you!',
    'lastMessageAt': '2026-10-15T12:35:00Z',
    'lastFrom': 'customer',
    'unread': 0,
  };
  final messages = [
    {
      'id': 'm1',
      'from': 'customer',
      'text': "My weekly quest isn't counting my workouts since yesterday",
      'createdAt': '2026-10-15T12:35:00Z',
      'attachments': [],
    },
    {
      'id': 'm2',
      'from': 'team',
      'authorName': 'Jay',
      'text':
          "Thanks María! That's fixed in 2.4.2. Update the app, then pull to refresh your quests and yesterday's workouts will count.",
      'createdAt': '2026-10-15T12:36:00Z',
      'attachments': [],
    },
  ];
  SupportAPI api() {
    final store = <String, String>{};
    return SupportAPI(
      client: MockClient(
        (r) async => http.Response(
          jsonEncode(
            r.url.path.endsWith('/session')
                ? {'session': 's'}
                : r.url.path.endsWith('/conversations')
                ? {
                    'conversations': [conversation],
                  }
                : {'conversation': conversation, 'messages': messages},
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      apiKey: () => 'key',
      read: (k) async => store[k],
      write: (k, v) async {
        if (v != null) store[k] = v;
      },
      profile: () async => {},
    )..name = 'María';
  }

  SupportAPI fake(Future<http.Response> Function(http.Request) handler) =>
      SupportAPI(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/session'))
            return http.Response('{"session":"s"}', 200);
          return handler(r);
        }),
        apiKey: () => 'key',
        read: (_) async => 's',
        write: (_, __) async {},
        profile: () async => {},
      );
  Map<String, dynamic> message(String id, String time, String text) => {
    'id': id,
    'createdAt': time,
    'text': text,
    'from': 'customer',
  };
  http.Response response(Object body) => http.Response.bytes(
    utf8.encode(jsonEncode(body)),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  testWidgets('poll cursor excludes send responses and merges duplicate ids', (
    tester,
  ) async {
    final cursors = <String?>[];
    final old = message('old', '2026-10-15T10:00:00Z', 'old');
    final own = message('own', '2026-10-15T10:02:00Z', 'own');
    final reply = message('reply', '2026-10-15T10:01:00Z', 'team reply');
    final client = fake((r) async {
      if (r.method == 'POST') return response({'message': own});
      cursors.add(r.url.queryParameters['after']);
      return response({
        'conversation': conversation,
        'messages': cursors.length == 1 ? [old] : [reply, own, own],
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AppReferSupportView(api: client, conversationId: 'c'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'own');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(cursors[1], old["createdAt"]);
    expect(find.text('team reply'), findsOneWidget);
    expect(find.text('own'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'a first send finishing after the customer moved on does not jump',
    (tester) async {
      final completion = Completer<http.Response>();
      final paths = <String>[];
      final other = {
        ...conversation,
        'id': 'other',
        'subject': 'Older question',
      };
      final client = fake((r) async {
        paths.add(r.url.path);
        if (r.method == 'POST') return completion.future;
        if (r.url.path.endsWith('/conversations')) {
          return response({
            'conversations': [other],
          });
        }
        return response({'conversation': other, 'messages': []});
      });
      await tester.pumpWidget(
        MaterialApp(
          home: AppReferSupportView(api: client, composing: 'first'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('first'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
      // Past the device-details wait, so the first send is really in flight.
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('Older question'));
      await tester.pumpAndSettle();
      completion.complete(
        response({
          'conversation': {...conversation, 'id': 'new'},
          'messages': [],
        }),
      );
      await tester.pumpAndSettle();
      expect(paths.where((p) => p.endsWith('/conversations/new')), isEmpty);
      expect(find.byTooltip('Back'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('first'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('text-only retry reuses id and next send gets a new id', (
    tester,
  ) async {
    final ids = <String>[];
    final client = fake((r) async {
      if (r.method == 'POST') {
        ids.add(jsonDecode(r.body)['clientMessageId'] as String);
        if (ids.length == 1) throw http.ClientException('lost response');
        return response({
          'message': message(
            'm${ids.length}',
            '2026-10-15T10:00:00Z',
            'delivered',
          ),
        });
      }
      return response({'conversation': conversation, 'messages': []});
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AppReferSupportView(api: client, conversationId: 'c'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not sent · Tap to retry'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'another');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pumpAndSettle();
    expect(ids[1], ids[0]);
    expect(ids[2], isNot(ids[0]));
    await tester.pumpWidget(const SizedBox());
  });
  for (final first in [false, true]) {
    testWidgets(
      'lost response retries with stable id and fresh images (first=$first)',
      (tester) async {
        var uploads = 0;
        final bodies = <Map<String, dynamic>>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              supportChannel,
              (call) async => call.method == 'pick'
                  ? [
                      Uint8List.fromList(
                        base64Decode(
                          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH1cAAAAASUVORK5CYII=',
                        ),
                      ),
                    ]
                  : null,
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(supportChannel, null),
        );
        final client = fake((r) async {
          if (r.url.path.endsWith('/attachments')) {
            uploads++;
            return response({
              'attachmentId': 'a$uploads',
              'uploadUrl': 'https://upload.example/$uploads',
              'headers': <String, String>{},
            });
          }
          if (r.method == 'PUT') return http.Response('', 200);
          if (r.method == 'POST') {
            bodies.add(Map<String, dynamic>.from(jsonDecode(r.body)));
            if (bodies.length == 1) throw http.ClientException('lost response');
            final m = message('stored', '2026-10-15T10:00:00Z', 'hello');
            return response(
              first
                  ? {
                      'conversation': conversation,
                      'messages': [m],
                      'duplicate': true,
                    }
                  : {'message': m, 'duplicate': true},
            );
          }
          return response({
            'conversation': conversation,
            'messages': [],
            'conversations': [],
          });
        });
        await tester.pumpWidget(
          MaterialApp(
            home: AppReferSupportView(
              api: client,
              conversationId: first ? null : 'c',
              composing: first ? 'hello' : null,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (!first) await tester.enterText(find.byType(TextField), 'hello');
        await tester.pump();
        await tester.tap(find.byTooltip('Add screenshot'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Send'));
        await tester.pumpAndSettle();
        await tester.tap(
          first ? find.byTooltip('Send') : find.text('Not sent · Tap to retry'),
        );
        await tester.pumpAndSettle();
        expect(uploads, 2);
        expect(
          bodies[0]['clientMessageId'],
          matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')),
        );
        expect(bodies[1]['clientMessageId'], bodies[0]['clientMessageId']);
        expect(bodies[0]['attachmentIds'], ['a1']);
        expect(bodies[1]['attachmentIds'], ['a2']);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  setUp(() {
    final support = AppReferSupport.instance;
    support.title = 'Sparkly support';
    support.accentColor = const Color(0xff7955ff);
    support.teamNames = const ['Jay', 'Ana'];
    support.replyTime = 'under an hour';
    support.topics = AppReferSupportTopic.defaults;
  });
  testWidgets('home: greeting, presence, continue card and topics', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      root(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: AppReferSupportView(api: api()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hi María 👋'), findsOneWidget);
    expect(find.text('Sparkly support'), findsOneWidget);
    expect(
      find.text('Jay and the team · usually under an hour'),
      findsOneWidget,
    );
    expect(find.text('CONTINUE'), findsOneWidget);
    expect(find.text('You: That fixed it, thank you!'), findsOneWidget);
    expect(find.text('QUICK HELP'), findsOneWidget);
    expect(find.text('YOUR CONVERSATIONS'), findsNothing);
    expect(find.text('Ask us anything…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'home');
    await tester.tap(find.text('Report a bug'));
    await tester.pumpAndSettle();
    expect(find.text('Report a bug'), findsNWidgets(2));
    expect(find.text('What went wrong? A screenshot helps.'), findsOneWidget);
    await capture(tester, 'home-topic');
    await tester.tap(find.byTooltip('Remove topic'));
    await tester.pumpAndSettle();
    expect(find.text('Ask us anything…'), findsOneWidget);
    await tester.tap(find.text("My weekly quest isn't counting…"));
    await tester.pumpAndSettle();
    expect(find.text('Jay'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('CONTINUE'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('presence line follows the team names', (tester) async {
    final support = AppReferSupport.instance;
    for (final (names, line) in [
      (<String>[], 'We usually reply in a few hours'),
      (['Jay'], 'Jay · usually replies in a few hours'),
    ]) {
      support.teamNames = names;
      support.replyTime = 'a few hours';
      await tester.pumpWidget(
        MaterialApp(home: AppReferSupportView(api: api())),
      );
      await tester.pumpAndSettle();
      expect(find.text(line), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
  });
  testWidgets('compose opens the home pre-filled and focused', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppReferSupportView(api: api(), composing: 'Refund please'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hi María 👋'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Refund please');
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'a topic sends its title as the subject; an action runs instead',
    (tester) async {
      final bodies = <Map<String, dynamic>>[];
      var restored = 0;
      AppReferSupport.instance.topics = [
        AppReferSupportTopic.bug,
        AppReferSupportTopic(
          title: 'Restore purchase',
          subtitle: 'Get your plan back',
          icon: Icons.refresh,
          tint: Colors.blue,
          prompt: '',
          action: () => restored++,
        ),
      ];
      final client = fake((r) async {
        if (r.method == 'POST') {
          bodies.add(Map<String, dynamic>.from(jsonDecode(r.body)));
          return response({
            'conversation': {...conversation, 'id': 'new'},
            'messages': [
              message('n1', '2026-10-15T10:00:00Z', 'The quest is stuck'),
            ],
          });
        }
        if (r.url.path.endsWith('/conversations')) {
          return response({'conversations': []});
        }
        return response({'conversation': conversation, 'messages': []});
      });
      await tester.pumpWidget(
        MaterialApp(home: AppReferSupportView(api: client)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore purchase'));
      await tester.pumpAndSettle();
      expect(restored, 1);
      expect(find.byTooltip('Remove topic'), findsNothing);
      await tester.tap(find.text('Report a bug'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'The quest is stuck');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(bodies.single['subject'], 'Report a bug');
      expect(bodies.single['text'], 'The quest is stuck');
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.text('The quest is stuck'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('thread reply layout', (tester) async {
    tester.view.physicalSize = const Size(400, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      root(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: AppReferSupportView(api: api(), conversationId: 'c'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Jay'), findsOneWidget);
    await capture(tester, 'thread-reply');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('thread authors, reply and large text in dark mode', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 840);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      root(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: AppReferSupportView(api: api(), conversationId: 'c'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Jay'), findsOneWidget);
    expect(find.textContaining('Thanks María!'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await capture(tester, 'thread-dark-large');
    await tester.pumpWidget(const SizedBox());
  });

  group('AI persona', () {
    const persona = {'name': 'Sam', 'avatarUrl': null, 'handoffTo': 'Jay'};
    final botConversation = {
      ...conversation,
      'lastFrom': 'bot',
      'preview': 'Open Settings → Restore purchases',
    };
    final botMessages = [
      messages.first,
      {
        'id': 'b1',
        'from': 'bot',
        'authorName': 'Sam',
        'text': 'Open Settings → Restore purchases and it should unlock.',
        'createdAt': '2026-10-15T12:35:30Z',
        'attachments': [],
      },
      message('c2', '2026-10-15T12:36:00Z', 'Can I get a refund?'),
      {
        'id': 'b2',
        'from': 'bot',
        'authorName': 'Sam',
        'text': "I'll get Jay to look at the refund for you.",
        'createdAt': '2026-10-15T12:36:10Z',
        'attachments': [],
        'handoff': true,
      },
    ];
    SupportAPI personaApi(List<Map<String, dynamic>> thread) => fake(
      (r) async => response(
        r.url.path.endsWith('/conversations')
            ? {
                'conversations': [botConversation],
                'persona': persona,
              }
            : {
                'conversation': botConversation,
                'messages': thread,
                'persona': persona,
              },
      ),
    )..name = 'María';

    testWidgets('home names the assistant', (tester) async {
      tester.view.physicalSize = const Size(400, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        root(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: AppReferSupportView(api: personaApi(botMessages)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Sam replies instantly · Jay and the team in under an hour'),
        findsOneWidget,
      );
      expect(find.text('Message Sam…'), findsOneWidget);
      // Continue card shows Sam's avatar (initial S) for a bot last message.
      expect(find.text('S'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await capture(tester, 'home-persona');
      await tester.tap(find.text('Report a bug'));
      await tester.pumpAndSettle();
      expect(find.text('What went wrong? A screenshot helps.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('thread: header, AI tags, hand-over pill, no quick replies', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        root(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: AppReferSupportView(
              api: personaApi(botMessages),
              conversationId: 'c',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sam'), findsNWidgets(3)); // header + two bubbles
      expect(find.text('AI'), findsNWidgets(3));
      expect(find.bySemanticsLabel('AI assistant'), findsWidgets);
      expect(find.textContaining('team · replies instantly'), findsOneWidget);
      expect(
        find.text('Passed to Jay · usually replies in under an hour'),
        findsOneWidget,
      );
      expect(find.text("👍 Thanks, that's sorted"), findsNothing);
      expect(find.text('✦ INSTANT ANSWER'), findsNothing);
      expect(tester.takeException(), isNull);
      await capture(tester, 'thread-persona');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a teammate in the thread takes the header; chips return', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppReferSupportView(
            api: personaApi([...botMessages.take(2), messages.last]),
            conversationId: 'c',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Jay'), findsOneWidget);
      expect(find.text('Usually replies in under an hour'), findsOneWidget);
      expect(find.text('AI'), findsOneWidget); // only Sam's bubble
      expect(find.text("👍 Thanks, that's sorted"), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an unnamed bot message keeps the instant-answer card', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppReferSupportView(
            api: personaApi([
              {
                'id': 'b',
                'from': 'bot',
                'text': 'Try restoring purchases.',
                'createdAt': '2026-10-15T12:35:30Z',
              },
            ]),
            conversationId: 'c',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('✦ INSTANT ANSWER'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
