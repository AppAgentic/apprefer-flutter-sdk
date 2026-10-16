import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:ui' show Locale, PlatformDispatcher, TextDirection;

import 'package:http/http.dart' as http;
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart' show DateFormat;

import 'support_api.dart';
import 'support_strings_table.g.dart';

/// The help chat's text, in 35 languages.
///
/// Lookup order for every key: the app's override (`AppRefer.support.strings`),
/// then the bundled table for the chat's language, then English. The chat's
/// language follows the host app: the locale the app is running in (the
/// `Localizations` locale of the widget tree the chat opens in, which Flutter
/// resolves from the app's `supportedLocales`), so an app that ships fewer
/// languages than the SDK gets a chat that matches its own screens; then the
/// device's preferred languages; then English. `AppRefer.support.language`
/// forces one. No `localizationsDelegates` are needed in the host app.
///
/// Keys and translations come from the shared table every AppRefer SDK uses
/// (`Localization/support-strings.json` in this repo, compiled into
/// `support_strings_table.g.dart` by `tool/generate_support_strings.dart`).
/// `{name}`-style placeholders are filled in by name, so a translation may
/// reorder them. Plural keys are stored as `key#one`, `key#few`, … (CLDR
/// cardinal categories) and picked with [pluralCategory].
abstract final class SupportStrings {
  /// Every language the SDK ships (BCP 47, e.g. "pt-BR", "zh-Hant").
  static const supportedLanguages = supportLanguages;

  /// `AppRefer.support.strings`: key → the app's own text.
  static Map<String, String> overrides = {};

  /// `AppRefer.support.language`: forces the chat's language.
  static String? forcedLanguage;

  /// The locales the app is running in, most preferred first. The chat view
  /// sets this from its widget tree (`Localizations.maybeLocaleOf`); null
  /// until a chat has been shown (only the device's languages count then).
  static List<Locale>? appLocales;

  /// The device's preferred languages. Replaceable in tests.
  static List<Locale> Function() deviceLocales = () =>
      PlatformDispatcher.instance.locales;

  // MARK: Language

  /// The chat's language: one of [supportedLanguages].
  static String get language {
    final forced = forcedLanguage;
    if (forced != null) return match([forced]) ?? 'en';
    return resolve(
      appLanguages: [for (final l in appLocales ?? const []) l.toLanguageTag()],
      deviceLanguages: [for (final l in deviceLocales()) l.toLanguageTag()],
    );
  }

  /// The language the app runs in comes first, so the chat matches the app's
  /// screens; then the device's languages; then English.
  static String resolve({
    required List<String> appLanguages,
    required List<String> deviceLanguages,
  }) => match([...appLanguages, ...deviceLanguages]) ?? 'en';

  /// The first preference the SDK has a table for. Regional variants map to
  /// the table a speaker expects: Latin American Spanish to es-MX, Portuguese
  /// outside Brazil to pt-PT, Chinese by script (Taiwan, Hong Kong and Macau
  /// to Traditional), Norwegian to Bokmål.
  static String? match(Iterable<String> preferences) {
    for (final preference in preferences) {
      final parts = preference
          .replaceAll('_', '-')
          .split('-')
          .where((p) => p.isNotEmpty)
          .toList();
      if (parts.isEmpty) continue;
      final first = parts.first.toLowerCase();
      final rest = parts.skip(1);
      final script = rest
          .where((p) => p.length == 4)
          .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
          .firstOrNull;
      final region = rest
          .where(
            (p) => p.length == 2 || (p.length == 3 && int.tryParse(p) != null),
          )
          .map((p) => p.toUpperCase())
          .firstOrNull;
      switch (first) {
        case 'zh':
          final traditional =
              script == 'Hant' ||
              (script == null && const {'TW', 'HK', 'MO'}.contains(region));
          return traditional ? 'zh-Hant' : 'zh-Hans';
        case 'pt':
          return region == null || region == 'BR' ? 'pt-BR' : 'pt-PT';
        case 'es':
          return region == null || _spanishEurope.contains(region)
              ? 'es'
              : 'es-MX';
        case 'nb' || 'no' || 'nn':
          return 'nb';
        case 'iw':
          return 'he';
        case 'in':
          return 'id';
        default:
          if (supportedLanguages.contains(first)) return first;
      }
    }
    return null;
  }

