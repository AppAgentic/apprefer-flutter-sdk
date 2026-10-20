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
      expect(t.submits[1].sublist(2), [true, '0123456789abcdef']);
      expect(
        flow.result,
        AppReferTestimonialResult(
          t.current.requestId,
          'submitted',
          'pending',
          'granted',
        ),
      );
    },
  );

  test(
    'only Submit agrees to the terms shown; opening, picking and cancelling send nothing',
    () async {
      final t = FakeTransport(request());
      final flow = TestimonialFlow(t.current.requestId, t);
      expect(flow.canSubmit, isFalse);
      await flow.load();
      expect(flow.hasTerms, isTrue);
      expect(flow.canSubmit, isFalse, reason: 'nothing picked yet');
      flow.picked(photo);
      expect(flow.canSubmit, isTrue);
      expect(flow.request?.permissionText, 'You may show this in the app.');
      expect(t.submits, isEmpty, reason: 'opening and picking record nothing');
      expect(t.slots, 0, reason: 'nothing is uploaded before Submit');
      await flow.submit();
      expect(t.submits.single.sublist(2), [true, '0123456789abcdef']);
      final declined = TestimonialFlow('tsr_x', FakeTransport(request()));
      await declined.load();
      declined.picked(photo);
      expect(
        (await declined.decline(false)).publication,
        isNull,
        reason: 'declining or cancelling sends no agreement',
      );
    },
  );

  test(
    'changed terms are shown again and only the next Submit agrees to them',
    () async {
      final t = FakeTransport(request());
      final flow = TestimonialFlow(t.current.requestId, t);
      await flow.load();
      flow.picked(photo);
      t.failSubmit = SupportException(409, 'changed', code: 'TERMS_CHANGED');
      t.current = request({
        ...requestJson(),
        'permission': {
          'text': 'You may show this in the app and on our website.',
          'scopes': ['in_app', 'website'],
          'version': 'fedcba9876543210',
        },
      });
      await flow.submit();
      expect(flow.phase, TestimonialPhase.ready);
      expect(
        flow.notice,
        'The terms have changed. Please read them, then submit again.',
      );
      expect(
        flow.request?.permissionText,
        'You may show this in the app and on our website.',
      );
      expect(
        t.submits.single[3],
        '0123456789abcdef',
        reason: 'the refused answer named the terms that were shown',
      );
      expect(flow.result.publication, isNull, reason: 'nothing was agreed');
      await flow.submit();
      expect(flow.phase, TestimonialPhase.done);
      expect(t.submits.last.sublist(2), [true, 'fedcba9876543210']);
      expect(t.submits.first[0], t.submits.last[0], reason: 'upload kept');
      expect(t.submits.first[1], t.submits.last[1], reason: 'same client id');
      expect(t.slots, 1);
    },
  );

  test('every language has the terms wrapper, Submit and the notice', () {
    for (final language in supportLanguages) {
      for (final key in [
        'support.testimonial.termsAgree',
        'support.testimonial.termsChanged',
        'support.testimonial.submit',
        'support.testimonial.rewardNote',
      ]) {
        expect(
          supportStringsTable[language]?[key],
          isNotEmpty,
          reason: '$key in $language',
        );
      }
      for (final gone in [
        'support.testimonial.publish',
        'support.testimonial.publishHint',
        'support.testimonial.submitPublic',
        'support.testimonial.submitPrivate',
      ]) {
        expect(supportStringsTable[language]?[gone], isNull, reason: gone);
      }
    }
    SupportStrings.forcedLanguage = 'de';
    expect(
      SupportStrings.text('support.testimonial.termsAgree'),
      'Mit dem Senden stimmst du diesen Bedingungen zu.',
    );
    expect(SupportStrings.text('support.testimonial.submit'), 'Senden');
  });

  test(
    'a request without terms can\'t be submitted and nothing is assumed',
    () async {
      final t = FakeTransport(request({...requestJson(), 'permission': null}));
      final flow = TestimonialFlow(t.current.requestId, t);
      await flow.load();
      expect(flow.request?.permissionVersion, isNull);
      expect(flow.phase, TestimonialPhase.unavailable);
      flow.picked(photo);
      expect(flow.canSubmit, isFalse);
      await flow.submit();
      expect(t.submits, isEmpty);
      expect(t.slots, 0);
      final noVersion = FakeTransport(
        request({
          ...requestJson(),
          'permission': {'text': 'You may show this in the app.'},
        }),
      );
      final other = TestimonialFlow(noVersion.current.requestId, noVersion);
      await other.load();
      expect(other.phase, TestimonialPhase.unavailable);
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

  testWidgets('the capture screen picks, shows the terms above Submit and shares', (
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
        'You get it for taking part, whatever you say and whether or not we use it.',
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
    expect(
      find.text('By submitting, you agree to these terms.'),
      findsOneWidget,
    );
    expect(find.byType(Switch), findsNothing, reason: 'no toggle');
    expect(find.byType(Checkbox), findsNothing, reason: 'no tick');
    expect(find.text('Allow public use'), findsNothing);
    expect(t.submits, isEmpty, reason: 'showing the terms records nothing');
    await tester.scrollUntilVisible(find.text('Submit'), 200);
    await tester.ensureVisible(find.text('Submit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Submit'));
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
      t.submits.single.sublist(2),
      [true, '0123456789abcdef'],
      reason: 'Submit agrees to the terms version that was on screen',
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
