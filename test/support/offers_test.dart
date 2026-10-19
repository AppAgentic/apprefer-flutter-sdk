import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:apprefer/src/support/support_offers.dart';
import 'package:apprefer/src/support/support_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Offer cards (0.12.0): model, receipts, opening, API, the onOffer callback
/// and the card in the chat.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const cardJson = {
    'cardId': 'ofc_0123456789abcdef01234567',
    'offeringId': 'main',
    'packageId': null,
    'status': 'available',
    'reason': null,
    'eligibility': 'checked',
    'packages': [
      {
        'id': r'$ar_annual',
        'packageType': 'annual',
        'displayName': null,
        'productId': 'app.pro.annual',
        'current': false,
      },
      {
        'id': r'$ar_monthly',
        'packageType': 'monthly',
        'displayName': 'Monthly Pro',
        'productId': 'app.pro.monthly',
        'current': true,
      },
    ],
  };
  AppReferSupportOfferCard card([Map<String, Object?> over = const {}]) =>
      AppReferSupportOfferCard.fromJson({...cardJson, ...over})!;
  SupportOfferReceipts memory(
    Map<String, String> store, [
    DateTime Function()? now,
  ]) => SupportOfferReceipts(
    read: (k) async => store[k],
    write: (k, v) async => v == null ? store.remove(k) : store[k] = v,
    now: now,
  );

  setUp(() => SupportStrings.forcedLanguage = 'en');
  tearDown(() {
    SupportStrings.forcedLanguage = null;
    AppReferSDK.support.onOffer = null;
  });

  test('decodes cards and never draws something that is not one', () {
    final c = card();
    expect(c.offeringId, 'main');
    expect(c.isAvailable, isTrue);
    expect(c.packages.map((p) => p.current), [false, true]);
    expect(AppReferSupportOfferCard.fromJson({'cardId': 'ofc_x'}), isNull);
    expect(AppReferSupportOfferCard.fromJson('offer'), isNull);
    expect(AppReferSupportOfferCard.fromJson(null), isNull);
    expect(card({'packageId': r'$ar_annual'}).shownPackages.map((p) => p.id), [
      r'$ar_annual',
    ]);
  });

  test('look follows the server state and whether the app set onOffer', () {
    expect(SupportOfferLook.of(card(), true), SupportOfferLook.open);
    expect(SupportOfferLook.of(card(), false), SupportOfferLook.unsupported);
    expect(
      SupportOfferLook.unsupported.notice,
      "This offer can't be opened in this version of the app",
    );
    expect(
      SupportOfferLook.of(card({'status': 'owned'}), true),
      SupportOfferLook.owned,
    );
    expect(
      SupportOfferLook.of(card({'status': 'unavailable'}), true),
      SupportOfferLook.unavailable,
    );
    expect(
      SupportOfferLook.unavailable.notice,
      'This offer is no longer available',
    );
    expect(
      SupportOfferLook.of(card({'status': 'paused'}), true),
      SupportOfferLook.unavailable,
    );
  });

  test('package labels never invent a name', () {
    final c = card();
    expect(supportOfferLabel(c.packages[0], 'Pro Yearly'), 'Yearly');
    expect(supportOfferLabel(c.packages[1], null), 'Monthly Pro');
    const custom = AppReferSupportOfferPackage(
      id: 'gold',
      packageType: 'custom',
      productId: 'p',
    );
    expect(supportOfferLabel(custom, 'Gold Pack'), 'Gold Pack');
    expect(supportOfferLabel(custom, null), 'Option');
    SupportStrings.forcedLanguage = 'de';
    expect(supportOfferLabel(c.packages[0], null), 'Jährlich');
    expect(SupportStrings.text('support.offer.open'), 'Angebot ansehen');
  });

  test(
    'receipt queue persists, dedupes, drops old or over-retried ones',
    () async {
      final store = <String, String>{};
      final now = DateTime.utc(2026, 10, 19, 12);
      final q = memory(store, () => now);
      final a = SupportOfferReceipt(
        conversationId: 'cv1',
        cardId: 'ofc_a',
        kind: 'shown',
        clientEventId: 'shown_a',
        occurredAt: SupportOfferReceipt.iso(now),
      );
      await q.enqueue(a);
      await q.enqueue(a);
      expect(await memory(store, () => now).pending, [a]);
      await q.enqueue(
        SupportOfferReceipt(
          conversationId: 'cv1',
          cardId: 'ofc_b',
          kind: 'opened',
          clientEventId: 'open_old',
          occurredAt: SupportOfferReceipt.iso(
            now.subtract(const Duration(days: 8)),
          ),
        ),
      );
      expect(await q.pending, [a]);
      for (var i = 0; i < SupportOfferReceipts.maxAttempts - 1; i++) {
        await q.failed(a);
      }
      expect(
        (await q.pending).single.attempts,
        SupportOfferReceipts.maxAttempts - 1,
      );
      await q.failed(a);
      expect(await q.pending, isEmpty);
      for (var i = 0; i < 60; i++) {
        await q.enqueue(
          SupportOfferReceipt(
            conversationId: 'cv1',
            cardId: 'ofc_$i',
            kind: 'opened',
            clientEventId: 'open_$i',
            occurredAt: SupportOfferReceipt.iso(now),
          ),
        );
      }
      expect((await q.pending).length, SupportOfferReceipts.maxItems);
      await q.clear();
      expect(store, isEmpty);
      expect(
        SupportOfferReceipt.shownId('ofc_0123456789abcdef01234567'),
        'shown_0123456789abcdef01234567',
      );
      expect(
        RegExp(
          r'^open_[0-9a-f]{24}$',
        ).hasMatch(SupportOfferReceipt.eventId('open')),
        isTrue,
      );
    },
  );

  test('opener records, refuses or opens offline', () async {
    final store = <String, String>{};
    final q = memory(store);
    final opener = SupportOfferOpener(
      queue: q,
      send: (_) async => null,
      timeout: const Duration(seconds: 2),
    );
    final r1 = opener.receipt(card(), 'cv1');
    expect(r1.kind, 'opened');
    expect(await opener.check(r1), isA<SupportOfferRecorded>());
    expect(await q.pending, isEmpty);
    opener.send = (_) async =>
        throw SupportException(409, "This offer can't be opened (revoked).");
    expect(
      await opener.check(opener.receipt(card(), 'cv1')),
      isA<SupportOfferRefused>(),
    );
    expect(await q.pending, isEmpty);
    opener.send = (_) async => throw const SocketException('offline');
    final r3 = opener.receipt(card(), 'cv1');
    expect(await opener.check(r3), isA<SupportOfferOffline>());
    expect((await q.pending).map((r) => r.clientEventId), [r3.clientEventId]);
    opener.timeout = const Duration(milliseconds: 50);
    opener.send = (_) => Completer<AppReferSupportOfferCard?>().future;
    final started = DateTime.now();
    expect(
      await opener.check(opener.receipt(card(), 'cv1')),
      isA<SupportOfferOffline>(),
    );
    expect(DateTime.now().difference(started).inSeconds, lessThan(2));
    expect((await q.pending).length, 2);
  });

  SupportAPI make(
    Future<http.Response> Function(http.Request) handler,
    List<http.Request> requests,
    Map<String, String> store, {
    bool ios = true,
  }) => SupportAPI(
    client: MockClient((r) async {
      requests.add(r);
      if (r.url.path == '/api/support/v1/session')
        return http.Response('{"session":"ars_one","created":true}', 201);
      return handler(r);
    }),
    apiKey: () => 'pk_live_key',
    read: (k) async => store[k],
    write: (k, v) async => v == null ? store.remove(k) : store[k] = v,
    keys: () async => store.keys.toList(),
    profile: () async => {'appUserId': 'user_42'},
    identityCleared: () async => false,
    isIOS: ios,
  );

  test(
    'requests announce cards and ask for the platform\'s products',
    () async {
      final requests = <http.Request>[];
      final api = make(
        (r) async {
          if (r.url.path.endsWith('/offers'))
            return http.Response(
              jsonEncode({
                'offers': [cardJson, null],
              }),
              200,
            );
          return http.Response(
            jsonEncode({
              'conversation': {
                'id': 'cv1',
                'subject': 's',
                'status': 'open',
                'preview': 'p',
                'lastMessageAt': 'x',
                'lastFrom': 'team',
                'unread': 0,
              },
              'messages': [],
              'persona': null,
            }),
            200,
          );
        },
        requests,
        {},
        ios: false,
      );
      await api.thread('cv1', after: '2026-10-19T12:00:00.000Z');
      AppReferSDK.support.onOffer = (_) {};
      final cards = await api.offerCards('cv1');
      AppReferSDK.support.onOffer = null;
      expect(cards.map((c) => c.cardId), ['ofc_0123456789abcdef01234567']);
      final calls = requests
          .where((r) => r.url.path != '/api/support/v1/session')
          .toList();
      expect(calls[0].headers['X-AppRefer-Support-Features'], 'offers, reviews');
      expect(calls[0].url.queryParameters, {
        'platform': 'android',
        'after': '2026-10-19T12:00:00.000Z',
      });
      expect(calls[1].url.path, '/api/support/v1/conversations/cv1/offers');
      expect(calls[1].url.queryParameters, {'platform': 'android'});
      expect(
        calls[1].headers['X-AppRefer-Support-Features'],
        'offers, offer-handler, reviews',
      );
      expect(SupportOffers.hasHandler, isFalse);
    },
  );

  test(
    'flush sends once, keeps transient failures and drops refusals',
    () async {
      final requests = <http.Request>[];
      final store = <String, String>{};
      final api = make(
        (r) async {
          if (r.url.path.contains('ofc_flaky'))
            return http.Response('{"error":"busy"}', 503);
          if (r.url.path.contains('ofc_gone'))
            return http.Response('{"error":"Not found"}', 404);
          return http.Response(
            '{"eventId":"ofe_x","duplicate":false,"offer":null}',
            201,
          );
        },
        requests,
        store,
      );
      final at = SupportOfferReceipt.iso(DateTime.now());
      for (final id in ['ok', 'flaky', 'gone']) {
        await api.offerReceipts.enqueue(
          SupportOfferReceipt(
            conversationId: 'cv1',
            cardId: 'ofc_$id',
            kind: id == 'ok' ? 'shown' : 'opened',
            clientEventId: 'evt_${id}_00001',
            occurredAt: at,
          ),
        );
      }
      await api.flushOfferReceipts();
      final left = await api.offerReceipts.pending;
      expect(left.map((r) => r.cardId), ['ofc_flaky']);
      expect(left.single.attempts, 1);
      final ok = requests.singleWhere((r) => r.url.path.contains('ofc_ok'));
      expect(ok.method, 'POST');
      expect(
        ok.url.path,
        '/api/support/v1/conversations/cv1/offers/ofc_ok/events',
      );
      expect(ok.url.queryParameters, {'platform': 'ios'});
      expect(jsonDecode(ok.body), {
        'kind': 'shown',
        'clientEventId': 'evt_ok_00001',
        'occurredAt': at,
      });
    },
  );

  test('nothing opens without onOffer; setting it is announced', () {
    expect(
      AppReferSDK.support.deliverOffer(
        const AppReferSupportOffer(
          cardId: 'ofc_a',
          conversationId: 'cv1',
          offeringId: 'main',
        ),
      ),
      isFalse,
    );
    final got = <AppReferSupportOffer>[];
    AppReferSDK.support.onOffer = got.add;
    expect(SupportOffers.hasHandler, isTrue);
    const offer = AppReferSupportOffer(
      cardId: 'ofc_a',
      conversationId: 'cv1',
      offeringId: 'main',
      packageId: r'$ar_annual',
    );
    expect(AppReferSDK.support.deliverOffer(offer), isTrue);
    expect(got, [offer]);
  });

  group('in the chat', () {
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

    late List<http.Request> requests;
    late Map<String, Object?> current;
    late int eventStatus;
    SupportAPI chat() {
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
                        'code': 'OFFER_UNAVAILABLE',
                        'offer': {
                          ...current,
                          'status': 'unavailable',
                          'reason': 'revoked',
                        },
                      }
                    : {
                        'eventId': 'ofe_x',
                        'duplicate': false,
                        'offer': current,
                      },
              ),
              eventStatus,
            );
          }
          if (r.url.path.endsWith('/offers'))
            return http.Response(
              jsonEncode({
                'offers': [current],
              }),
              200,
            );
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                'conversation': {
                  'id': 'c',
                  'subject': 'Plans',
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
                    'text': 'Is there a yearly plan?',
                    'createdAt': '2026-10-19T11:59:00Z',
                    'attachments': [],
                  },
                  {
                    'id': 'm2',
                    'from': 'team',
                    'authorName': 'Jay',
                    'text': 'Here are the plans',
                    'createdAt': '2026-10-19T12:00:00Z',
                    'attachments': [],
                    'offer': current,
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
      );
    }

    setUp(() {
      requests = [];
      current = Map.of(cardJson);
      eventStatus = 201;
    });

    Future<void> open(
      WidgetTester tester, {
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
            home: AppReferSupportView(api: chat(), conversationId: 'c'),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'an open card hands the offering to the app and records the tap',
      (tester) async {
        final got = <AppReferSupportOffer>[];
        AppReferSDK.support.onOffer = got.add;
        await open(tester);
        expect(find.text('An offer for you'), findsOneWidget);
        expect(find.text('Yearly'), findsOneWidget);
        expect(find.text('Monthly Pro'), findsOneWidget);
        expect(find.text('Current plan'), findsOneWidget);
        // No prices without AppRefer Billing: never made up.
        expect(find.textContaining(r'$'), findsNothing);
        await capture(tester, 'offer-card-light');
        await tester.tap(find.text('View offer'));
        await tester.pumpAndSettle();
        expect(got.map((o) => (o.offeringId, o.conversationId, o.cardId)), [
          ('main', 'c', 'ofc_0123456789abcdef01234567'),
        ]);
        final events = requests
            .where((r) => r.url.path.endsWith('/events'))
            .map((r) => jsonDecode(r.body)['kind'])
            .toList();
        expect(events, containsAll(['shown', 'opened']));
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('a withdrawn card redraws instead of opening the paywall', (
      tester,
    ) async {
      final got = <AppReferSupportOffer>[];
      AppReferSDK.support.onOffer = got.add;
      await open(tester);
      eventStatus = 409;
      current = {...cardJson, 'status': 'unavailable', 'reason': 'revoked'};
      await tester.tap(find.text('View offer'));
      await tester.pumpAndSettle();
      expect(got, isEmpty);
      expect(find.text('This offer is no longer available'), findsOneWidget);
      expect(find.text('View offer'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
      'without onOffer the card says so honestly; disabled states in dark',
      (tester) async {
        await open(tester, brightness: Brightness.dark);
        expect(
          find.text("This offer can't be opened in this version of the app"),
          findsOneWidget,
        );
        expect(find.text('View offer'), findsNothing);
        await capture(tester, 'offer-card-unsupported-dark');
        await tester.pumpWidget(const SizedBox());
        current = {
          ...cardJson,
          'status': 'owned',
          'reason': 'owned',
          'packageId': r'$ar_monthly',
        };
        AppReferSDK.support.onOffer = (_) {};
        await open(tester, brightness: Brightness.dark);
        expect(find.text('You already have this'), findsOneWidget);
        await capture(tester, 'offer-card-owned-dark');
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
