import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'support_api.dart';
import 'support_strings.dart';

// MARK: - Help centre models

/// A help article as listed in the help centre (no body).
@immutable
class AppReferHelpArticle {
  const AppReferHelpArticle({
    required this.slug,
    required this.title,
    this.summary = '',
    this.category,
    this.url,
    this.updatedAt = '',
    this.status = 'published',
    this.locale,
  });

  final String slug, title;

  /// The article's summary, or the start of its text.
  final String summary;
  final String? category;

  /// The article's web page, if it has one.
  final String? url;

  /// ISO 8601.
  final String updatedAt;

  /// "published" or, for test SDK keys only, "draft".
  final String? status;

  /// The translation the server picked (e.g. "de"), null for the default language.
  final String? locale;

  bool get isDraft => status == 'draft';
  DateTime? get updatedDate => DateTime.tryParse(updatedAt)?.toLocal();

  /// [url] when it is an http(s) link.
  String? get webUrl {
    final safe = SupportMarkdown.safeUrl(url);
    return safe == null || safe.toLowerCase().startsWith('mailto:')
        ? null
        : safe;
  }

  static AppReferHelpArticle? fromJson(Object? json) {
    if (json is! Map) return null;
    final slug = json['slug'];
    if (slug is! String) return null;
    String? str(String key) => json[key] is String ? json[key] as String : null;
    final category = str('category');
    return AppReferHelpArticle(
      slug: slug,
      title: str('title') ?? slug,
      summary: str('summary') ?? '',
      category: category == null || category.isEmpty ? null : category,
      url: str('url'),
      updatedAt: str('updatedAt') ?? '',
      status: str('status'),
      locale: str('locale'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppReferHelpArticle &&
      other.slug == slug &&
      other.title == title &&
      other.summary == summary &&
      other.category == category &&
      other.url == url &&
      other.updatedAt == updatedAt &&
      other.status == status &&
      other.locale == locale;
  @override
  int get hashCode => Object.hash(
    slug,
    title,
    summary,
    category,
    url,
    updatedAt,
    status,
    locale,
  );
}

/// One help article with its markdown body.
@immutable
class AppReferHelpArticleDetail {
  const AppReferHelpArticleDetail({required this.article, required this.body});
  final AppReferHelpArticle article;

  /// Markdown. The built-in reader renders headings, lists, links, emphasis,
  /// code and images; HTML is never run and only http(s) and mailto links are
  /// kept.
  final String body;

  String get slug => article.slug;
  String get title => article.title;
  String get summary => article.summary;
  String? get category => article.category;
  String? get url => article.url;
  String get updatedAt => article.updatedAt;
  bool get isDraft => article.isDraft;
}

/// One push channel's readiness.
@immutable
class AppReferSupportPushChannel {
  const AppReferSupportPushChannel({
    required this.configured,
    required this.verified,
    this.checkedAt,
    this.error,
    this.environments,
  });
  final bool configured;

  /// true: the store accepted the credentials; false: it rejected them (see
  /// [error]); null: not checked yet or the store was unreachable.
  final bool? verified;
  final String? checkedAt, error;

  /// iOS only: which APNs environments accepted the key (production, sandbox).
  final Map<String, bool?>? environments;

  static AppReferSupportPushChannel fromJson(Object? json) {
    if (json is! Map) {
      return const AppReferSupportPushChannel(
        configured: false,
        verified: null,
      );
    }
    final env = json['environments'];
    return AppReferSupportPushChannel(
      configured: json['configured'] == true,
      verified: json['verified'] is bool ? json['verified'] as bool : null,
      checkedAt: json['checkedAt'] is String
          ? json['checkedAt'] as String
          : null,
      error: json['error'] is String ? json['error'] as String : null,
      environments: env is Map
          ? {
              for (final e in env.entries)
                '${e.key}': e.value is bool ? e.value as bool : null,
            }
          : null,
    );
  }
}

/// What AppRefer Support can do for this app right now
/// (`AppReferSDK.support.status()`).
@immutable
class AppReferSupportStatus {
  const AppReferSupportStatus({
    required this.ios,
    required this.android,
    required this.emailConfigured,
    this.emailVerified,
    required this.emailReceivesReplies,
    required this.helpCentreArticles,
    this.isIOS = false,
  });
  final AppReferSupportPushChannel ios, android;

  /// Replies can be emailed to customers who gave an email address.
  final bool emailConfigured;
  final bool? emailVerified;

  /// Customers can answer those emails and their answer lands in the conversation.
  final bool emailReceivesReplies;

  /// Published help articles (drafts not counted).
  final int helpCentreArticles;

  /// The platform [pushReady] answers for.
  final bool isIOS;

  /// Register push tokens only when this is true: push is configured for this
  /// platform and the store accepted the credentials (`verified == true`).
  bool get pushReady {
    final channel = isIOS ? ios : android;
    // Dart cannot infer the signed APNs environment; fail closed if either
    // environment was explicitly rejected.
    return channel.configured &&
        channel.verified == true &&
        (!isIOS ||
            (ios.environments?['production'] != false &&
                ios.environments?['sandbox'] != false));
  }

  /// Customers can answer reply emails and their answer reaches the conversation.
  bool get emailReplies => emailReceivesReplies;

  static AppReferSupportStatus fromJson(Object? json, {required bool isIOS}) {
    final m = json is Map ? json : const {};
    final push = m['push'] is Map ? m['push'] as Map : const {};
    final email = m['email'] is Map ? m['email'] as Map : const {};
    final help = m['helpCentre'] is Map ? m['helpCentre'] as Map : const {};
    return AppReferSupportStatus(
      ios: AppReferSupportPushChannel.fromJson(push['ios']),
      android: AppReferSupportPushChannel.fromJson(push['android']),
      emailConfigured: email['configured'] == true,
      emailVerified: email['verified'] is bool
          ? email['verified'] as bool
          : null,
      emailReceivesReplies: email['receivesReplies'] == true,
      helpCentreArticles: help['publishedArticles'] is num
          ? (help['publishedArticles'] as num).toInt()
          : 0,
      isIOS: isIOS,
    );
  }
}

// MARK: - Requests

class _Cached<T> {
  _Cached(this.value, this.expiresAt);
  final T value;
  final DateTime expiresAt;
}

/// The help centre and status requests: SDK key only, no support session.
/// Lists and articles are kept in memory for five minutes; when a request
/// fails, the last copy for the same key, language and query is used whatever
/// its age, and only without one is the error thrown. The status is kept as
/// long as the server's Cache-Control `max-age` allows (5 minutes once every
/// configured channel is verified, else 30 s).
class SupportHelpClient {
  SupportHelpClient({
    required this.client,
    required this.apiKey,
    this.baseUrl = 'https://apprefer.com',
    DateTime Function()? now,
    this.isIOS = false,
  }) : now = now ?? DateTime.now;

  /// The current HTTP client (Support swaps it on reset).
  final http.Client Function() client;
  final String? Function() apiKey;
  final String baseUrl;
  final DateTime Function() now;
  final bool isIOS;

  static const cacheDuration = Duration(minutes: 5);

  /// Search terms longer than this are cut (the server refuses longer ones).
  static const maxQueryLength = 200;

  final _lists = <String, _Cached<List<AppReferHelpArticle>>>{};
  final _articles = <String, _Cached<AppReferHelpArticleDetail>>{};
  final _statuses = <String, _Cached<AppReferSupportStatus>>{};

  String _key(List<String> parts) => [apiKey() ?? '', ...parts].join('|');

  static String? normalizedQuery(String? query) {
    final trimmed = (query ?? '').trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length > maxQueryLength
        ? trimmed.substring(0, maxQueryLength)
        : trimmed;
  }

  Future<http.Response> _get(
    String path, {
    Map<String, String> query = const {},
    String? language,
  }) async {
    final key = apiKey();
    if (key == null) {
      throw SupportException(
        0,
        'Configure AppRefer before opening support.',
        reason: SupportErrorReason.unavailable,
      );
    }
    final encoded = query.entries
        .map((e) => '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final request = http.Request(
      'GET',
      Uri.parse('$baseUrl$path${encoded.isEmpty ? '' : '?$encoded'}'),
    );
    request.headers['X-AppRefer-Key'] = key;
    if (language != null) request.headers['Accept-Language'] = language;
    final response = await http.Response.fromStream(
      await client().send(request).timeout(const Duration(seconds: 15)),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      Object? data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {}
      final error = data is Map ? data['error'] : null;
      throw SupportException(
        response.statusCode,
        '${error ?? 'Something went wrong (${response.statusCode})'}',
      );
    }
    return response;
  }

  static Map<String, dynamic> _json(http.Response response) {
    try {
      final data = jsonDecode(response.body);
      return data is Map<String, dynamic> ? data : {};
    } catch (_) {
      return {};
    }
  }

  void _trim<T>(Map<String, _Cached<T>> cache) {
    if (cache.length <= 40) return;
    final at = now();
    cache.removeWhere((_, v) => !v.expiresAt.isAfter(at));
  }

  /// Published articles in [language] (the chat's language), best first; with
  /// [query], the server's search results.
  Future<List<AppReferHelpArticle>> list(String? query, String language) async {
    final q = normalizedQuery(query);
    final k = _key(['list', language, q ?? '']);
    final hit = _lists[k];
    if (hit != null && hit.expiresAt.isAfter(now())) return hit.value;
    try {
      final response = await _get(
        '/api/support/v1/articles',
        query: {'locale': language, if (q != null) 'q': q},
        language: language,
      );
      final raw = _json(response)['articles'];
      final result = [
        for (final item in raw is List ? raw : const [])
          if (AppReferHelpArticle.fromJson(item) case final article?) article,
      ];
      _trim(_lists);
      _lists[k] = _Cached(result, now().add(cacheDuration));
      return result;
    } catch (_) {
      final stale = _lists[k];
      if (stale != null) return stale.value;
      rethrow;
    }
  }

  /// The last article list for [language] (no query), whatever its age.
  List<AppReferHelpArticle>? cachedList(String language) =>
      _lists[_key(['list', language, ''])]?.value;

  /// One article. Throws [SupportException] with status 404 when it doesn't
  /// exist or isn't published.
  Future<AppReferHelpArticleDetail> article(
    String slug,
    String language,
  ) async {
    final k = _key(['article', language, slug]);
    final hit = _articles[k];
    if (hit != null && hit.expiresAt.isAfter(now())) return hit.value;
    try {
      final response = await _get(
        '/api/support/v1/articles/${Uri.encodeComponent(slug)}',
        query: {'locale': language},
        language: language,
      );
      final raw = _json(response)['article'];
      final article = AppReferHelpArticle.fromJson(raw);
      if (article == null) {
        throw SupportException(response.statusCode, 'Unreadable article');
      }
      final body = raw is Map && raw['body'] is String
          ? raw['body'] as String
          : '';
      final detail = AppReferHelpArticleDetail(article: article, body: body);
      _trim(_articles);
      _articles[k] = _Cached(detail, now().add(cacheDuration));
      return detail;
    } on SupportException catch (e) {
      if (e.status == 404) {
        _articles.remove(k);
        rethrow;
      }
      final stale = _articles[k];
      if (stale != null) return stale.value;
      rethrow;
    } catch (_) {
      final stale = _articles[k];
      if (stale != null) return stale.value;
      rethrow;
    }
  }

  /// Support readiness for this app, kept as long as the server's
  /// Cache-Control allows.
  Future<AppReferSupportStatus> status() async {
    final k = apiKey() ?? '';
    final hit = _statuses[k];
    if (hit != null && hit.expiresAt.isAfter(now())) return hit.value;
    final response = await _get('/api/support/v1/status');
    final status = AppReferSupportStatus.fromJson(
      _json(response),
      isIOS: isIOS,
    );
    final age = maxAgeSeconds(response.headers['cache-control']) ?? 30;
    _statuses[k] = _Cached(status, now().add(Duration(seconds: age)));
    return status;
  }

  /// `max-age` from a Cache-Control header, capped at five minutes; null
  /// without one. `no-store` / `no-cache` mean zero.
  static int? maxAgeSeconds(String? header) {
    if (header == null) return null;
    int? age;
    for (final part in header.toLowerCase().split(',')) {
      final directive = part.trim();
      if (directive == 'no-store' || directive == 'no-cache') return 0;
      if (directive.startsWith('max-age=')) {
        final seconds = int.tryParse(directive.substring('max-age='.length));
        if (seconds != null)
          age = seconds < 0 ? 0 : (seconds > 300 ? 300 : seconds);
      }
    }
    return age;
  }

  /// Fills the list cache (tests and previews).
  @visibleForTesting
  void seed(String language, List<AppReferHelpArticle> articles) =>
      _lists[_key(['list', language, ''])] = _Cached(
        articles,
        now().add(cacheDuration),
      );
}

// MARK: - Markdown

/// Inline styles in a help article's text.
enum SupportInlineStyle { bold, italic, code, strike, link }

/// A styled range of [SupportRichText.text]; [url] is set for links (always http(s) or mailto).
@immutable
class SupportSpan {
  const SupportSpan(this.start, this.end, this.style, [this.url]);
  final int start, end;
  final SupportInlineStyle style;
  final String? url;
  @override
  bool operator ==(Object other) =>
      other is SupportSpan &&
      other.start == start &&
      other.end == end &&
      other.style == style &&
      other.url == url;
  @override
  int get hashCode => Object.hash(start, end, style, url);
  @override
  String toString() => 'SupportSpan($start, $end, $style, $url)';
}

/// Plain text plus style ranges; the view turns it into text spans.
@immutable
class SupportRichText {
  const SupportRichText(this.text, [this.spans = const []]);
  final String text;
  final List<SupportSpan> spans;
  List<String> get links => [
    for (final s in spans)
      if (s.url != null) s.url!,
  ];

  SupportRichText operator +(SupportRichText other) =>
      SupportRichText(text + other.text, [
        ...spans,
        for (final s in other.spans)
          SupportSpan(
            s.start + text.length,
            s.end + text.length,
            s.style,
            s.url,
          ),
      ]);

  @override
  bool operator ==(Object other) =>
      other is SupportRichText &&
      other.text == text &&
      listEquals(other.spans, spans);
  @override
  int get hashCode => Object.hash(text, Object.hashAll(spans));
  @override
  String toString() => 'SupportRichText("$text", $spans)';
}

/// A block of a help article.
@immutable
sealed class SupportMarkdownBlock {
  const SupportMarkdownBlock();
}

class SupportHeadingBlock extends SupportMarkdownBlock {
  const SupportHeadingBlock(this.level, this.text);
  final int level;
  final SupportRichText text;
  @override
  bool operator ==(Object other) =>
      other is SupportHeadingBlock &&
      other.level == level &&
      other.text == text;
  @override
  int get hashCode => Object.hash(level, text);
  @override
  String toString() => 'Heading($level, $text)';
}

class SupportParagraphBlock extends SupportMarkdownBlock {
  const SupportParagraphBlock(this.text);
  final SupportRichText text;
  @override
  bool operator ==(Object other) =>
      other is SupportParagraphBlock && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => 'Paragraph($text)';
}

/// One list item; [depth] 0 is the outer list. [number] is set for ordered lists.
class SupportListItemBlock extends SupportMarkdownBlock {
  const SupportListItemBlock(this.number, this.depth, this.text);
  final int? number;
  final int depth;
  final SupportRichText text;
  @override
  bool operator ==(Object other) =>
      other is SupportListItemBlock &&
      other.number == number &&
      other.depth == depth &&
      other.text == text;
  @override
  int get hashCode => Object.hash(number, depth, text);
  @override
  String toString() => 'ListItem($number, $depth, $text)';
}

class SupportQuoteBlock extends SupportMarkdownBlock {
  const SupportQuoteBlock(this.text);
  final SupportRichText text;
  @override
  bool operator ==(Object other) =>
      other is SupportQuoteBlock && other.text == text;
  @override
  int get hashCode => text.hashCode;
  @override
  String toString() => 'Quote($text)';
}

class SupportCodeBlock extends SupportMarkdownBlock {
  const SupportCodeBlock(this.code);
  final String code;
  @override
  bool operator ==(Object other) =>
      other is SupportCodeBlock && other.code == code;
  @override
  int get hashCode => code.hashCode;
  @override
  String toString() => 'Code($code)';
}

class SupportRuleBlock extends SupportMarkdownBlock {
  const SupportRuleBlock();
  @override
  bool operator ==(Object other) => other is SupportRuleBlock;
  @override
  int get hashCode => 7;
  @override
  String toString() => 'Rule';
}

/// A picture on its own line (http/https only).
class SupportImageBlock extends SupportMarkdownBlock {
  const SupportImageBlock(this.url, this.alt);
  final String url, alt;
  @override
  bool operator ==(Object other) =>
      other is SupportImageBlock && other.url == url && other.alt == alt;
  @override
  int get hashCode => Object.hash(url, alt);
  @override
  String toString() => 'Image($url, $alt)';
}

/// A small, safe markdown reader for help articles (same rules as the iOS and
/// Android SDKs): headings, lists, quotes, fenced code, rules, images, and
/// inline bold, italic, code, strikethrough and links. Nothing is ever
/// executed: HTML tags are dropped (script and style with their content), and
/// links keep only http(s) and mailto targets; everything else (javascript:,
/// data:, file:, relative paths, app schemes) becomes plain text.
abstract final class SupportMarkdown {
  static List<SupportMarkdownBlock> blocks(String markdown) {
    final lines = markdown
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');
    final blocks = <SupportMarkdownBlock>[];
    final paragraph = <String>[];
    final quote = <String>[];
    var listOpen = false;
    var index = 0;

    void flushParagraph() {
      if (paragraph.isEmpty) return;
      blocks.add(SupportParagraphBlock(inline(_joinLines(paragraph))));
      paragraph.clear();
    }

    void flushQuote() {
      if (quote.isEmpty) return;
      blocks.add(SupportQuoteBlock(inline(_joinLines(quote))));
      quote.clear();
    }

    void flushAll() {
      flushParagraph();
      flushQuote();
      listOpen = false;
    }

    while (index < lines.length) {
      final line = lines[index];
      final trimmed = _trimSpaces(line);
      index++;

      // Fenced code: everything up to the closing fence, as written.
      if (trimmed.startsWith('```') || trimmed.startsWith('~~~')) {
        flushAll();
        final fence = trimmed.substring(0, 3);
        final code = <String>[];
        while (index < lines.length &&
            !_trimSpaces(lines[index]).startsWith(fence)) {
          code.add(lines[index]);
          index++;
        }
        index++; // the closing fence
        blocks.add(SupportCodeBlock(code.join('\n')));
        continue;
      }
      if (trimmed.isEmpty) {
        flushAll();
        continue;
      }

      // Setext headings: a paragraph line underlined with === or ---.
      if (paragraph.isNotEmpty &&
          trimmed.length >= 2 &&
          (_all(trimmed, '=') || _all(trimmed, '-'))) {
        final text = _joinLines(paragraph);
        paragraph.clear();
        blocks.add(
          SupportHeadingBlock(trimmed[0] == '=' ? 1 : 2, inline(text)),
        );
        continue;
      }
      if (_isRule(trimmed)) {
        flushAll();
        blocks.add(const SupportRuleBlock());
        continue;
      }
      final heading = _atxHeading(trimmed);
      if (heading != null) {
        flushAll();
        blocks.add(SupportHeadingBlock(heading.$1, inline(heading.$2)));
        continue;
      }
      if (trimmed.startsWith('>')) {
        flushParagraph();
        listOpen = false;
        quote.add(_trimSpaces(trimmed.substring(1)));
        continue;
      }
      flushQuote();
      final item = _listItem(line);
      if (item != null) {
        flushParagraph();
        listOpen = true;
        blocks.add(SupportListItemBlock(item.$1, item.$2, inline(item.$3)));
        continue;
      }
      // An indented line right after a list item continues that item.
      final last = blocks.isEmpty ? null : blocks.last;
      if (listOpen &&
          (line.startsWith(' ') || line.startsWith('\t')) &&
          last is SupportListItemBlock) {
        blocks[blocks.length - 1] = SupportListItemBlock(
          last.number,
          last.depth,
          last.text + const SupportRichText(' ') + inline(trimmed),
        );
        continue;
      }
      listOpen = false;
      if (paragraph.isEmpty) {
        final image = _standaloneImage(trimmed);
        if (image != null) {
          if (!(image is SupportParagraphBlock && image.text.text.isEmpty))
            blocks.add(image);
          continue;
        }
      }
      paragraph.add(line);
    }
    flushAll();
    return blocks;
  }

  // MARK: Inline

  /// Inline markdown with only safe links kept and HTML tags removed.
  static SupportRichText inline(String text) {
    final out = StringBuffer();
    final spans = <SupportSpan>[];
    _parseInline(stripHTML(text), out, spans, 0);
    spans.sort(
      (a, b) => a.start != b.start
          ? a.start.compareTo(b.start)
          : b.end.compareTo(a.end),
    );
    return SupportRichText(out.toString(), List.unmodifiable(spans));
  }

  /// The URL when it is an http(s) link with a host, or a mailto link; null otherwise.
  static String? safeUrl(String? string) {
    final trimmed = string?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    if (trimmed.codeUnits.any((c) => c < 0x20 || c == 0x7f) ||
        _whitespace.hasMatch(trimmed))
      return null;
    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;
    switch (uri.scheme.toLowerCase()) {
      case 'http':
      case 'https':
        return uri.hasAuthority && uri.host.isNotEmpty ? trimmed : null;
      case 'mailto':
        return trimmed.length > 'mailto:'.length ? trimmed : null;
      default:
        return null;
    }
  }

  /// Removes HTML tags (and script/style elements with their content) outside
  /// `code` spans. Autolinks such as `<https://…>` are kept.
  static String stripHTML(String text) {
    if (!text.contains('<')) return text;
    final parts = text.split('`');
    for (var i = 0; i < parts.length; i += 2) {
      var s = parts[i];
      if (!s.contains('<')) continue;
      s = s.replaceAll(_scriptClosed, '');
      s = s.replaceAll(_scriptOpen, '');
      s = s.replaceAll(_break, '\n');
      s = s.replaceAll(_comment, '');
      parts[i] = s.replaceAll(_tag, '');
    }
    return parts.join('`');
  }

  static final _scriptClosed = RegExp(
    r'<(script|style)\b[^>]*>[\s\S]*?</\1\s*>',
    caseSensitive: false,
  );
  static final _scriptOpen = RegExp(
    r'<(script|style)\b[^>]*>[\s\S]*$',
    caseSensitive: false,
  );
  static final _break = RegExp(r'<br\s*/?>', caseSensitive: false);
  static final _comment = RegExp(r'<!--[\s\S]*?-->');
  static final _tag = RegExp(r'</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>');
  static final _autolink = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]{1,31}:[^\s<>]*$');
  static final _email = RegExp(r'^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$');
  static final _whitespace = RegExp(r'\s');
  static final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);
  static const _punctuation = r'''!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~''';

  static bool _isSpace(String ch) => _whitespace.hasMatch(ch);
  static bool _isWord(String ch) => _wordChar.hasMatch(ch);

  static void _parseInline(
    String s,
    StringBuffer out,
    List<SupportSpan> spans,
    int depth,
  ) {
    var i = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == r'\' && i + 1 < s.length && _punctuation.contains(s[i + 1])) {
        out.write(s[i + 1]);
        i += 2;
      } else if (c == '`') {
        final run = _runLength(s, i, '`');
        final close = _findCodeClose(s, i + run, run);
        if (close < 0) {
          out.write(s.substring(i, i + run));
          i += run;
        } else {
          var code = s.substring(i + run, close);
          if (code.length >= 2 &&
              code.startsWith(' ') &&
              code.endsWith(' ') &&
              code.trim().isNotEmpty) {
            code = code.substring(1, code.length - 1);
          }
          final start = out.length;
          out.write(code);
          spans.add(SupportSpan(start, out.length, SupportInlineStyle.code));
          i = close + run;
        }
      } else if (c == '!' && i + 1 < s.length && s[i + 1] == '[' && depth < 8) {
        final link = _link(s, i + 1);
        if (link == null) {
          out.write(c);
          i++;
        } else {
          // An inline picture shows its alt text.
          _parseInline(link.$1, out, spans, depth + 1);
          i = link.$3;
        }
      } else if (c == '[' && depth < 8) {
        final link = _link(s, i);
        if (link == null) {
          out.write(c);
          i++;
        } else {
          final start = out.length;
          _parseInline(link.$1, out, spans, depth + 1);
          final url = safeUrl(link.$2);
          if (url != null && out.length > start) {
            spans.add(
              SupportSpan(start, out.length, SupportInlineStyle.link, url),
            );
          }
          i = link.$3;
        }
      } else if (c == '<') {
        final close = s.indexOf('>', i + 1);
        final inner = close > i ? s.substring(i + 1, close) : '';
        final target = _autolink.hasMatch(inner)
            ? inner
            : _email.hasMatch(inner)
            ? 'mailto:$inner'
            : null;
        if (target == null) {
          out.write(c);
          i++;
        } else {
          final start = out.length;
          out.write(inner);
          final url = safeUrl(target);
          if (url != null)
            spans.add(
              SupportSpan(start, out.length, SupportInlineStyle.link, url),
            );
          i = close + 1;
        }
      } else if ((c == '*' || c == '_' || c == '~') && depth < 8) {
        final run = _runLength(s, i, c);
        final width = c == '~' ? (run >= 2 ? 2 : 0) : (run >= 2 ? 2 : 1);
        final close = width == 0 ? -1 : _findDelimiterClose(s, i, c, width);
        if (close < 0) {
          out.write(s.substring(i, i + run));
          i += run;
        } else {
          final start = out.length;
          _parseInline(s.substring(i + width, close), out, spans, depth + 1);
          final style = c == '~'
              ? SupportInlineStyle.strike
              : width == 2
              ? SupportInlineStyle.bold
              : SupportInlineStyle.italic;
          if (out.length > start)
            spans.add(SupportSpan(start, out.length, style));
          i = close + width;
        }
      } else {
        out.write(c);
        i++;
      }
    }
  }

  static int _runLength(String s, int from, String c) {
    var n = 0;
    while (from + n < s.length && s[from + n] == c) {
      n++;
    }
    return n;
  }

  /// The start of the next run of exactly [run] backticks, or -1.
  static int _findCodeClose(String s, int from, int run) {
    var j = from;
    while (j < s.length) {
      if (s[j] == '`') {
        final n = _runLength(s, j, '`');
        if (n == run) return j;
        j += n;
      } else {
        j++;
      }
    }
    return -1;
  }

  /// The closing delimiter for an opening run of [width] × [c] at [open], or
  /// -1. The opening must be followed by a non-space and the closing preceded
  /// by one; `_` only opens and closes at word edges.
  static int _findDelimiterClose(String s, int open, String c, int width) {
    final first = open + width;
    if (first >= s.length || _isSpace(s[first])) return -1;
    if (c == '_' && open > 0 && _isWord(s[open - 1])) return -1;
    var j = first;
    while (j < s.length) {
      final ch = s[j];
      if (ch == r'\') {
        j += 2;
      } else if (ch == '`') {
        final n = _runLength(s, j, '`');
        final close = _findCodeClose(s, j + n, n);
        j = close < 0 ? j + n : close + n;
      } else if (ch == c) {
        final n = _runLength(s, j, c);
        final fits = width == 1 ? (n == 1 || n >= 3) : n >= 2;
        final after = j + width;
        final wordEdge = c != '_' || after >= s.length || !_isWord(s[after]);
        if (fits && j > first && !_isSpace(s[j - 1]) && wordEdge) return j;
        j += n;
      } else {
        j++;
      }
    }
    return -1;
  }

  /// `[label](destination "title")` starting at [open] ('['): label,
  /// destination and the index after it.
  static (String, String, int)? _link(String s, int open) {
    var depth = 0;
    var j = open;
    var labelEnd = -1;
    while (j < s.length) {
      final ch = s[j];
      if (ch == r'\') {
        j++;
      } else if (ch == '[') {
        depth++;
      } else if (ch == ']') {
        depth--;
        if (depth == 0) {
          labelEnd = j;
          break;
        }
      }
      j++;
    }
    if (labelEnd < 0 || labelEnd + 1 >= s.length || s[labelEnd + 1] != '(')
      return null;
    var parens = 0;
    var k = labelEnd + 1;
    var destEnd = -1;
    while (k < s.length) {
      final ch = s[k];
      if (ch == r'\') {
        k++;
      } else if (ch == '(') {
        parens++;
      } else if (ch == ')') {
        parens--;
        if (parens == 0) {
          destEnd = k;
          break;
        }
      }
      k++;
    }
    if (destEnd < 0) return null;
    var destination = s.substring(labelEnd + 2, destEnd).trim();
    if (destination.startsWith('<')) {
      final close = destination.indexOf('>');
      destination = close > 0
          ? destination.substring(1, close)
          : destination.substring(1);
    } else {
      final space = destination.indexOf(_whitespace);
      if (space >= 0) destination = destination.substring(0, space);
    }
    return (s.substring(open + 1, labelEnd), destination, destEnd + 1);
  }

  // MARK: Block helpers

  static String _trimSpaces(String s) {
    var start = 0, end = s.length;
    while (start < end && (s[start] == ' ' || s[start] == '\t')) {
      start++;
    }
    while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t')) {
      end--;
    }
    return s.substring(start, end);
  }

  static bool _all(String s, String c) => s.split('').every((ch) => ch == c);

  /// Lines of one paragraph: a soft break is a space; two trailing spaces or a
  /// backslash make a line break.
  static String _joinLines(List<String> lines) {
    final out = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final hard = raw.endsWith('  ') || raw.endsWith(r'\');
      var line = _trimSpaces(raw);
      if (line.endsWith(r'\')) line = line.substring(0, line.length - 1);
      out.write(line);
      if (i < lines.length - 1) out.write(hard ? '\n' : ' ');
    }
    return out.toString();
  }

  static bool _isRule(String s) {
    final compact = s.replaceAll(' ', '');
    if (compact.length < 3 || !'-*_'.contains(compact[0])) return false;
    return _all(compact, compact[0]);
  }

  static (int, String)? _atxHeading(String s) {
    var hashes = 0;
    while (hashes < s.length && s[hashes] == '#') {
      hashes++;
    }
    if (hashes < 1 || hashes > 6) return null;
    final rest = s.substring(hashes);
    if (rest.isNotEmpty && rest[0] != ' ' && rest[0] != '\t') return null;
    var text = _trimSpaces(rest);
    // Closing hashes ("## Title ##").
    while (text.endsWith('#')) {
      text = text.substring(0, text.length - 1);
    }
    return (hashes, _trimSpaces(text));
  }

  static (int?, int, String)? _listItem(String line) {
    final expanded = line.replaceAll('\t', '    ');
    var indent = 0;
    while (indent < expanded.length && expanded[indent] == ' ') {
      indent++;
    }
    final rest = expanded.substring(indent);
    final depth = indent ~/ 2 > 3 ? 3 : indent ~/ 2;
    if (rest.length >= 2 && '-*+'.contains(rest[0]) && rest[1] == ' ') {
      final text = _trimSpaces(rest.substring(2));
      // "- [ ] task" / "- [x] task": shown as a plain item with a box.
      if (text.startsWith('[ ] '))
        return (null, depth, '☐ ${text.substring(4)}');
      if (text.toLowerCase().startsWith('[x] '))
        return (null, depth, '☑︎ ${text.substring(4)}');
      return (null, depth, text);
    }
    var digits = 0;
    while (digits < rest.length && '0123456789'.contains(rest[digits])) {
      digits++;
    }
    if (digits == 0 || digits > 9) return null;
    final after = rest.substring(digits);
    if (after.length < 2 ||
        (after[0] != '.' && after[0] != ')') ||
        after[1] != ' ')
      return null;
    return (
      int.parse(rest.substring(0, digits)),
      depth,
      _trimSpaces(after.substring(2)),
    );
  }

  /// `![alt](url "title")` alone on a line; an unsafe one becomes its alt text.
  static SupportMarkdownBlock? _standaloneImage(String s) {
    if (!s.startsWith('![') || !s.endsWith(')')) return null;
    final close = s.indexOf('](');
    if (close < 0) return null;
    final alt = s.substring(2, close);
    var target = s.substring(close + 2, s.length - 1).trim();
    final space = target.indexOf(' ');
    if (space >= 0) target = target.substring(0, space);
    while (target.startsWith('<') || target.startsWith('>')) {
      target = target.substring(1);
    }
    while (target.endsWith('>') || target.endsWith('<')) {
      target = target.substring(0, target.length - 1);
    }
    final url = safeUrl(target);
    if (url == null || url.toLowerCase().startsWith('mailto:')) {
      return SupportParagraphBlock(SupportRichText(alt));
    }
    return SupportImageBlock(url, alt);
  }
}

// MARK: - UI logic

/// Articles whose title, summary or category contain every word of [query]
/// (case and common accents ignored).
List<AppReferHelpArticle> supportHelpLocalMatches(
  List<AppReferHelpArticle> articles,
  String query,
) {
  final words = query
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map(supportFold)
      .toList();
  return [
    for (final a in articles)
      if (words.every(
        supportFold('${a.title} ${a.summary} ${a.category ?? ''}').contains,
      ))
        a,
  ];
}

const _folds = {
  'a': 'àáâãäåāăą',
  'c': 'çćč',
  'd': 'ď',
  'e': 'èéêëēėęě',
  'i': 'ìíîïīįı',
  'n': 'ñńň',
  'o': 'òóôõöøōő',
  'r': 'ŕř',
  's': 'śšşß',
  't': 'ť',
  'u': 'ùúûüūůűų',
  'y': 'ýÿ',
  'z': 'žźż',
};
final _foldMap = {
  for (final e in _folds.entries)
    for (final ch in e.value.split('')) ch: e.key,
};

/// Lower case without common Latin diacritics (precomposed or combining), for
/// the local search.
String supportFold(String s) {
  final out = StringBuffer();
  for (final rune in s.toLowerCase().runes) {
    if (rune >= 0x300 && rune <= 0x36f) continue; // combining marks
    final ch = String.fromCharCode(rune);
    out.write(_foldMap[ch] ?? ch);
  }
  return out.toString();
}

/// Articles by category in the server's order; uncategorised ones last ("More
/// articles"), or with no heading at all when nothing has a category.
List<(String?, List<AppReferHelpArticle>)> supportHelpGroups(
  List<AppReferHelpArticle> articles,
) {
  final byCategory = <String, List<AppReferHelpArticle>>{};
  final loose = <AppReferHelpArticle>[];
  for (final article in articles) {
    final category = article.category?.trim();
    if (category == null || category.isEmpty) {
      loose.add(article);
    } else {
      byCategory.putIfAbsent(category, () => []).add(article);
    }
  }
  return [
    for (final e in byCategory.entries) (e.key, e.value),
    if (loose.isNotEmpty)
      (
        byCategory.isEmpty
            ? null
            : SupportStrings.text('support.help.otherCategory'),
        loose,
      ),
  ];
}

/// What the line under the customer's last message promises about the reply.
enum SupportReplyNotice {
  /// "we'll notify you" (also when the status is unknown, as before 0.10.0).
  push,
  email,

  /// Neither push nor email can reach them: the reply shows in the chat.
  inApp;

  static SupportReplyNotice choose(
    AppReferSupportStatus? status, {
    required bool hasPushToken,
    required bool hasEmail,
  }) {
    if (status == null) return push;
    if (status.pushReady && hasPushToken) return push;
    if (status.emailConfigured && hasEmail) return email;
    return inApp;
  }

  String text(String? time) {
    final hasTime = time != null && time.isNotEmpty;
    final key = switch (this) {
      push =>
        hasTime
            ? 'support.thread.sentNotice'
            : 'support.thread.sentNoticeNoTime',
      email =>
        hasTime
            ? 'support.status.sentNoticeEmail'
            : 'support.status.sentNoticeEmailNoTime',
      inApp =>
        hasTime
            ? 'support.status.sentNoticeInApp'
            : 'support.status.sentNoticeInAppNoTime',
    };
    return SupportStrings.text(key, hasTime ? {'time': time} : const {});
  }
}
