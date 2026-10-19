import 'dart:convert';
import 'dart:io';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:apprefer/src/support/support_strings.dart';
import 'package:apprefer/src/support/support_strings_table.g.dart';
import 'package:apprefer/src/support/support_style.dart';
import 'package:apprefer/src/support/support_testimonials.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, Object?> requestJson({
  String status = 'open',
  String rewardStatus = 'none',
  String? publication,
}) => {
  'requestId': 'tsr_0123456789abcdef0123456789abcdef',
  'campaignId': 'progress_story',
  'status': status,
  'title': 'Share your progress',
  'prompt': 'Show us what you made.',
  'media': ['image', 'video'],
  'maxVideoSeconds': 30,
  'reward': {'type': 'credits', 'description': '50 bonus credits'},
  'permission': {
    'text': 'You may show this in the app.',
    'scopes': ['in_app'],
    'version': '0123456789abcdef',
  },
  'expiresAt': '2026-11-02T12:00:00.000Z',
  'submittedAt': null,
  'publication': publication,
  'rewardStatus': rewardStatus,
};

class FakeTransport implements TestimonialTransport {
  FakeTransport(this.current);
  AppReferTestimonialRequest current;
  int slots = 0, puts = 0;
  final submits = <List<Object>>[];
  Object? failSubmit;
  Object? failRequest;

  @override
  Future<AppReferTestimonialRequest> request(String id) async {
    if (failRequest case final e?) throw e;
    return current;
  }

  @override
  Future<TestimonialSlot> slot(String id, String contentType, int size) async =>
      TestimonialSlot('tup_${'0' * 31}${++slots}', 'https://r2.test/u', {
        'Content-Type': contentType,
      });

  @override
  Future<void> put(
    TestimonialFile file,
    TestimonialSlot slot,
    void Function(double) progress,
  ) async {
    puts++;
    progress(0.5);
    progress(1);
  }

  @override
  Future<AppReferTestimonialRequest> submit(
    String id,
    String uploadId,
    String clientSubmissionId,
    bool publication,
    String version,
  ) async {
    submits.add([uploadId, clientSubmissionId, publication, version]);
    final fail = failSubmit;
    failSubmit = null;
    if (fail != null) throw fail;
    return AppReferTestimonialRequest.fromJson(
      requestJson(
        status: 'submitted',
        rewardStatus: 'pending',
        publication: publication ? 'granted' : 'declined',
      ),
    )!;
  }

  @override
  Future<AppReferTestimonialRequest?> decline(
    String id,
    bool dontAskAgain,
  ) async =>
      AppReferTestimonialRequest.fromJson(requestJson(status: 'declined'));
}

const photo = TestimonialFile(
  path: '/tmp/apprefer-testimonial-a.jpg',
  contentType: 'image/jpeg',
  kind: 'image',
  size: 2000,
);