  /// Regions that read Spain's Spanish; every other region (Latin America,
  /// the US, "419") gets es-MX.
  static const _spanishEurope = {'ES', 'GQ', 'EA', 'IC', 'AD'};

  static bool get isRightToLeft => const {'ar', 'he'}.contains(language);

  static TextDirection get textDirection =>
      isRightToLeft ? TextDirection.rtl : TextDirection.ltr;

  // MARK: Lookup

  /// The text for [key] with `{placeholders}` filled in.
  static String text(String key, [Map<String, String> arguments = const {}]) {
    final template =
        overrides[key] ?? bundled(key, language) ?? bundled(key, 'en') ?? key;
    return fill(template, arguments);
  }

  /// A plural key: the form for [count] in the chat's language, with
  /// `{count}` filled in.
  static String plural(
    String key,
    int count, [
    Map<String, String> arguments = const {},
  ]) {
    final lang = language;
    final category = pluralCategory(count, lang);
    final custom = overrides;
    final template =
        custom['$key#$category'] ??
        custom[key] ??
        bundled('$key#$category', lang) ??
        bundled('$key#other', lang) ??
        bundled('$key#${pluralCategory(count, 'en')}', 'en') ??
        key;
    return fill(template, {...arguments, 'count': '$count'});
  }

  /// The bundled translation, or null when the language or key is missing.
  static String? bundled(String key, String language) {
    final value = supportStringsTable[language]?[key];
    return value == null || value.isEmpty ? null : value;
  }

  /// One language's whole table (empty for a language the SDK doesn't ship).
  static Map<String, String> table(String language) =>
      supportStringsTable[language] ?? const {};

  /// Replaces `{name}` with `arguments['name']`; unknown placeholders stay as
  /// written. One pass, so a value that itself contains braces is never
  /// expanded again.
  static String fill(String template, Map<String, String> arguments) {
    if (arguments.isEmpty || !template.contains('{')) return template;
    final result = StringBuffer();
    var rest = template;
    while (true) {
      final open = rest.indexOf('{');
      if (open < 0) break;
      result.write(rest.substring(0, open));
      final after = rest.substring(open + 1);
      final close = after.indexOf('}');
      final value = close < 0 ? null : arguments[after.substring(0, close)];
      if (value != null) {
        result.write(value);
        rest = after.substring(close + 1);
      } else {
        result.write('{');
        rest = after;
      }
    }
    result.write(rest);
    return result.toString();
  }

  // MARK: Plurals

  /// The CLDR cardinal plural category of a whole number in one of the SDK's
  /// languages.
  static String pluralCategory(int count, String language) {
    final n = count.abs();
    final n10 = n % 10, n100 = n % 100;
    bool between(int v, int a, int b) => v >= a && v <= b;
    switch (language.split('-').first) {
      case 'ja' || 'ko' || 'zh' || 'th' || 'vi' || 'id' || 'ms':
        return 'other';
      case 'hi':
        return n <= 1 ? 'one' : 'other';
      case 'fr':
      case 'pt' when language != 'pt-PT':
        if (n <= 1) return 'one';
        return n % 1000000 == 0 ? 'many' : 'other';
      case 'pt' || 'es' || 'it' || 'ca':
        if (n == 1) return 'one';
        return n != 0 && n % 1000000 == 0 ? 'many' : 'other';
      case 'ru' || 'uk':
        if (n10 == 1 && n100 != 11) return 'one';
        if (between(n10, 2, 4) && !between(n100, 12, 14)) return 'few';
        return 'many';
      case 'pl':
        if (n == 1) return 'one';
        if (between(n10, 2, 4) && !between(n100, 12, 14)) return 'few';
        return 'many';
      case 'cs' || 'sk':
        if (n == 1) return 'one';
        return between(n, 2, 4) ? 'few' : 'other';
      case 'hr':
        if (n10 == 1 && n100 != 11) return 'one';
        if (between(n10, 2, 4) && !between(n100, 12, 14)) return 'few';
        return 'other';
      case 'ro':
        if (n == 1) return 'one';
        return n == 0 || between(n100, 1, 19) ? 'few' : 'other';
      case 'ar':
        if (n == 0) return 'zero';
        if (n == 1) return 'one';
        if (n == 2) return 'two';
        if (between(n100, 3, 10)) return 'few';
        if (between(n100, 11, 99)) return 'many';
        return 'other';
      case 'he':
        if (n == 1) return 'one';
        return n == 2 ? 'two' : 'other';
      default: // en, de, nl, sv, da, nb, fi, el, hu, tr
        return n == 1 ? 'one' : 'other';
    }
  }

