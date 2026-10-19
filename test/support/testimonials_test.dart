import 'dart:convert';
import 'dart:io';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:apprefer/src/support/support_strings.dart';
import 'package:apprefer/src/support/support_style.dart';
import 'package:apprefer/src/support/support_testimonials.dart';
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
        "Couldn't share it. Check your connection and try again.",
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

  testWidgets(
    'the capture screen picks, asks permission separately and shares',
    (tester) async {
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
        find.text(
          'The reward doesn\'t depend on what you share or whether it\'s used.',
        ),
        findsOneWidget,
      );
      expect(find.text('Use camera'), findsNothing);
      await tester.tap(find.text('Choose from library'));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'testimonialPick').single.arguments,
        {'source': 'library', 'images': true, 'videos': true, 'maxSeconds': 30},
      );
      await tester.scrollUntilVisible(
        find.text('You may show this in the app.'),
        200,
      );
      expect(find.text('Allow public use'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Share'), 200);
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(find.text('Thanks for sharing!'), findsOneWidget);
      expect(find.text('Your reward is on its way.'), findsOneWidget);
      expect(
        t.submits.single[2],
        false,
        reason: 'public use stays off unless the customer switches it on',
      );
      // The done screen checks the reward a few times; let those checks run out.
      await tester.pump(const Duration(seconds: 60));
      await tester.pumpWidget(const SizedBox());
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        supportChannel,
        null,
      );
    },
  );
}
