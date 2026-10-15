import 'dart:io';
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

  setUp(() {
    AppReferSupport.instance.title = 'Sparkly support';
    AppReferSupport.instance.accentColor = const Color(0xff7955ff);
  });
  testWidgets('home greeting, conversation and compose navigation', (
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
    expect(find.text('Your conversation'), findsOneWidget);
    await capture(tester, 'home');
    await tester.tap(find.text('Send us a message'));
    await tester.pumpAndSettle();
    expect(find.text('New message'), findsOneWidget);
    expect(find.text('Screenshot'), findsOneWidget);
    await capture(tester, 'compose');
    await tester.pumpWidget(const SizedBox());
  });
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
}
