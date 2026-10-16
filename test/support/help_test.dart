import 'dart:convert';
import 'dart:io';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:apprefer/src/support/support_help.dart';
import 'package:apprefer/src/support/support_strings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const listJSON = '''
{"articles":[{"slug":"refunds","title":"Refunds","summary":"How refunds work","category":"Billing","locale":"de","url":"https://help.example.com/refunds","status":"published","updatedAt":"2026-10-15T09:00:00.000Z"},
             {"slug":"draft-1","title":"Coming soon","summary":"","category":null,"locale":null,"url":null,"status":"draft","updatedAt":"2026-10-16T09:00:00Z"}],"locale":"de"}
''';
const statusJSON = '''
{"push":{"ios":{"configured":true,"verified":true,"checkedAt":"2026-10-16T09:00:00.000Z","environments":{"production":true,"sandbox":null}},
         "android":{"configured":true,"verified":false,"checkedAt":"2026-10-16T09:00:00.000Z","error":"No permission"}},
 "email":{"configured":true,"verified":null,"receivesReplies":true},"helpCentre":{"publishedArticles":12}}
''';

http.Response json(
  String body, [
  int status = 200,
  Map<String, String>? headers,
]) => http.Response.bytes(
  utf8.encode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8', ...?headers},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<http.Request> requests;
  late DateTime now;
  late String? key;
  setUp(() {
    requests = [];
    now = DateTime.utc(2027, 1, 15, 8);
    key = 'pk_test_help';
    SupportStrings.overrides = {};
    SupportStrings.forcedLanguage = null;
    SupportStrings.appLocales = null;
    SupportStrings.deviceLocales = () => const [Locale('en', 'US')];
  });

  SupportHelpClient client(
    Future<http.Response?> Function(http.Request) handler, {
    bool isIOS = false,
  }) => SupportHelpClient(
    client: () => MockClient((r) async {
      requests.add(r);
      final response = await handler(r);
      if (response == null) throw const SocketException('offline');
      return response;
    }),
    apiKey: () => key,
    baseUrl: 'https://help.test',
    now: () => now,
    isIOS: isIOS,
  );
  List<http.Request> articleRequests() => requests
      .where((r) => r.url.path.startsWith('/api/support/v1/articles'))
      .toList();

  group('articles', () {
    test('list sends the key, locale and query without a session', () async {
      final help = client((_) async => json(listJSON));
      final articles = await help.list('  c++ & refunds ', 'pt-BR');
      expect(articles.map((a) => a.slug), ['refunds', 'draft-1']);
      final r = articleRequests().last;
      expect(r.method, 'GET');
      expect(r.url.path, '/api/support/v1/articles');
      expect(r.headers['X-AppRefer-Key'], 'pk_test_help');
      expect(r.headers.containsKey('X-AppRefer-Support-Session'), isFalse);
      expect(r.headers['Accept-Language'], 'pt-BR');
      expect(r.url.queryParameters['locale'], 'pt-BR');
      expect(
        r.url.queryParameters['q'],
        'c++ & refunds',
        reason: 'trimmed, + and & survive',
      );
      expect(r.url.toString(), contains('q=c%2B%2B%20%26%20refunds'));
      expect(requests.any((r) => r.url.path.endsWith('/session')), isFalse);
    });

    test('no q without a query, long queries are cut', () async {
      final help = client((_) async => json(listJSON));
      await help.list('   ', 'en');
      expect(
        articleRequests().last.url.queryParameters.containsKey('q'),
        isFalse,
      );
      await help.list('a' * 250, 'en');
      expect(articleRequests().last.url.queryParameters['q'], hasLength(200));
    });

    test('decodes articles and drafts', () async {
      final articles = await client(
        (_) async => json(listJSON),
      ).list(null, 'de');
      expect(articles[0].category, 'Billing');
      expect(articles[0].webUrl, 'https://help.example.com/refunds');
      expect(articles[0].updatedDate, isNotNull);
      expect(articles[0].isDraft, isFalse);
      expect(articles[1].isDraft, isTrue);
      expect(articles[1].category, isNull);
      expect(articles[1].webUrl, isNull);
    });

    test('cached five minutes per key and language, then refetched', () async {
      final help = client((_) async => json(listJSON));
      await help.list(null, 'en');
      now = now.add(const Duration(seconds: 299));
      await help.list(null, 'en');
      expect(articleRequests(), hasLength(1));
      await help.list(null, 'de');
      expect(articleRequests(), hasLength(2));
      now = now.add(const Duration(seconds: 2));
      await help.list(null, 'en');
      expect(articleRequests(), hasLength(3));
      key = 'pk_test_other';
      await help.list(null, 'en');
      expect(
        articleRequests(),
        hasLength(4),
        reason: 'another SDK key is another list',
      );
    });

    test('offline returns the last list, otherwise throws', () async {
      http.Response? Function(http.Request) reply = (_) => json(listJSON);
      final help = client((r) async => reply(r));
      await help.list(null, 'en');
      now = now.add(const Duration(hours: 1));
      reply = (_) => null;
      expect(await help.list(null, 'en'), hasLength(2));
      expect(help.cachedList('en'), hasLength(2));
      await expectLater(help.list(null, 'fr'), throwsA(isA<SocketException>()));
      reply = (_) => json('{"error":"down"}', 503);
      await expectLater(
        help.list('x', 'en'),
        throwsA(isA<SupportException>().having((e) => e.status, 'status', 503)),
      );
    });

    test(
      'article decodes its body; 404 throws and is never hidden by the cache',
      () async {
        var offline = false;
        final help = client((r) async {
          if (offline) return null;
          if (r.url.path.endsWith('/missing'))
            return json('{"error":"Article not found"}', 404);
          return json(
            '{"article":{"slug":"a b","title":"Refunds","summary":"s","category":null,"locale":"en","url":null,"status":"published","updatedAt":"2026-10-15T09:00:00Z","body":"# Refunds\\n\\nText"}}',
          );
        });
        final article = await help.article('a b', 'en');
        expect(article.title, 'Refunds');
        expect(article.body, '# Refunds\n\nText');
        expect(
          articleRequests().last.url.toString(),
          'https://help.test/api/support/v1/articles/a%20b?locale=en',
        );
        await expectLater(
          help.article('missing', 'en'),
          throwsA(
            isA<SupportException>().having((e) => e.status, 'status', 404),
          ),
        );
        now = now.add(const Duration(hours: 1));
        offline = true;
        expect((await help.article('a b', 'en')).title, 'Refunds');
      },
    );

    test('without an API key the help centre is unavailable', () async {
      key = null;
      final help = client((_) async => json(listJSON));
      await expectLater(
        help.list(null, 'en'),
        throwsA(
          isA<SupportException>().having(
            (e) => e.reason,
            'reason',
            SupportErrorReason.unavailable,
          ),
        ),
      );
      expect(requests, isEmpty);
    });
  });

  group('status', () {
    test('mapping', () {
      final android = AppReferSupportStatus.fromJson(
        jsonDecode(statusJSON),
        isIOS: false,
      );
      expect(android.pushReady, isFalse, reason: 'Android was rejected');
      expect(android.emailReplies, isTrue);
      expect(android.helpCentreArticles, 12);
      expect(android.android.error, 'No permission');
      expect(android.emailVerified, isNull);
      final ios = AppReferSupportStatus.fromJson(
        jsonDecode(statusJSON),
        isIOS: true,
      );
      expect(ios.pushReady, isTrue);
      expect(ios.ios.environments?['production'], isTrue);
      final empty = AppReferSupportStatus.fromJson(const {}, isIOS: true);
      expect(empty.pushReady, isFalse);
      expect(empty.emailReplies, isFalse);
      expect(empty.helpCentreArticles, 0);
    });

    test('mixed APNs environments fail closed on iOS only', () {
      for (final env in [
        {'production': false, 'sandbox': true},
        {'production': true, 'sandbox': false},
      ]) {
        final json = {
          'push': {
            'ios': {'configured': true, 'verified': true, 'environments': env},
            'android': {'configured': true, 'verified': true},
          },
        };
        expect(
          AppReferSupportStatus.fromJson(json, isIOS: true).pushReady,
          isFalse,
        );
        expect(
          AppReferSupportStatus.fromJson(json, isIOS: false).pushReady,
          isTrue,
        );
      }
    });

    test('pushReady truth table', () {
      AppReferSupportStatus status(
        bool configured,
        bool? verified, {
        required bool isIOS,
      }) => AppReferSupportStatus(
        ios: AppReferSupportPushChannel(
          configured: configured,
          verified: verified,
        ),
        android: const AppReferSupportPushChannel(
          configured: false,
          verified: null,
        ),
        emailConfigured: false,
        emailReceivesReplies: false,
        helpCentreArticles: 0,
        isIOS: isIOS,
      );
      expect(status(true, true, isIOS: true).pushReady, isTrue);
      expect(status(true, false, isIOS: true).pushReady, isFalse);
      expect(
        status(true, null, isIOS: true).pushReady,
        isFalse,
        reason: 'not checked yet',
      );
      expect(status(false, null, isIOS: true).pushReady, isFalse);
      expect(status(false, true, isIOS: true).pushReady, isFalse);
      expect(
        status(true, true, isIOS: false).pushReady,
        isFalse,
        reason: 'iOS ready never makes Android ready',
      );
    });

    test('honours Cache-Control', () async {
      var maxAge = 300;
      final help = client(
        (_) async => json(statusJSON, 200, {
          'cache-control': 'private, max-age=$maxAge',
        }),
      );
      List<http.Request> calls() => requests
          .where((r) => r.url.path == '/api/support/v1/status')
          .toList();
      await help.status();
      now = now.add(const Duration(seconds: 299));
      await help.status();
      expect(calls(), hasLength(1));
      expect(calls().first.headers['X-AppRefer-Key'], 'pk_test_help');
      now = now.add(const Duration(seconds: 2));
      maxAge = 30;
      await help.status();
      expect(calls(), hasLength(2));
      now = now.add(const Duration(seconds: 29));
      await help.status();
      expect(calls(), hasLength(2));
      now = now.add(const Duration(seconds: 2));
      await help.status();
      expect(calls(), hasLength(3));
    });

    test('max-age parsing', () {
      expect(SupportHelpClient.maxAgeSeconds('private, max-age=300'), 300);
      expect(SupportHelpClient.maxAgeSeconds('max-age=30'), 30);
      expect(SupportHelpClient.maxAgeSeconds('max-age=99999'), 300);
      expect(SupportHelpClient.maxAgeSeconds('no-store'), 0);
      expect(SupportHelpClient.maxAgeSeconds('private'), isNull);
      expect(SupportHelpClient.maxAgeSeconds(null), isNull);
    });
  });

  group('markdown', () {
    test('unsafe links are dropped', () {
      final text = SupportMarkdown.inline(
        '[a](javascript:alert(1)) [b](https://ok.example/x) [c](mailto:help@example.com) [d](data:text/html,hi) [e](/relative) [f](myapp://open) [g](JAVASCRIPT:alert(1)) <javascript:alert(2)> [h](http:no-host) [i](vbscript:x) [j]( https://spaced.example )',
      );
      expect(text.links, [
        'https://ok.example/x',
        'mailto:help@example.com',
        'https://spaced.example',
      ]);
      expect(text.text, startsWith('a b c d e f g'));
      expect(text.text, isNot(contains('](')));
    });

    test('safeUrl', () {
      expect(SupportMarkdown.safeUrl('https://example.com'), isNotNull);
      expect(SupportMarkdown.safeUrl('HTTP://example.com/a?b=c'), isNotNull);
      expect(SupportMarkdown.safeUrl('mailto:a@b.co'), isNotNull);
      for (final bad in [
        'mailto:',
        'javascript:alert(1)',
        'java\nscript:alert(1)',
        'file:///etc/passwd',
        'tel:123',
        '//example.com',
        null,
      ]) {
        expect(SupportMarkdown.safeUrl(bad), isNull, reason: '$bad');
      }
    });

    test('HTML is never kept', () {
      final text = SupportMarkdown.inline(
        "Hi <script>alert('x')</script><b>there</b> <img src=x onerror=alert(1)> `<div>` <https://example.com>",
      );
      expect(text.text, isNot(contains('alert')));
      expect(text.text, isNot(contains('<b>')));
      expect(text.text, isNot(contains('onerror')));
      expect(text.text, contains('there'));
      expect(
        text.text,
        contains('<div>'),
        reason: 'code spans keep their text',
      );
      expect(text.links, ['https://example.com']);
      expect(
        SupportMarkdown.inline('Before <script>steal()').text,
        isNot(contains('steal')),
      );
    });

    test('inline styles', () {
      final text = SupportMarkdown.inline(
        '**bold** *it* `code` ~~gone~~ __also__ _em_ snake_case_name * alone',
      );
      expect(text.text, 'bold it code gone also em snake_case_name * alone');
      final styles = [
        for (final s in text.spans)
          (s.style, text.text.substring(s.start, s.end)),
      ];
      expect(
        styles,
        containsAll([
          (SupportInlineStyle.bold, 'bold'),
          (SupportInlineStyle.italic, 'it'),
          (SupportInlineStyle.code, 'code'),
          (SupportInlineStyle.strike, 'gone'),
          (SupportInlineStyle.bold, 'also'),
          (SupportInlineStyle.italic, 'em'),
        ]),
      );
      final nested = SupportMarkdown.inline(
        '*see **this** [link](https://a.example)*',
      );
      expect(nested.text, 'see this link');
      expect(nested.links, ['https://a.example']);
      expect(
        nested.spans.any(
          (s) =>
              s.style == SupportInlineStyle.bold &&
              nested.text.substring(s.start, s.end) == 'this',
        ),
        isTrue,
      );
      expect(SupportMarkdown.inline(r'a\*b').text, 'a*b');
    });

    test('blocks', () {
      const md = '''