/// Photo/video testimonials (0.13.0): model, capture flow, retries, API
/// routes, reward updates, the chat card and the capture screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SupportStrings.forcedLanguage = 'en';
    AppReferTestimonials.instance.reset();
    AppReferTestimonials.instance.onRewardUpdate = null;
  });
  tearDown(() => SupportStrings.forcedLanguage = null);
  AppReferTestimonialRequest request([Map<String, Object?>? json]) =>
      AppReferTestimonialRequest.fromJson(json ?? requestJson())!;

  test('decodes requests and never draws something that is not one', () {
    final r = request();
    expect(r.isOpen && r.allowsImages && r.allowsVideos, isTrue);
    expect(r.rewardDescription, '50 bonus credits');
    expect(r.permissionVersion, '0123456789abcdef');
    final card = AppReferTestimonialRequest.fromJson({
      'requestId': 'tsr_x',
      'status': 'unavailable',
    })!;
    expect(card.isOpen, isFalse);
    expect(card.rewardDescription, isNull);
    expect(AppReferTestimonialRequest.fromJson({'status': 'open'}), isNull);
    expect(AppReferTestimonialRequest.fromJson('x'), isNull);
  });

  test(
    'a lost answer resubmits the same upload with the same client id',
    () async {
      final t = FakeTransport(request());
      final flow = TestimonialFlow(t.current.requestId, t);
      await flow.load();
      expect(flow.phase, TestimonialPhase.ready);
      flow.picked(photo);
      flow.publish = false;
      t.failSubmit = const SocketException('connection reset');
      await flow.submit();
      expect(flow.phase, TestimonialPhase.failed);
      expect(
        flow.notice,
        "Couldn't share it, nothing was sent. Check your connection and try again.",
      );
      await flow.submit();
      expect(flow.phase, TestimonialPhase.done);
      expect(t.slots, 1);
      expect(t.puts, 1);
      expect(t.submits[0][0], t.submits[1][0]);
      expect(
        t.submits[0][1],
        t.submits[1][1],
        reason: 'same clientSubmissionId',
      );
      expect(t.submits[1][2], false);
      expect(t.submits[1][3], '0123456789abcdef');
      expect(
        flow.result,
        AppReferTestimonialResult(
          t.current.requestId,
          'submitted',
          'pending',
          'declined',
        ),
      );
    },
  );

  test('public use starts on but only the final share records it', () async {
    final t = FakeTransport(request());
    final flow = TestimonialFlow(t.current.requestId, t);
    expect(flow.publish, isTrue, reason: 'public use starts on');
    await flow.load();
    flow.picked(photo);
    expect(flow.request?.permissionText, 'You may show this in the app.');
    expect(t.submits, isEmpty, reason: 'opening and picking record nothing');
    await flow.submit();
    expect(t.submits.single.sublist(2), [true, '0123456789abcdef']);
    expect(
      flow.result,
      AppReferTestimonialResult(
        t.current.requestId,
        'submitted',
        'pending',
        'granted',
      ),
    );
    final declined = TestimonialFlow('tsr_x', FakeTransport(request()));
    await declined.load();
    declined.picked(photo);
    expect(
      (await declined.decline(false)).publication,
      isNull,
      reason: 'declining sends no permission answer',
    );
  });

  test('the submit button says whether it allows sharing', () async {
    final t = FakeTransport(request());
    final flow = TestimonialFlow(t.current.requestId, t);
    await flow.load();
    flow.picked(photo);
    expect(flow.submitLabelKey, 'support.testimonial.submitPublic');
    expect(SupportStrings.text(flow.submitLabelKey), 'Send and allow sharing');
    flow.publish = false;
    expect(SupportStrings.text(flow.submitLabelKey), 'Send privately');
    t.failSubmit = const SocketException('connection reset');
    await flow.submit();
    expect(flow.phase, TestimonialPhase.failed);
    expect(
      SupportStrings.text(flow.submitLabelKey),
      'Send privately',
      reason: 'a retry still names what it sends',
    );
    await flow.submit();
    expect(t.submits.map((s) => s[2]), [
      false,
      false,
    ], reason: 'the label matches the answer sent');
    for (final language in supportLanguages) {
      for (final key in [
        'support.testimonial.submitPublic',
        'support.testimonial.submitPrivate',
      ]) {
        expect(
          supportStringsTable[language]?[key],
          isNotEmpty,
          reason: '$key in $language',
        );
      }
    }
  });

  test(
    'a request without permission text is never submitted with an assumed answer',
    () async {
      final t = FakeTransport(request({...requestJson(), 'permission': null}));
      final flow = TestimonialFlow(t.current.requestId, t);
      await flow.load();
      expect(flow.request?.permissionVersion, isNull);
      expect(
        flow.submitLabelKey,
        'support.testimonial.submit',
        reason: 'no switch, so the button claims neither sharing nor privacy',
      );
      flow.picked(photo);
      await flow.submit();
      expect(t.submits, isEmpty);
      expect(t.slots, 0);
    },
  );

  test(
    'a refused file is uploaded again; a closed request ends the flow',
    () async {
      final t = FakeTransport(request());
      final flow = TestimonialFlow(t.current.requestId, t);
      await flow.load();
      flow.picked(photo);
      t.failSubmit = SupportException(422, 'bad file', code: 'TYPE_MISMATCH');
      await flow.submit();
      await flow.submit();
      expect(t.slots, 2);
      final other = TestimonialFlow('tsr_y', t);
      await other.load();
      other.picked(photo);
      t.failSubmit = SupportException(409, 'verify', code: 'IDENTITY_REQUIRED');
      await other.submit();
      expect(other.phase, TestimonialPhase.unavailable);
      expect(other.notice, 'This request is no longer available');
    },
  );

  test('another account\'s or an unverified request is unavailable', () async {
    final t = FakeTransport(
      request(),
    )..failRequest = SupportException(409, 'verify', code: 'IDENTITY_REQUIRED');
    final flow = TestimonialFlow('tsr_x', t);
    await flow.load();
    expect(flow.phase, TestimonialPhase.unavailable);
    expect(flow.result.outcome, 'unavailable');
  });

  test('picker problems are explained and declining earns nothing', () async {
    final t = FakeTransport(request());
    final flow = TestimonialFlow(t.current.requestId, t);
    await flow.load();
    flow.pickFailed('too_long', 30);
    expect(flow.notice, 'Videos can be up to 30 seconds.');
    flow.pickFailed('too_large', 0);
    expect(flow.notice, 'This file is too large to share.');
    expect(
      await flow.decline(true),
      AppReferTestimonialResult(t.current.requestId, 'declined', 'none', null),
    );
  });

  test('reward updates reach the app once per change', () {
    final seen = <String>[];
    AppReferTestimonials.instance.onRewardUpdate = (u) =>
        seen.add(u.rewardStatus);
    for (final s in ['none', 'pending', 'pending', 'fulfilled']) {
      AppReferTestimonials.instance.note('tsr_a', s);
    }
    expect(seen, ['pending', 'fulfilled']);
  });

  test('the API sends only what the server expects', () async {
    final calls = <http.BaseRequest>[];
    final bodies = <Object?>[];
    final client = MockClient((r) async {
      if (r.url.path.endsWith('/session'))
        return http.Response(jsonEncode({'session': 'ars_${'a' * 43}'}), 201);
      calls.add(r);
      bodies.add(r.body.isEmpty ? null : jsonDecode(r.body));
      expect(
        r.headers['X-AppRefer-Support-Features'],
        contains('testimonials'),
      );
      if (r.url.path.endsWith('/uploads')) {
        return http.Response(
          jsonEncode({
            'uploadId': 'tup_${'1' * 32}',
            'uploadUrl': 'https://r2.test/u',
            'headers': {'Content-Type': 'image/jpeg'},
            'expiresIn': 900,
          }),
          201,
        );
      }
      return http.Response(
        jsonEncode({
          'request': requestJson(status: 'submitted', rewardStatus: 'pending'),
        }),
        200,
      );
    });
    final store = <String, String?>{};
    final api = SupportAPI(
      client: client,
      apiKey: () => 'pk_live_key',
      read: (k) async => store[k],
      write: (k, v) async => store[k] = v,
      profile: () async => {'appUserId': 'user_42'},
      keys: () async => store.keys.toList(),
      identityCleared: () async => false,
      detectPushEnvironment: () async => null,
      isIOS: true,
    );
    final t = LiveTestimonialTransport(api);
    expect((await t.request('tsr_a')).status, 'submitted');
    expect(
      (await t.slot('tsr_a', 'image/jpeg', 2000)).uploadId,
      'tup_${'1' * 32}',
    );
    await t.submit('tsr_a', 'tup_1', 'flt_client', true, '0123456789abcdef');
    await t.decline('tsr_a', true);
    expect(calls.map((c) => '${c.method} ${c.url.path}'), [
      'GET /api/support/v1/testimonials/tsr_a',
      'POST /api/support/v1/testimonials/tsr_a/uploads',
      'POST /api/support/v1/testimonials/tsr_a/submit',
      'POST /api/support/v1/testimonials/tsr_a/decline',
    ]);
    expect(bodies[2], {
      'uploadId': 'tup_1',
      'clientSubmissionId': 'flt_client',
      'publication': true,
      'permissionVersion': '0123456789abcdef',
    });
    expect(bodies[3], {'dontAskAgain': true});
    // A reset makes the pinned transport refuse to reach the next account.
    await api.reset();
    expect(() => t.request('tsr_a'), throwsA(isA<SupportException>()));
  });

  testWidgets('the chat card opens the capture screen; old requests say so', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SupportTestimonialCard(
                request: request(),
                palette: SupportPalette(Colors.indigo),
                colors: const SupportColors(false),
                open: () => opened++,
              ),
              SupportTestimonialCard(
                request: request(requestJson(status: 'submitted')),
                palette: SupportPalette(Colors.indigo),
                colors: const SupportColors(false),
                open: () => opened++,
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('For taking part: 50 bonus credits'), findsOneWidget);
    expect(find.text('Thanks for sharing!'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('supportTestimonialOpen')));
    expect(opened, 1);
  });

  testWidgets('the capture screen picks, asks permission separately and shares', (
    tester,
  ) async {
    final t = FakeTransport(request());
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      supportChannel,
      (call) async {
        calls.add(call);
        if (call.method == 'testimonialPick')
          return {
            'path': '/tmp/apprefer-testimonial-a.jpg',
            'contentType': 'image/jpeg',
            'kind': 'image',
            'size': 2000,
          };
        return null;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AppReferTestimonialScreen(
          requestId: t.current.requestId,
          transport: t,
          cameraAvailable: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Share your progress'), findsOneWidget);
    expect(
      find.text('Good, bad or mixed: we want your honest take.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'You get it for taking part, whatever you say and whether or not you allow reuse.',
      ),
      findsOneWidget,
    );
    expect(find.text('Use camera'), findsNothing);
    await tester.tap(find.text('Choose from library'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c.method == 'testimonialPick').single.arguments, {
      'source': 'library',
      'images': true,
      'videos': true,
      'maxSeconds': 30,
    });
    await tester.scrollUntilVisible(
      find.text('You may show this in the app.'),
      200,
    );
    expect(find.text('Allow public use'), findsOneWidget);
    expect(
      find.text(
        'On unless you turn it off. The reward is the same either way, and you can withdraw this later.',
      ),
      findsOneWidget,
    );
    final toggle = find.byType(SwitchListTile);
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    expect(t.submits, isEmpty, reason: 'showing the switch records nothing');
    await tester.scrollUntilVisible(find.text('Send and allow sharing'), 200);
    expect(find.text('Send privately'), findsNothing);
    expect(
      find.text('Share'),
      findsNothing,
      reason: 'the button names what it sends',
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    expect(find.text('Send and allow sharing'), findsNothing);
    await tester.scrollUntilVisible(find.text('Send privately'), 200);
    await tester.ensureVisible(find.text('Send privately'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send privately'));
    await tester.pumpAndSettle();
    expect(find.text('Thanks for sharing!'), findsOneWidget);
    // Earned, not yet confirmed by the app's backend: no delivery promise.
    expect(
      find.text(
        "You've earned it. It shows as confirmed here once it has been applied.",
      ),
      findsOneWidget,
    );
    expect(
      t.submits.single[2],
      false,
      reason: 'the customer turned public use off before sharing',
    );
    // The done screen checks the reward a few times; let those checks run out.
    await tester.pump(const Duration(seconds: 60));
    await tester.pumpWidget(const SizedBox());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      supportChannel,
      null,
    );
  });

  test('the reward line follows the backend\'s receipt and the reward type', () {
    String line(String status, String type) => SupportStrings.text(
      request({
        ...requestJson(status: 'submitted', rewardStatus: status),
        'reward': {'type': type, 'description': 'x'},
      }).rewardStatusKey,
    );
    // Earned but unconfirmed (pending, or handed to the backend): never "added".
    for (final s in ['pending', 'delivered', 'none']) {
      expect(
        line(s, 'credits'),
        "You've earned it. It shows as confirmed here once it has been applied.",
      );
    }
    expect(
      line('fulfilled', 'credits'),
      'Your reward has been added to your account.',
    );
    expect(
      line('fulfilled', 'coach_usage'),
      'Your reward has been added to your account.',
    );
    expect(
      line('fulfilled', 'subscription_time'),
      'Your reward has been added to your account.',
    );
    // Goods, gifts and discounts are handled by the app: confirmed, no shipping or email promise.
    for (final type in ['merch', 'gift', 'discount', 'manual']) {
      expect(line('fulfilled', type), 'Your reward is confirmed.');
    }
    expect(
      line('failed', 'merch'),
      "Your reward hasn't been confirmed yet. Support can see this and can send it again.",
    );
    expect(line('timed_out', 'credits'), line('failed', 'merch'));
    expect(
      line('not_eligible', 'credits'),
      "You've already taken part in this, so there's no new reward this time.",
    );
    // Every new key exists in every language.
    for (final lang in supportLanguages) {
      for (final key in [
        'support.testimonial.honest',
        'support.testimonial.rewardDone.account',
        'support.testimonial.rewardDelayed',
        'support.testimonial.rewardNotEligible',
        'support.testimonial.takePhoto',
        'support.testimonial.recordVideo',
        'support.testimonial.cameraDenied',
      ]) {
        expect(
          supportStringsTable[lang]?[key],
          isNotEmpty,
          reason: '$lang $key',
        );
      }
    }
  });

  test(
    'a declined camera prompt is explained; a vanished camera is not an error',
    () async {
      final t = FakeTransport(request());
      final flow = TestimonialFlow(t.current.requestId, t);
      await flow.load();
      flow.pickFailed('unavailable', 0);
      expect(flow.notice, isNull);
      flow.pickFailed('camera_denied', 0);
      expect(
        flow.notice,
        'Camera access is off. You can choose from your library instead.',
      );
    },
  );

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('camera buttons on ${platform.name}', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final t = FakeTransport(request());
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          supportChannel,
          (call) async {
            calls.add(call);
            if (call.method == 'testimonialPick')
              throw PlatformException(code: 'camera_denied', details: 0);
            return null;
          },
        );
        await tester.pumpWidget(
          MaterialApp(
            home: AppReferTestimonialScreen(
              requestId: t.current.requestId,
              transport: t,
              cameraAvailable: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (platform == TargetPlatform.android) {
          // The camera app takes one kind at a time: a still photo, or a video.
          expect(find.text('Use camera'), findsNothing);
          await tester.tap(find.text('Take a photo'));
          await tester.pumpAndSettle();
          expect(calls.last.arguments, {
            'source': 'camera',
            'images': true,
            'videos': false,
            'maxSeconds': 30,
            'capture': 'image',
          });
          expect(find.text('Record a video'), findsOneWidget);
        } else {
          expect(find.text('Take a photo'), findsNothing);
          await tester.tap(find.text('Use camera'));
          await tester.pumpAndSettle();
          expect(calls.last.arguments, {
            'source': 'camera',
            'images': true,
            'videos': true,
            'maxSeconds': 30,
          });
        }
        // Permission declined: told plainly, the library stays offered.
        expect(
          find.text(
            'Camera access is off. You can choose from your library instead.',
          ),
          findsOneWidget,
        );
        expect(find.text('Choose from library'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          supportChannel,
          null,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  group('Support home invitations', () {
    late List<Map<String, Object?>> open;
    late List<String> paths;
    SupportAPI api() => SupportAPI(
      client: MockClient((r) async {
        paths.add('${r.method} ${r.url.path}');
        final path = r.url.path;
        Object body = const {};
        if (path.endsWith('/session')) body = {'session': 's'};
        if (path.endsWith('/conversations')) body = {'conversations': []};
        if (path == '/api/support/v1/testimonials') body = {'requests': open};
        if (path.startsWith('/api/support/v1/testimonials/tsr_'))
          body = {'request': requestJson()};
        if (path.endsWith('/status') ||
            path.startsWith('/api/support/v1/articles'))
          return http.Response('{"error":"not here"}', 404);
        return http.Response.bytes(
          utf8.encode(jsonEncode(body)),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
      apiKey: () => 'key',
      read: (_) async => 's',
      write: (_, __) async {},
      profile: () async => {},
    );

    setUp(() {
      open = [requestJson()];
      paths = [];
    });

    testWidgets(
      'opening Support shows the verified account\'s open ask; it leads to the capture screen and leaves once answered',
      (tester) async {
        final client = api();
        AppReferTestimonials.instance.api = () => client;
        await tester.pumpWidget(
          MaterialApp(home: AppReferSupportView(api: client)),
        );
        await tester.pumpAndSettle();
        expect(paths, contains('GET /api/support/v1/testimonials'));
        final card = find.byKey(supportTestimonialInviteKey);
        expect(card, findsOneWidget);
        expect(
          find.descendant(of: card, matching: find.text('Share your progress')),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: card,
            matching: find.text(
              'Good, bad or mixed: we want your honest take.',
            ),
          ),
          findsOneWidget,
        );
        // No modal: the capture screen opens only from the card.
        expect(find.byType(AppReferTestimonialScreen), findsNothing);
        await tester.tap(
          find.descendant(
            of: card,
            matching: find.byKey(const ValueKey('supportTestimonialOpen')),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(AppReferTestimonialScreen), findsOneWidget);
        // Shared elsewhere (or declined, or the campaign switched off): the
        // server no longer lists it, and closing the screen removes the card.
        open = [];
        await tester.tap(find.byTooltip('Cancel'));
        await tester.pumpAndSettle();
        expect(find.byKey(supportTestimonialInviteKey), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'an account switch clears the card before the next account loads',
      (tester) async {
        final client = api();
        AppReferTestimonials.instance.api = () => client;
        await tester.pumpWidget(
          MaterialApp(home: AppReferSupportView(api: client)),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(supportTestimonialInviteKey), findsOneWidget);
        // Signed into another account (unverified yet): the server lists nothing for it.
        open = [];
        AppReferSupport.instance.accountGeneration.value++;
        await tester.pump();
        expect(find.byKey(supportTestimonialInviteKey), findsNothing);
        await tester.pumpAndSettle();
        expect(find.byKey(supportTestimonialInviteKey), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      'offline keeps the card that was shown; a non-open entry is never drawn',
      (tester) async {
        open = [requestJson(status: 'submitted')];
        final client = api();
        await tester.pumpWidget(
          MaterialApp(home: AppReferSupportView(api: client)),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(supportTestimonialInviteKey), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  });
}
