import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:apprefer/src/support/support_strings.dart';
import 'package:apprefer/src/support/support_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Narrow screens (320 pt, an iPhone Duo cover): help-article summaries wrap
/// instead of stopping after a few words, and the floating composer never
/// covers the last quick-help tiles once the page is scrolled to its end.
// Test fonts draw every glyph a full em wide, so this already needs 3 lines here.
const summary = 'Every printed item is made for you.';
const listJSON =
    '''
{"articles":[
 {"slug":"orders","title":"Printing and orders","summary":"$summary","updatedAt":"2026-10-15T09:00:00Z","status":"published"},
 {"slug":"refunds","title":"Refunds","summary":"Bought through Apple or Google? Refunds go through the store you paid.","updatedAt":"2026-10-15T09:00:00Z","status":"published"},
 {"slug":"empty","title":"Subscriptions and restoring purchases","summary":"","updatedAt":"2026-10-15T09:00:00Z","status":"published"}]}
''';

http.Response json(String body) => http.Response.bytes(
  utf8.encode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

SupportAPI api() => SupportAPI(
  client: MockClient((r) async {
    final path = r.url.path;
    if (path.endsWith('/session')) return json('{"session":"s"}');
    if (path.endsWith('/status')) return json('{}');
    if (path == '/api/support/v1/articles') return json(listJSON);
    return json('{"conversations":[]}');
  }),
  apiKey: () => 'key',
  read: (_) async => null,
  write: (_, _) async {},
  profile: () async => {},
);

void main() {
  setUp(() {
    SupportStrings.overrides = {};
    SupportStrings.forcedLanguage = null;
    SupportStrings.appLocales = null;
    SupportStrings.deviceLocales = () => const [Locale('en', 'US')];
  });

  Future<void> pump(
    WidgetTester tester, {
    double width = 320,
    double height = 640,
    double textScale = 1,
    double keyboard = 0,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, height);
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 34);
    tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: MaterialApp(home: AppReferSupportView(api: api())),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Drags the home to its end.
  Future<void> scrollToEnd(WidgetTester tester) async {
    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 12; i++) {
      await tester.drag(scroll, const Offset(0, -400), warnIfMissed: false);
      await tester.pumpAndSettle();
    }
  }

  /// The composer's glass bar starts 7 pt above its field.
  double composerTop(WidgetTester tester) =>
      tester.getRect(find.byType(TextField).last).top - 7;

  void expectLastTileClear(WidgetTester tester) {
    final last = AppReferSupportTopic.defaults.last;
    // The tile's own 14 pt padding sits under its subtitle.
    final tileBottom = tester.getRect(find.text(last.subtitle)).bottom + 14;
    expect(
      tileBottom,
      lessThanOrEqualTo(composerTop(tester)),
      reason: 'the last quick-help tile must clear the composer',
    );
  }

  for (final dark in [false, true]) {
    testWidgets('320 pt: summaries wrap (${dark ? 'dark' : 'light'})', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = dark
          ? Brightness.dark
          : Brightness.light;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await pump(tester);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.text(summary),
      );
      expect(paragraph.didExceedMaxLines, isFalse, reason: 'not cut short');
      expect(
        paragraph.size.height,
        greaterThan(paragraph.text.style!.fontSize! * 1.5),
        reason: 'wraps onto more than one line',
      );
      // An empty summary adds no line at all.
      expect(
        find.text('Subscriptions and restoring purchases'),
        findsOneWidget,
      );
    });
  }

  testWidgets('320 pt: tile subtitles wrap and a row shares one height', (
    tester,
  ) async {
    final config = AppReferSupport.instance;
    final before = config.topics;
    addTearDown(() => config.topics = before);
    config.topics = const [
      AppReferSupportTopic(
        title: 'Orders',
        subtitle: 'Get help',
        icon: Icons.local_shipping_rounded,
        tint: Colors.blue,
        prompt: 'Which order?',
      ),
      AppReferSupportTopic(
        title: 'Restore',
        subtitle: 'Get your plan',
        icon: Icons.refresh_rounded,
        tint: Colors.green,
        prompt: 'What happened?',
      ),
    ];
    await pump(tester);
    final wrapped = tester.renderObject<RenderParagraph>(
      find.text('Get your plan'),
    );
    expect(wrapped.didExceedMaxLines, isFalse);
    expect(wrapped.size.height, greaterThan(12.5 * 1.5));
    Rect tile(String subtitle) => tester.getRect(
      find
          .ancestor(of: find.text(subtitle), matching: find.byType(Container))
          .first,
    );
    expect(tile('Get help').height, tile('Get your plan').height);
  });

  testWidgets('320 pt: the last tiles clear the composer', (tester) async {
    await pump(tester);
    await scrollToEnd(tester);
    expectLastTileClear(tester);
  });

  testWidgets('320 pt, large text: tiles clear the composer', (tester) async {
    await pump(tester, height: 700, textScale: 1.6);
    await scrollToEnd(tester);
    expectLastTileClear(tester);
  });

  testWidgets('a taller composer moves the end of the page with it', (
    tester,
  ) async {
    await pump(tester);
    await tester.enterText(
      find.byType(TextField).last,
      'line one\nline two\nline three\nline four\nline five',
    );
    await tester.pumpAndSettle();
    await scrollToEnd(tester);
    expectLastTileClear(tester);
  });

  testWidgets('keyboard open: the last tiles stay reachable', (tester) async {
    await pump(tester, keyboard: 300, height: 760);
    await scrollToEnd(tester);
    expectLastTileClear(tester);
  });

  // The customer is already at the end, then taps the composer: the keyboard
  // opens and they type five lines. The last tiles stay above the composer
  // without another scroll.
  testWidgets('at the end, the keyboard opening keeps the last tiles clear', (
    tester,
  ) async {
    await pump(tester, height: 760);
    await scrollToEnd(tester);
    expectLastTileClear(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    expectLastTileClear(tester);
    await tester.enterText(
      find.byType(TextField).last,
      'line one\nline two\nline three\nline four\nline five',
    );
    await tester.pumpAndSettle();
    expectLastTileClear(tester);
  });

  testWidgets('at the end, a taller composer keeps the last tiles clear', (
    tester,
  ) async {
    await pump(tester, textScale: 1.6, height: 700);
    await scrollToEnd(tester);
    await tester.enterText(
      find.byType(TextField).last,
      'line one\nline two\nline three\nline four\nline five',
    );
    await tester.pumpAndSettle();
    expectLastTileClear(tester);
  });

  // Reading higher up: neither the keyboard nor a taller composer moves the page.
  testWidgets('reading higher up, the page does not jump', (tester) async {
    await pump(tester, height: 760);
    await tester.drag(
      find.byType(Scrollable).first,
      const Offset(0, -60),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    expect(position.pixels, lessThan(position.maxScrollExtent - 100));
    final reading = tester.getRect(find.text('Refunds')).top;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).last,
      'line one\nline two\nline three\nline four\nline five',
    );
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('Refunds')).top, reading);
  });

  test('at-end rule', () {
    expect(supportHomeAtEnd(976, 1000), isTrue);
    expect(supportHomeAtEnd(975, 1000), isFalse);
    expect(supportHomeAtEnd(0, 0), isTrue);
  });

  testWidgets('ordinary phone and large window keep the same layout', (
    tester,
  ) async {
    for (final size in [const Size(393, 852), const Size(1024, 1366)]) {
      await pump(tester, width: size.width, height: size.height);
      await scrollToEnd(tester);
      expectLastTileClear(tester);
    }
  });
}