# Title #
Intro line one
continues here.

## Steps
1. Open **Settings**
2. Tap [Restore](https://example.com/restore)
   and wait
- Top
  - Nested
* [ ] todo

> A quote
> over two lines

```
let x = "<b>"
```
---
![Screen](https://example.com/s.png "Title")
![Bad](javascript:alert(1))
Setext
======''';
      final blocks = SupportMarkdown.blocks(md);
      expect(blocks, hasLength(14), reason: '$blocks');
      expect(blocks[0], const SupportHeadingBlock(1, SupportRichText('Title')));
      expect(
        (blocks[1] as SupportParagraphBlock).text.text,
        'Intro line one continues here.',
      );
      expect((blocks[2] as SupportHeadingBlock).level, 2);
      final one = blocks[3] as SupportListItemBlock;
      expect((one.number, one.depth, one.text.text), (1, 0, 'Open Settings'));
      final two = blocks[4] as SupportListItemBlock;
      expect(two.number, 2);
      expect(two.text.text, 'Tap Restore and wait');
      expect(two.text.links, ['https://example.com/restore']);
      expect((blocks[5] as SupportListItemBlock).number, isNull);
      expect((blocks[6] as SupportListItemBlock).depth, 1);
      expect((blocks[7] as SupportListItemBlock).text.text, startsWith('☐'));
      expect(
        (blocks[8] as SupportQuoteBlock).text.text,
        'A quote over two lines',
      );
      expect(blocks[9], const SupportCodeBlock('let x = "<b>"'));
      expect(blocks[10], const SupportRuleBlock());
      expect(
        blocks[11],
        const SupportImageBlock('https://example.com/s.png', 'Screen'),
      );
      expect(
        (blocks[12] as SupportParagraphBlock).text.text,
        'Bad',
        reason: 'unsafe image becomes its alt text',
      );
      expect(
        blocks[13],
        const SupportHeadingBlock(1, SupportRichText('Setext')),
      );
    });

    test('setext, rules and empty input', () {
      expect(SupportMarkdown.blocks(''), isEmpty);
      expect(SupportMarkdown.blocks('Big\n==='), [
        const SupportHeadingBlock(1, SupportRichText('Big')),
      ]);
      expect(SupportMarkdown.blocks('Small\n---'), [
        const SupportHeadingBlock(2, SupportRichText('Small')),
      ]);
      expect(SupportMarkdown.blocks('***'), [const SupportRuleBlock()]);
      expect(
        SupportMarkdown.blocks('#hashtag').single,
        isA<SupportParagraphBlock>(),
      );
      expect(SupportMarkdown.blocks('```dart\na\nb'), [
        const SupportCodeBlock('a\nb'),
      ]);
    });
  });

  group('logic', () {
    AppReferHelpArticle article(String slug, String? category) =>
        AppReferHelpArticle(
          slug: slug,
          title: slug.toUpperCase(),
          summary: 'About $slug',
          category: category,
        );

    test('groups by category, loose articles last', () {
      final groups = supportHelpGroups([
        article('a', 'Billing'),
        article('b', null),
        article('c', 'Account'),
        article('d', 'Billing'),
      ]);
      expect(groups.map((g) => g.$1), ['Billing', 'Account', 'More articles']);
      expect(groups[0].$2.map((a) => a.slug), ['a', 'd']);
      expect(supportHelpGroups([article('x', null)]).map((g) => g.$1), [null]);
      expect(supportHelpGroups([]), isEmpty);
    });

    test('local search matches every word ignoring case and accents', () {
      const list = [
        AppReferHelpArticle(
          slug: '1',
          title: 'Café refunds',
          summary: 'Money back',
        ),
        AppReferHelpArticle(
          slug: '2',
          title: 'Login',
          summary: 'Password reset',
        ),
      ];
      expect(supportHelpLocalMatches(list, 'cafe MONEY').map((a) => a.slug), [
        '1',
      ]);
      expect(supportHelpLocalMatches(list, 'reset').map((a) => a.slug), ['2']);
      expect(supportHelpLocalMatches(list, 'nothing'), isEmpty);
    });

    test('reply notice follows the status', () {
      AppReferSupportStatus status(bool push, bool email) =>
          AppReferSupportStatus(
            ios: AppReferSupportPushChannel(
              configured: push,
              verified: push ? true : null,
            ),
            android: AppReferSupportPushChannel(
              configured: push,
              verified: push ? true : null,
            ),
            emailConfigured: email,
            emailReceivesReplies: email,
            helpCentreArticles: 0,
          );
      expect(
        SupportReplyNotice.choose(null, hasPushToken: false, hasEmail: false),
        SupportReplyNotice.push,
      );
      expect(
        SupportReplyNotice.choose(
          status(true, true),
          hasPushToken: true,
          hasEmail: true,
        ),
        SupportReplyNotice.push,
      );
      expect(
        SupportReplyNotice.choose(
          status(true, true),
          hasPushToken: false,
          hasEmail: true,
        ),
        SupportReplyNotice.email,
      );
      expect(
        SupportReplyNotice.choose(
          status(false, true),
          hasPushToken: true,
          hasEmail: true,
        ),
        SupportReplyNotice.email,
      );
      expect(
        SupportReplyNotice.choose(
          status(false, true),
          hasPushToken: true,
          hasEmail: false,
        ),
        SupportReplyNotice.inApp,
      );
      expect(
        SupportReplyNotice.choose(
          status(false, false),
          hasPushToken: false,
          hasEmail: true,
        ),
        SupportReplyNotice.inApp,
      );
      expect(
        SupportReplyNotice.email.text(null),
        "Sent · we'll email you when the team replies",
      );
      expect(
        SupportReplyNotice.inApp.text('12:30'),
        "Sent 12:30 · the team's reply will appear here",
      );
    });
  });

  test('new keys are in every language with their placeholders', () {
    const keys = [
      'support.help.title',
      'support.help.search.placeholder',
      'support.help.search.noResults',
      'support.help.search.noResultsHint',
      'support.help.searching',
      'support.help.seeAll',
      'support.help.loading',
      'support.help.loadFailed',
      'support.help.listFailed',
      'support.help.updated',
      'support.help.draft',
      'support.help.otherCategory',
      'support.help.stillNeedHelp',
      'support.help.messageUs',
      'support.help.prompt',
      'support.help.openInBrowser',
      'support.help.a11y.clearSearch',
      'support.help.a11y.article',
      'support.status.sentNoticeEmail',
      'support.status.sentNoticeEmailNoTime',
      'support.status.sentNoticeInApp',
      'support.status.sentNoticeInAppNoTime',
    ];
    expect(SupportStrings.supportedLanguages, hasLength(35));
    for (final language in SupportStrings.supportedLanguages) {
      for (final k in keys) {
        expect(
          SupportStrings.bundled(k, language),
          isNotNull,
          reason: '$language: $k',
        );
      }
      expect(
        SupportStrings.bundled('support.help.search.noResults', language),
        contains('{query}'),
      );
      expect(
        SupportStrings.bundled('support.help.updated', language),
        contains('{date}'),
      );
    }
    SupportStrings.forcedLanguage = 'de';
    expect(
      SupportStrings.text('support.help.search.noResults', {'query': 'Abo'}),
      'Keine Artikel zu „Abo“',
    );
  });

  group('help centre UI', () {
    SupportAPI api({
      required bool withArticles,
      List<http.Request>? log,
    }) => SupportAPI(
      client: MockClient((r) async {
        log?.add(r);
        final path = r.url.path;
        if (path.endsWith('/session')) return json('{"session":"s"}');
        if (path.endsWith('/status')) return json(statusJSON);
        if (path == '/api/support/v1/articles') {
          return withArticles
              ? json(
                  r.url.queryParameters.containsKey('q')
                      ? '{"articles":[{"slug":"refunds","title":"Refunds","summary":"How refunds work","updatedAt":"2026-10-15T09:00:00Z"}]}'
                      : listJSON,
                )
              : json('{"articles":[]}');
        }
        if (path.startsWith('/api/support/v1/articles/')) {
          return json(
            '{"article":{"slug":"refunds","title":"Refunds","summary":"How refunds work","category":"Billing","url":"https://help.example.com/refunds","status":"published","updatedAt":"2026-10-15T09:00:00Z","body":"Hello **there**. [Evil](javascript:alert(1)) and [Safe](https://ok.example)."}}',
          );
        }
        return json('{"conversations":[]}');
      }),
      apiKey: () => 'key',
      read: (_) async => null,
      write: (_, _) async {},
      profile: () async => {},
    );

    testWidgets('the help section is hidden without articles', (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: AppReferSupportView(api: api(withArticles: false))),
      );
      await tester.pumpAndSettle();
      expect(find.text('HELP ARTICLES'), findsNothing);
      expect(find.text('Search help articles'), findsNothing);
    });

    testWidgets('home section, help centre, article and Message us', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(home: AppReferSupportView(api: api(withArticles: true))),
      );
      await tester.pumpAndSettle();
      expect(find.text('HELP ARTICLES'), findsOneWidget);
      expect(find.text('Refunds'), findsOneWidget);
      expect(
        find.text('DRAFT'),
        findsOneWidget,
        reason: 'test keys preview drafts',
      );

      // Search opens the help centre with every article grouped.
      await tester.tap(find.text('Search help articles'));
      await tester.pumpAndSettle();
      expect(find.text('BILLING'), findsOneWidget);
      expect(find.text('MORE ARTICLES'), findsOneWidget);
      expect(find.text('Still need help?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'refund');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Coming soon'), findsNothing);

      // The article: markdown rendered, unsafe link left as text.
      await tester.tap(find.text('Refunds').first);
      await tester.pumpAndSettle();
      expect(find.text('Refunds'), findsWidgets);
      expect(
        find.textContaining('Hello there.', findRichText: true),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Open in browser'), findsOneWidget);

      // Back to the help centre, then Message us from an article starts a topic.
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Still need help?'), findsOneWidget);
      await tester.tap(find.text('Refunds').first);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Message us'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Message us'));
      await tester.pumpAndSettle();
      expect(
        find.text('Refunds'),
        findsWidgets,
        reason: 'the topic chip on the home',
      );
      expect(find.text('What do you still need help with?'), findsOneWidget);
    });

    testWidgets('opens straight to an article; Back goes home', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppReferSupportView(
            api: api(withArticles: true),
            opening: const AppReferSupportDestination.article('refunds'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Hello there.', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.bySemanticsLabel('Back'));
      await tester.pumpAndSettle();
      expect(find.text('HELP ARTICLES'), findsOneWidget);
    });

    testWidgets('only safe links get a tap target', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppReferSupportView(
            api: api(withArticles: true),
            opening: const AppReferSupportDestination.article('refunds'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rich = tester
          .widgetList<RichText>(find.byType(RichText))
          .firstWhere((t) => t.text.toPlainText().contains('Hello there.'));
      final linked = <String>[];
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.recognizer != null)
          linked.add(span.text ?? '');
        return true;
      });
      expect(linked, ['Safe'], reason: 'javascript: is plain text');
    });
  });
}