  // MARK: Dates

  /// The `intl` locale for a chat language.
  static String intlLocale(String language) => switch (language) {
    'zh-Hans' => 'zh_CN',
    'zh-Hant' => 'zh_TW',
    _ => language.replaceAll('-', '_'),
  };

  static bool _dateData = false;
  static String _dateLocale(String language) {
    if (!_dateData) {
      // Synchronous despite the Future: loads intl's bundled locale data.
      // A no-op if the app (e.g. flutter_localizations) loaded data first.
      unawaited(initializeDateFormatting());
      _dateData = true;
    }
    for (final candidate in [
      intlLocale(language),
      language.split('-').first,
      'en',
    ]) {
      if (DateFormat.localeExists(candidate)) return candidate;
    }
    return 'en';
  }

  /// A clock time ("14:05", "2:05 PM") in the chat's language.
  static String clock(DateTime date, {bool alwaysUse24HourFormat = false}) {
    final locale = _dateLocale(language);
    try {
      return (alwaysUse24HourFormat
              ? DateFormat.Hm(locale)
              : DateFormat.jm(locale))
          .format(date);
    } catch (_) {
      final h = date.hour.toString().padLeft(2, '0');
      return '$h:${date.minute.toString().padLeft(2, '0')}';
    }
  }

  /// A message timestamp: "Today, 14:05", "Yesterday, 09:12", or the date
  /// and time ("14 Oct 2026 14:05") in the chat's language.
  static String timestamp(
    DateTime date, {
    DateTime? now,
    bool alwaysUse24HourFormat = false,
  }) {
    final time = clock(date, alwaysUse24HourFormat: alwaysUse24HourFormat);
    final current = now ?? DateTime.now();
    final today = DateTime(current.year, current.month, current.day);
    final day = DateTime(date.year, date.month, date.day);
    if (day == today) return text('support.time.today', {'time': time});
    if (day == DateTime(today.year, today.month, today.day - 1)) {
      return text('support.time.yesterday', {'time': time});
    }
    try {
      return '${DateFormat.yMMMd(_dateLocale(language)).format(date)} $time';
    } catch (_) {
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')} $time';
    }
  }

  /// Uppercase in the chat's language (section labels): Turkish keeps the
  /// dotted İ and Greek drops its accents, as iOS's locale-aware uppercasing.
  static String upper(String value) {
    switch (language) {
      case 'tr':
        return value.replaceAll('i', 'İ').toUpperCase();
      case 'el':
        var upper = value.toUpperCase();
        _greekAccents.forEach((from, to) => upper = upper.replaceAll(from, to));
        return upper;
      default:
        return value.toUpperCase();
    }
  }

  static const _greekAccents = {
    'Ά': 'Α', 'Έ': 'Ε', 'Ή': 'Η', 'Ί': 'Ι', 'Ό': 'Ο', 'Ύ': 'Υ', 'Ώ': 'Ω', //
    'ΐ': 'Ϊ', 'ΰ': 'Ϋ',
  };

  // MARK: Errors

  /// What to show for a failed request: the customer's language, never a raw
  /// server message. [fallback] is the key for anything not more specific
  /// (e.g. `support.error.loadFailed` while loading).
  static String errorText(
    Object error, {
    String fallback = 'support.error.generic',
  }) {
    if (error is SupportException) {
      switch (error.reason) {
        case SupportErrorReason.locked:
          return text('support.error.locked');
        case SupportErrorReason.upload:
          return text('support.error.upload');
        case SupportErrorReason.unavailable:
          return text('support.error.unavailable');
        case SupportErrorReason.reset || SupportErrorReason.server:
          return switch (error.status) {
            413 => text('support.error.tooLong'),
            429 => text('support.error.rateLimited'),
            _ => text(fallback),
          };
      }
    }
    if (error is SocketException ||
        error is TimeoutException ||
        error is http.ClientException) {
      return text('support.error.offline');
    }
    return text(fallback);
  }
}
