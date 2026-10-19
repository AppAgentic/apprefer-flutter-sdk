import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:apprefer/src/support/support_strings.dart';
import 'package:apprefer/src/support/support_strings_table.g.dart';
import 'package:apprefer/src/support/support_style.dart';
import 'package:flutter/cupertino.dart'
    show CupertinoLocalizations, DefaultCupertinoLocalizations;
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Set<String> placeholders(String text) => {
  for (final m in RegExp(r'\{(\w+)\}').allMatches(text)) m.group(1)!,
};

/// Plural keys in the English table, without their `#category`.
Set<String> get pluralKeys => {
  for (final key in SupportStrings.table('en').keys)
    if (key.contains('#')) key.split('#').first,
};

void main() {
  tearDown(() {
    SupportStrings.overrides = {};
    SupportStrings.forcedLanguage = null;
    SupportStrings.appLocales = null;
    SupportStrings.deviceLocales = () => const [Locale('en', 'US')];
  });
  setUp(() => SupportStrings.deviceLocales = () => const [Locale('en', 'US')]);

  group('catalogue', () {
    test('35 languages; English has the whole key set', () {
      expect(SupportStrings.supportedLanguages, hasLength(35));
      expect(supportStringsTable.keys.toSet(), {
        ...SupportStrings.supportedLanguages,
      });
      final english = SupportStrings.table('en');
      expect(english.length, greaterThanOrEqualTo(78));
      for (final key in [
        'support.home.subtitle',
        'support.ai.tag',
        'support.a11y.unread#one',
        'support.a11y.unread#other',
        'support.error.offline',
      ]) {
        expect(english[key], isNotNull, reason: key);
      }
    });

    test('the generated table matches Localization/support-strings.json', () {
      final json =
          jsonDecode(
                File('Localization/support-strings.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final keys = json['keys'] as Map<String, dynamic>;
      final translations = json['translations'] as Map<String, dynamic>;
      // 78 chat keys + 22 help centre / status keys (0.10.0) + 7 lifecycle notification keys (0.11.0)
      // + 15 offer card keys (0.12.0).
      expect(keys, hasLength(122));
      Map<String, String> flatten(String lang) {
        final out = <String, String>{};
        for (final key in keys.keys) {
          final value = lang == 'en'
              ? keys[key]['en']
              : (translations[lang] as Map)[key];
          if (value is Map) {
            value.forEach((form, text) => out['$key#$form'] = text as String);
          } else {
            out[key] = value as String;
          }
        }
        return out;
      }

      expect(
        {...json['languages'] as List},
        {...SupportStrings.supportedLanguages},
      );
      for (final lang in SupportStrings.supportedLanguages) {
        expect(
          SupportStrings.table(lang),
          flatten(lang),
          reason: '$lang: rerun dart run tool/generate_support_strings.dart',
        );
      }
    });

    test('every key is translated in every language with its placeholders', () {
      final english = SupportStrings.table('en');
      final singular = {
        for (final e in english.entries)
          if (!e.key.contains('#')) e.key: e.value,
      };
      final plurals = pluralKeys;
      expect(plurals, {'support.a11y.unread'});
      final counts = [
        for (var i = 0; i <= 230; i++) i,
        1000,
        1001,
        1000000,
        2000000,
      ];
      for (final language in SupportStrings.supportedLanguages) {
        final table = SupportStrings.table(language);
        expect(table, isNotEmpty, reason: '$language has no table');
        singular.forEach((key, source) {
          final text = table[key];
          expect(text, isNotNull, reason: '$language: missing $key');
          expect(text!.trim(), isNotEmpty, reason: '$language: empty $key');
          expect(
            placeholders(text),
            placeholders(source),
            reason: '$language: placeholders of $key',
          );
        });
        for (final key in plurals) {
          final needed = {
            for (final n in counts) SupportStrings.pluralCategory(n, language),
          };
          for (final category in needed) {
            final text = table['$key#$category'];
            expect(
              text,
              isNotNull,
              reason: '$language: missing $key#$category',
            );
            expect(text!.trim(), isNotEmpty);
            expect(placeholders(text), {'count'});
          }
        }
        for (final key in table.keys) {
          final base = key.split('#').first;
          expect(
            singular.containsKey(key) || plurals.contains(base),
            isTrue,
            reason: '$language: unknown key $key',
          );
        }
      }
    });

    test('no translation names an AI provider', () {
      const banned = [
        'openai',
        'chatgpt',
        'gpt',
        'anthropic',
        'claude',
        'gemini',
        'llama',
        'qwen',
        'mistral',
      ];
      for (final language in SupportStrings.supportedLanguages) {
        SupportStrings.table(language).forEach((key, text) {
          final lower = text.toLowerCase();
          expect(
            banned.any(lower.contains),
            isFalse,
            reason: '$language: $key names a provider',
          );
        });
      }
    });
  });

  group('lookup', () {
    test('a forced language reads its table and fills placeholders', () {
      SupportStrings.forcedLanguage = 'de';
      expect(SupportStrings.language, 'de');
      expect(
        SupportStrings.text('support.home.subtitle'),
        SupportStrings.table('de')['support.home.subtitle'],
      );
      expect(
        SupportStrings.text('support.home.subtitle'),
        isNot('How can we help today?'),
      );
      final title = SupportStrings.text('support.home.title', {
        'app': 'Sparkly',
      });
      expect(title, contains('Sparkly'));
      expect(title, isNot(contains('{app}')));
      SupportStrings.forcedLanguage = 'pt-BR';
      expect(SupportStrings.language, 'pt-BR');
      expect(
        SupportStrings.text('support.ai.tag'),
        SupportStrings.table('pt-BR')['support.ai.tag'],
      );
      // The public API forwards to the same state.
      AppReferSupport.instance.language = 'ja';
      expect(SupportStrings.language, 'ja');
      AppReferSupport.instance.language = null;
      expect(SupportStrings.forcedLanguage, isNull);
    });

    test('an unknown language falls back to English', () {
      expect(
        SupportStrings.resolve(
          appLanguages: [],
          deviceLanguages: ['xx-YY', 'tlh'],
        ),
        'en',
      );
      SupportStrings.forcedLanguage = 'xx';
      expect(SupportStrings.language, 'en');
      expect(
        SupportStrings.text('support.home.subtitle'),
        'How can we help today?',
      );
      expect(
        SupportStrings.plural('support.a11y.unread', 1),
        '1 unread message',
      );
      expect(
        SupportStrings.plural('support.a11y.unread', 3),
        '3 unread messages',
      );
      // A key the table doesn't have shows the key, never an empty label.
      expect(SupportStrings.text('support.not.a.key'), 'support.not.a.key');
    });

    test('a missing translation falls back to English', () {
      expect(SupportStrings.bundled('support.home.subtitle', 'xx'), isNull);
      expect(SupportStrings.table('xx'), isEmpty);
      expect(
        SupportStrings.bundled('support.home.subtitle', 'en'),
        'How can we help today?',
      );
    });

    test('an override wins in every language', () {
      AppReferSupport.instance.strings = {
        'support.home.subtitle': "What's up, {name}?",
        'support.a11y.unread#one': 'One new reply',
        'support.thread.sending': '',
      };
      for (final language in ['en', 'de', 'ar', 'ja']) {
        SupportStrings.forcedLanguage = language;
        expect(
          SupportStrings.text('support.home.subtitle', {'name': 'Jay'}),
          "What's up, Jay?",
        );
        // A form override applies where the language uses that form
        // (Japanese has only "other").
        final expected = language == 'ja'
            ? SupportStrings.fill(
                SupportStrings.table('ja')['support.a11y.unread#other']!,
                {'count': '1'},
              )
            : 'One new reply';
        expect(SupportStrings.plural('support.a11y.unread', 1), expected);
      }
      SupportStrings.forcedLanguage = 'en';
      expect(
        SupportStrings.plural('support.a11y.unread', 2),
        '2 unread messages',
        reason: 'other forms keep the catalogue',
      );
      expect(
        SupportStrings.text('support.thread.sending'),
        '',
        reason: 'an override may blank a string',
      );
      // A plain key overrides every plural form.
      AppReferSupport.instance.strings = {'support.a11y.unread': '{count} new'};
      expect(SupportStrings.plural('support.a11y.unread', 5), '5 new');
      // The map can be edited in place, like iOS's dictionary.
      AppReferSupport.instance.strings['support.ai.tag'] = 'Bot';
      expect(SupportStrings.text('support.ai.tag'), 'Bot');
    });

    test('placeholders fill by name, in any order, once', () {
      expect(
        SupportStrings.fill('{time} · {name}', {'name': 'Jay', 'time': '1h'}),
        '1h · Jay',
      );
      expect(
        SupportStrings.fill('Hi {name} {unknown}', {'name': 'Jay'}),
        'Hi Jay {unknown}',
      );
      expect(
        SupportStrings.fill('Hi {name}', {'name': '{time}', 'time': 'x'}),
        'Hi {time}',
        reason: 'values are never expanded again',
      );
      expect(SupportStrings.fill('{ {name}}', {'name': 'a'}), '{ a}');
      expect(SupportStrings.fill('{name', {'name': 'a'}), '{name');
    });
  });

  group('language choice', () {
    test("the app's language wins, so the chat matches the app", () {
      // An English-only app on a German phone: the chat stays English.
      expect(
        SupportStrings.resolve(
          appLanguages: ['en'],
          deviceLanguages: ['de-DE', 'en'],
        ),
        'en',
      );
      expect(
        SupportStrings.resolve(
          appLanguages: ['de'],
          deviceLanguages: ['de-DE'],
        ),
        'de',
      );
      // No app locale yet: the device's order.
      expect(
        SupportStrings.resolve(
          appLanguages: [],
          deviceLanguages: ['fr-CA', 'en'],
        ),
        'fr',
      );
      // An app language the SDK doesn't ship falls through to the device.
      expect(
        SupportStrings.resolve(
          appLanguages: ['fil'],
          deviceLanguages: ['tl', 'it-IT'],
        ),
        'it',
      );
      // The same through the live state.
      SupportStrings.appLocales = const [Locale('en', 'US')];
      SupportStrings.deviceLocales = () => const [Locale('de', 'DE')];
      expect(SupportStrings.language, 'en');
      SupportStrings.appLocales = null;
      expect(SupportStrings.language, 'de');
      SupportStrings.appLocales = const [
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ];
      expect(SupportStrings.language, 'zh-Hant');
      SupportStrings.forcedLanguage = 'ru';
      expect(SupportStrings.language, 'ru', reason: 'forcing beats the app');
    });

    test('regional variants match the right table', () {
      const cases = {
        'es': 'es',
        'es-ES': 'es',
        'es-MX': 'es-MX',
        'es-419': 'es-MX',
        'es-US': 'es-MX',
        'es_AR': 'es-MX',
        'pt': 'pt-BR',
        'pt-BR': 'pt-BR',
        'pt-PT': 'pt-PT',
        'pt-AO': 'pt-PT',
        'zh-Hans': 'zh-Hans',
        'zh-Hans-CN': 'zh-Hans',
        'zh': 'zh-Hans',
        'zh-CN': 'zh-Hans',
        'zh-SG': 'zh-Hans',
        'zh-Hant': 'zh-Hant',
        'zh-Hant-TW': 'zh-Hant',
        'zh-TW': 'zh-Hant',
        'zh-HK': 'zh-Hant',
        'zh-Hant-HK': 'zh-Hant',
        'zh_TW': 'zh-Hant',
        'nb': 'nb',
        'no': 'nb',
        'nn-NO': 'nb',
        'nb-NO': 'nb',
        'iw': 'he',
        'he-IL': 'he',
        'in': 'id',
        'ms-MY': 'ms',
        'en-GB': 'en',
        'de-AT': 'de',
        'fr-CH': 'fr',
        'sr': 'en',
      };
      cases.forEach((preference, expected) {
        expect(
          SupportStrings.match([preference]) ?? 'en',
          expected,
          reason: preference,
        );
      });
      for (final language in SupportStrings.supportedLanguages) {
        expect(SupportStrings.match([language]), language);
      }
      // Flutter's own Locale tags go through the same mapping.
      expect(
        SupportStrings.match([
          const Locale.fromSubtags(
            languageCode: 'es',
            countryCode: '419',
          ).toLanguageTag(),
        ]),
        'es-MX',
      );
    });

    test('right-to-left languages', () {
      for (final (language, rtl) in [
        ('ar', true),
        ('he', true),
        ('de', false),
        ('en', false),
      ]) {
        SupportStrings.forcedLanguage = language;
        expect(SupportStrings.isRightToLeft, rtl, reason: language);
        expect(
          SupportStrings.textDirection,
          rtl ? TextDirection.rtl : TextDirection.ltr,
        );
      }
    });
  });

  group('plurals', () {
    test('categories follow CLDR', () {
      void check(String language, Map<int, String> expected) =>
          expected.forEach(
            (n, category) => expect(
              SupportStrings.pluralCategory(n, language),
              category,
              reason: '$language $n',
            ),
          );
      check('en', {0: 'other', 1: 'one', 2: 'other'});
      check('ja', {0: 'other', 1: 'other', 5: 'other'});
      check('fr', {0: 'one', 1: 'one', 2: 'other', 1000000: 'many'});
      check('pt-BR', {0: 'one', 1: 'one', 2: 'other'});
      check('pt-PT', {0: 'other', 1: 'one', 2: 'other', 1000000: 'many'});
      check('es-MX', {0: 'other', 1: 'one', 1000000: 'many'});
      check('hi', {0: 'one', 1: 'one', 2: 'other'});
      check('ru', {
        1: 'one',
        2: 'few',
        4: 'few',
        5: 'many',
        11: 'many',
        12: 'many',
        21: 'one',
        22: 'few',
        25: 'many',
        111: 'many',
      });
      check('uk', {1: 'one', 3: 'few', 0: 'many'});
      check('pl', {1: 'one', 2: 'few', 5: 'many', 21: 'many', 22: 'few'});
      check('cs', {1: 'one', 2: 'few', 4: 'few', 5: 'other', 0: 'other'});
      check('sk', {1: 'one', 3: 'few', 22: 'other'});
      check('hr', {1: 'one', 21: 'one', 11: 'other', 2: 'few', 5: 'other'});
      check('ro', {
        0: 'few',
        1: 'one',
        2: 'few',
        19: 'few',
        20: 'other',
        101: 'few',
        120: 'other',
      });
      check('ar', {
        0: 'zero',
        1: 'one',
        2: 'two',
        3: 'few',
        10: 'few',
        11: 'many',
        99: 'many',
        100: 'other',
        103: 'few',
      });
      check('he', {1: 'one', 2: 'two', 3: 'other', 20: 'other'});
    });

    test("a plural uses the language's form", () {
      SupportStrings.forcedLanguage = 'ru';
      final table = SupportStrings.table('ru');
      for (final (n, form) in [(1, 'one'), (3, 'few'), (7, 'many')]) {
        expect(
          SupportStrings.plural('support.a11y.unread', n),
          SupportStrings.fill(table['support.a11y.unread#$form']!, {
            'count': '$n',
          }),
        );
      }
      SupportStrings.forcedLanguage = 'ar';
      expect(
        SupportStrings.plural('support.a11y.unread', 2),
        SupportStrings.fill(
          SupportStrings.table('ar')['support.a11y.unread#two']!,
          {'count': '2'},
        ),
      );
    });
  });

  group('errors', () {
    test('errors show localized text, not server messages', () {
      SupportStrings.forcedLanguage = 'en';
      String t(String key) => SupportStrings.text(key);
      String e(Object error, [String? fallback]) => fallback == null
          ? SupportStrings.errorText(error)
          : SupportStrings.errorText(error, fallback: fallback);
      expect(
        e(SupportException(429, 'rate_limited')),
        t('support.error.rateLimited'),
      );
      expect(e(SupportException(413, 'too_large')), t('support.error.tooLong'));
      expect(e(SupportException(500, 'boom')), t('support.error.generic'));
      expect(
        e(SupportException(500, 'boom'), 'support.error.loadFailed'),
        t('support.error.loadFailed'),
      );
      expect(
        e(SupportException(400, 'bad'), 'support.error.notSent'),
        t('support.error.notSent'),
      );
      expect(
        e(
          SupportException(0, 'locked', reason: SupportErrorReason.locked),
          'support.error.loadFailed',
        ),
        t('support.error.locked'),
      );
      expect(
        e(SupportException(502, 'x', reason: SupportErrorReason.upload)),
        t('support.error.upload'),
      );
      expect(
        e(SupportException(0, 'x', reason: SupportErrorReason.unavailable)),
        t('support.error.unavailable'),
      );
      expect(e(const SocketException('down')), t('support.error.offline'));
      expect(e(TimeoutException('slow')), t('support.error.offline'));
      expect(e(http.ClientException('reset')), t('support.error.offline'));
      expect(e(const FormatException('?')), t('support.error.generic'));
      SupportStrings.forcedLanguage = 'de';
      expect(
        e(TimeoutException('slow')),
        SupportStrings.table('de')['support.error.offline'],
      );
      // The raw message stays available for logs.
      expect(SupportException(429, 'rate_limited').toString(), 'rate_limited');
    });

    test('the API marks setup and upload failures', () async {
      final unconfigured = SupportAPI(
        client: MockClient((_) async => http.Response('{}', 200)),
        apiKey: () => null,
        read: (_) async => 's',
        write: (_, __) async {},
        profile: () async => {},
      );
      await expectLater(
        unconfigured.conversations(),
        throwsA(
          isA<SupportException>().having(
            (e) => e.reason,
            'reason',
            SupportErrorReason.unavailable,
          ),
        ),
      );
      final upload = SupportAPI(
        client: MockClient((r) async {
          if (r.url.path.endsWith('/session')) {
            return http.Response('{"session":"s"}', 200);
          }
          if (r.url.path.endsWith('/attachments')) {
            return http.Response(
              jsonEncode({
                'attachmentId': 'a1',
                'uploadUrl': 'https://upload.example.com/x',
                'headers': {'Content-Type': 'image/jpeg'},
              }),
              200,
            );
          }
          return http.Response('', 403);
        }),
        apiKey: () => 'key',
        read: (_) async => 's',
        write: (_, __) async {},
        profile: () async => {},
      );
      await expectLater(
        upload.upload(Uint8List.fromList([1, 2, 3])),
        throwsA(
          isA<SupportException>().having(
            (e) => SupportStrings.errorText(e),
            'text',
            SupportStrings.text('support.error.upload'),
          ),
        ),
      );
    });
  });

  group('defaults in the chat language', () {
    test('built-in topics translate; their ids are stable', () {
      expect(
        [for (final t in AppReferSupportTopic.defaults) t.id],
        ['billing', 'restore', 'bug', 'idea'],
      );
      expect(AppReferSupportTopic.billing.title, 'Billing & refunds');
      SupportStrings.forcedLanguage = 'de';
      final de = SupportStrings.table('de');
      expect(
        AppReferSupportTopic.billing.title,
        de['support.topic.billing.title'],
      );
      expect(
        AppReferSupportTopic.bug.subtitle,
        de['support.topic.bug.subtitle'],
      );
      expect(AppReferSupportTopic.idea.prompt, de['support.topic.idea.prompt']);
      expect(AppReferSupportTopic.restore.id, 'restore');
      // Your own tile is shown as written in every language.
      const own = AppReferSupportTopic(
        title: 'Account',
        subtitle: 'Email, password',
        icon: Icons.person,
        tint: Colors.blue,
        prompt: 'What do you need?',
      );
      expect(own.id, 'Account');
      expect(own.title, 'Account');
      expect(own.subtitle, 'Email, password');
      expect(own.prompt, 'What do you need?');
    });

    test('replyTime defaults to the chat language; a set value is kept', () {
      final support = AppReferSupport.instance;
      SupportStrings.forcedLanguage = 'fr';
      expect(
        support.replyTime,
        SupportStrings.table('fr')['support.replyTime.default'],
      );
      SupportStrings.forcedLanguage = 'en';
      expect(support.replyTime, 'under an hour');
      expect(
        supportPresenceLine(teamNames: const [], replyTime: support.replyTime),
        'We usually reply in under an hour',
      );
      SupportStrings.forcedLanguage = 'de';
      expect(
        supportPresenceLine(
          persona: 'Sam',
          teamNames: const ['Jay'],
          replyTime: 'X',
        ),
        SupportStrings.fill(
          SupportStrings.table('de')['support.presence.personaWithTeam']!,
          {'persona': 'Sam', 'name': 'Jay', 'time': 'X'},
        ),
      );
      support.replyTime = 'innerhalb weniger Stunden';
      SupportStrings.forcedLanguage = 'ja';
      expect(support.replyTime, 'innerhalb weniger Stunden');
    });

    test('dates use the keys and the chat locale', () {
      final now = DateTime(2026, 10, 16, 18);
      SupportStrings.forcedLanguage = 'de';
      final de = SupportStrings.table('de');
      expect(
        SupportStrings.timestamp(
          DateTime(2026, 10, 16, 14, 5),
          now: now,
          alwaysUse24HourFormat: true,
        ),
        SupportStrings.fill(de['support.time.today']!, {'time': '14:05'}),
      );
      expect(
        SupportStrings.timestamp(DateTime(2026, 10, 15, 9, 7), now: now),
        SupportStrings.fill(de['support.time.yesterday']!, {'time': '09:07'}),
        reason: 'German clocks are 24-hour',
      );
      expect(
        SupportStrings.timestamp(DateTime(2026, 10, 1, 9, 7), now: now),
        contains('Okt'),
      );
      // Midnight crossings and month starts.
      expect(
        SupportStrings.timestamp(
          DateTime(2026, 9, 30, 23, 59),
          now: DateTime(2026, 10, 1, 0, 1),
        ),
        startsWith(de['support.time.yesterday']!.split('{').first),
      );
      SupportStrings.forcedLanguage = 'en';
      expect(
        SupportStrings.timestamp(DateTime(2026, 10, 16, 14, 5), now: now),
        // intl puts a narrow no-break space before PM.
        matches(RegExp(r'^Today, 2:05\sPM$')),
      );
      expect(
        SupportStrings.clock(
          DateTime(2026, 10, 16, 14, 5),
          alwaysUse24HourFormat: true,
        ),
        '14:05',
      );
      // Every shipped language formats without throwing.
      for (final language in SupportStrings.supportedLanguages) {
        SupportStrings.forcedLanguage = language;
        expect(
          SupportStrings.timestamp(DateTime(2026, 1, 2, 3, 4), now: now),
          isNotEmpty,
        );
      }
    });

    test('section labels uppercase in the chat language', () {
      SupportStrings.forcedLanguage = 'tr';
      expect(SupportStrings.upper('hızlı yardım'), 'HIZLI YARDIM');
      expect(SupportStrings.upper('devam'), 'DEVAM');
      expect(SupportStrings.upper('iş'), 'İŞ');
      SupportStrings.forcedLanguage = 'el';
      expect(SupportStrings.upper('Συνέχεια'), 'ΣΥΝΕΧΕΙΑ');
      SupportStrings.forcedLanguage = 'en';
      expect(SupportStrings.upper('Quick help'), 'QUICK HELP');
    });
  });

  group('chat view', () {
    final conversation = {
      'id': 'c',
      'subject': 'Charge',
      'status': 'open',
      'preview': 'Hello',
      'lastMessageAt': '2026-10-15T12:35:00Z',
      'lastFrom': 'customer',
      'unread': 2,
    };
    SupportAPI api() => SupportAPI(
      client: MockClient(
        (r) async => http.Response.bytes(
          utf8.encode(
            jsonEncode(
              r.url.path.endsWith('/session')
                  ? {'session': 's'}
                  : r.url.path.endsWith('/conversations')
                  ? {
                      'conversations': [conversation],
                    }
                  : {
                      'conversation': conversation,
                      'messages': [
                        {
                          'id': 'm1',
                          'from': 'customer',
                          'text': 'Hello',
                          'createdAt': '2026-10-15T12:35:00Z',
                        },
                      ],
                    },
            ),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
      apiKey: () => 'key',
      read: (_) async => 's',
      write: (_, __) async {},
      profile: () async => {},
    );

    Future<void> pump(
      WidgetTester tester, {
      Locale? locale,
      List<Locale> supported = const [Locale('en', 'US')],
      String? conversationId,
    }) async {
      tester.view.physicalSize = const Size(400, 840);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          supportedLocales: supported,
          // What flutter_localizations gives a real app (Flutter refuses an
          // app locale without them); the chat itself needs none.
          localizationsDelegates: const [
            _AnyLocale<MaterialLocalizations>(DefaultMaterialLocalizations()),
            _AnyLocale<CupertinoLocalizations>(DefaultCupertinoLocalizations()),
            _AnyLocale<WidgetsLocalizations>(DefaultWidgetsLocalizations()),
          ],
          home: AppReferSupportView(api: api(), conversationId: conversationId),
        ),
      );
      await tester.pumpAndSettle();
    }

    String de(String key) => SupportStrings.table('de')[key]!;

    testWidgets('follows the locale the app runs in, without delegates', (
      tester,
    ) async {
      SupportStrings.deviceLocales = () => const [Locale('de', 'DE')];
      await pump(
        tester,
        locale: const Locale('de'),
        supported: const [Locale('en'), Locale('de')],
      );
      expect(SupportStrings.language, 'de');
      expect(find.text(de('support.home.subtitle')), findsOneWidget);
      expect(
        find.text(SupportStrings.upper(de('support.home.continue'))),
        findsOneWidget,
      );
      expect(find.text(de('support.topic.billing.title')), findsOneWidget);
      expect(find.byTooltip(de('support.a11y.send')), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          SupportStrings.fill(de('support.a11y.continueConversation'), {
            'subject': 'Charge',
          }),
        ),
        findsOneWidget,
      );
      expect(
        Directionality.of(tester.element(find.byType(Scaffold))),
        TextDirection.ltr,
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an English-only app on a German phone stays English', (
      tester,
    ) async {
      SupportStrings.deviceLocales = () => const [Locale('de', 'DE')];
      await pump(tester);
      expect(SupportStrings.language, 'en');
      expect(find.text('How can we help today?'), findsOneWidget);
      expect(find.text('Billing & refunds'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Arabic lays out right to left with mirrored bubble tails', (
      tester,
    ) async {
      AppReferSupport.instance.language = 'ar';
      await pump(tester, conversationId: 'c');
      final ar = SupportStrings.table('ar');
      expect(
        find.text(ar['support.composer.placeholder.thread']!),
        findsOneWidget,
      );
      final text = find.text('Hello');
      expect(Directionality.of(tester.element(text)), TextDirection.rtl);
      // The customer's bubble sits on the leading (right) side with its tail
      // in the bottom-left corner.
      final bubble = tester.widget<Container>(
        find.ancestor(of: text, matching: find.byType(Container)).first,
      );
      final radius = (bubble.decoration! as BoxDecoration).borderRadius!
          .resolve(TextDirection.rtl);
      expect(radius.bottomLeft, const Radius.circular(6));
      expect(radius.bottomRight, const Radius.circular(22));
      expect(
        tester.getCenter(text).dx,
        lessThan(200),
        reason: 'customer messages end on the left in RTL',
      );
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a forced language beats the app and an override beats both', (
      tester,
    ) async {
      AppReferSupport.instance.language = 'de';
      AppReferSupport.instance.strings = {
        'support.home.subtitle': 'Was ist los?',
      };
      await pump(tester, locale: const Locale('en', 'US'));
      expect(find.text('Was ist los?'), findsOneWidget);
      expect(find.text(de('support.topic.bug.title')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

/// Stands in for flutter_localizations in tests: any locale is "supported".
class _AnyLocale<T> extends LocalizationsDelegate<T> {
  const _AnyLocale(this.value);
  final T value;
  @override
  bool isSupported(Locale locale) => true;
  @override
  Future<T> load(Locale locale) => SynchronousFuture(value);
  @override
  bool shouldReload(_AnyLocale<T> old) => false;
}
