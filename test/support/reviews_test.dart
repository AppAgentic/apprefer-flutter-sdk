import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:apprefer/src/support/support_offers.dart';
import 'package:apprefer/src/support/support_reviews.dart';
import 'package:apprefer/src/support/support_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Review cards (0.12.0): model, link check, copy, receipts, API and the card
/// in the chat (opens the store page through the existing openUrl channel).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const ios = {
    'cardId': 'rvc_0123456789abcdef01234567',
    'status': 'available',
    'reason': null,
    'store': 'app_store',
    'url': 'https://apps.apple.com/app/id1234567890?action=write-review',
  };
  const play = {
    'cardId': 'rvc_0123456789abcdef01234567',
    'status': 'available',
    'reason': null,
    'store': 'play_store',
    'url': 'https://play.google.com/store/apps/details?id=com.sparkly.app',
  };
  AppReferSupportReviewCard card([Map<String, Object?> json = ios]) =>
      AppReferSupportReviewCard.fromJson(json)!;

  setUp(() => SupportStrings.forcedLanguage = 'en');
  tearDown(() => SupportStrings.forcedLanguage = null);

  test('decodes review cards and never draws something that is not one', () {
    expect(card().cardId, 'rvc_0123456789abcdef01234567');
    expect(AppReferSupportReviewCard.fromJson({'cardId': 'rvc_x'}), isNull);
    expect(AppReferSupportReviewCard.fromJson('review'), isNull);
  });

  test('only this platform\'s own store page is ever opened', () {
    expect(
      SupportReviewLink.validated(ios['url'] as String, ios: true),
      'https://apps.apple.com/app/id1234567890?action=write-review',
    );
    expect(
      SupportReviewLink.validated(play['url'] as String, ios: false),
      'https://play.google.com/store/apps/details?id=com.sparkly.app',
    );
    for (final bad in [
      'http://apps.apple.com/app/id1234567890?action=write-review',
      'https://apps.apple.com.evil.example/app/id1234567890?action=write-review',
      'https://apps.apple.com/app/id1234567890?action=write-review&next=https://evil.example',
      'https://user@apps.apple.com/app/id1234567890?action=write-review',
      'https://apps.apple.com/app/id1234567890',
      'itms-apps://apps.apple.com/app/id1234567890?action=write-review',
      play['url'] as String,
      '',
    ]) {
      expect(SupportReviewLink.validated(bad, ios: true), isNull, reason: bad);
    }
    for (final bad in [
      'https://play.google.com/store/apps/details?id=com.a.b&url=https://evil.example',
      'https://play.google.com/store/apps/details?id=javascript:alert(1)',
      'https://play.google.com:444/store/apps/details?id=com.a.b',
      'market://details?id=com.a.b',
      ios['url'] as String,
    ]) {
      expect(SupportReviewLink.validated(bad, ios: false), isNull, reason: bad);
    }
    expect(
      SupportReviewLook.of(card(), ios: false),
      isA<SupportReviewUnsupported>(),
    );
    expect(
      SupportReviewLook.of(
        card({
          ...ios,
          'status': 'unavailable',
          'reason': 'revoked',
          'url': null,
        }),
        ios: true,
      ),
      isA<SupportReviewUnavailable>(),
    );
    expect(
      SupportReviewLook.of(
        card({
          ...ios,
          'status': 'unavailable',
          'reason': 'not_on_platform',
          'url': null,
        }),
        ios: true,
      ),
      isA<SupportReviewUnsupported>(),
    );
  });

  test('neutral copy names the store in every language', () {
    expect(
      SupportStrings.text('support.review.title'),
      'Share your experience',
    );
    expect(
      SupportStrings.text('support.review.body.appStore'),
      "If you'd like, you can write a review on the App Store.",
    );
    expect(SupportStrings.text('support.review.open'), 'Write a review');
    for (final lang in ['ar', 'de', 'ja', 'pt-BR', 'zh-Hant']) {
      SupportStrings.forcedLanguage = lang;
      expect(
        SupportStrings.text('support.review.body.googlePlay'),
        contains('Google Play'),
      );
      expect(
        SupportStrings.text('support.review.open'),
        isNot('Write a review'),
      );
    }
    expect(
      SupportReviewLink.shownId('rvc_0123456789abcdef01234567'),
      matches(RegExp(r'^[A-Za-z0-9_-]{8,64}$')),
    );
  });

  group('in the chat', () {
    final shotKey = GlobalKey();
    late List<http.Request> requests;
    late List<String> opened;
    late Map<String, Object?> current;
    late int eventStatus;

    SupportAPI chat({required bool onIOS}) {
      final store = <String, String>{};
      return SupportAPI(
        client: MockClient((r) async {
          requests.add(r);
          if (r.url.path.endsWith('/session'))
            return http.Response('{"session":"s"}', 200);
          if (r.url.path.endsWith('/status') ||
              r.url.path.startsWith('/api/support/v1/articles')) {
            return http.Response('{"error":"not here"}', 404);
          }
          if (r.url.path.endsWith('/events')) {
            return http.Response(
              jsonEncode(
                eventStatus == 409
                    ? {
                        'error': 'gone',
                        'code': 'REVIEW_UNAVAILABLE',
                        'review': {
                          ...current,
                          'status': 'unavailable',
                          'reason': 'revoked',
                          'url': null,
                        },
                      }
                    : {
                        'eventId': 'rve_x',
                        'duplicate': false,
                        'review': current,
                      },
              ),
              eventStatus,
            );
          }
          if (r.url.path.endsWith('/reviews'))
            return http.Response(
              jsonEncode({
                'reviews': [current],
              }),
              200,
            );
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'conversation': {
                  'id': 'c',
                  'subject': 'Sync',
                  'status': 'open',
                  'preview': 'p',
                  'lastMessageAt': '2026-10-19T12:00:00Z',
                  'lastFrom': 'team',
                  'unread': 0,
                },
                'messages': [
                  {
                    'id': 'm1',
                    'from': 'customer',
                    'text': 'That fixed it, sync works again.',
                    'createdAt': '2026-10-19T11:59:00Z',
                    'attachments': [],
                  },
                  {
                    'id': 'm2',
                    'from': 'team',
                    'authorName': 'Jay',
                    'text': "Great, glad it's working again!",
                    'createdAt': '2026-10-19T12:00:00Z',
                    'attachments': [],
                    'review': current,
                  },
                ],
              }),
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
        apiKey: () => 'key',
        read: (k) async => store[k],
        write: (k, v) async => v == null ? store.remove(k) : store[k] = v,
        profile: () async => {},
        isIOS: onIOS,
      );
    }

    setUp(() {
      requests = [];
      opened = [];
      current = Map.of(ios);
      eventStatus = 201;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(supportChannel, (call) async {
            if (call.method == 'openUrl') opened.add(call.arguments as String);
            return null;
          });
    });
    tearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(supportChannel, null),
    );

    Future<void> open(
      WidgetTester tester, {
      bool onIOS = true,
      Brightness brightness = Brightness.light,
    }) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        RepaintBoundary(
          key: shotKey,
          child: MaterialApp(
            theme: ThemeData(
              brightness: brightness,
              colorSchemeSeed: const Color(0xff7856ff),
            ),
            home: AppReferSupportView(
              api: chat(onIOS: onIOS),
              conversationId: 'c',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

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

    testWidgets(
      'tapping opens the App Store write-review page and records the tap',
      (tester) async {
        await open(tester);
        expect(find.text('Share your experience'), findsOneWidget);
        expect(
          find.text("If you'd like, you can write a review on the App Store."),
          findsOneWidget,
        );
        expect(find.byIcon(Icons.star), findsNothing);
        await capture(tester, 'review-card-light');
        await tester.tap(find.text('Write a review'));
        await tester.pumpAndSettle();
        expect(opened, [
          'https://apps.apple.com/app/id1234567890?action=write-review',
        ]);
        final events = requests
            .where((r) => r.url.path.endsWith('/events'))
            .toList();
        expect(events.map((r) => r.url.path).toSet(), {
          '/api/support/v1/conversations/c/reviews/rvc_0123456789abcdef01234567/events',
        });
        expect(
          events.map((r) => jsonDecode(r.body)['kind']),
          containsAll(['shown', 'opened']),
        );
        expect(
          requests
              .firstWhere(
                (r) => r.url.path == '/api/support/v1/conversations/c',
              )
              .headers['X-AppRefer-Support-Features'],
          contains('reviews'),
        );
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('Android opens the Google Play listing', (tester) async {
      current = Map.of(play);
      await open(tester, onIOS: false, brightness: Brightness.dark);
      expect(
        find.text("If you'd like, you can write a review on Google Play."),
        findsOneWidget,
      );
      await capture(tester, 'review-card-play-dark');
      await tester.tap(find.text('Write a review'));
      await tester.pumpAndSettle();
      expect(opened, [
        'https://play.google.com/store/apps/details?id=com.sparkly.app',
      ]);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a withdrawn card redraws instead of opening the store', (
      tester,
    ) async {
      await open(tester);
      eventStatus = 409;
      current = {
        ...ios,
        'status': 'unavailable',
        'reason': 'revoked',
        'url': null,
      };
      await tester.tap(find.text('Write a review'));
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(
        find.text('This review link is no longer available'),
        findsOneWidget,
      );
      expect(find.text('Write a review'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a foreign link from the server is never opened', (
      tester,
    ) async {
      current = {
        ...ios,
        'url': 'https://evil.example/app/id1234567890?action=write-review',
      };
      await open(tester);
      expect(find.text('Write a review'), findsNothing);
      expect(
        find.text("There's no store page for this device"),
        findsOneWidget,
      );
      expect(opened, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  });

  test('reset drops pending review receipts with the session', () async {
    final store = <String, String>{};
    final q = SupportOfferReceipts(
      read: (k) async => store[k],
      write: (k, v) async => v == null ? store.remove(k) : store[k] = v,
    );
    await q.enqueue(
      SupportOfferReceipt(
        conversationId: 'c',
        cardId: 'rvc_a',
        kind: 'opened',
        clientEventId: 'open_rvc00001',
        occurredAt: SupportOfferReceipt.iso(DateTime.now()),
      ),
    );
    expect(await q.pending, hasLength(1));
    await q.clear();
    expect(await q.pending, isEmpty);
    expect(AppReferSDK.support, isNotNull);
  });
}
