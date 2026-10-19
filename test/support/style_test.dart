import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/support/support_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('presence text with and without a persona and team names', () {
    String line(String? persona, List<String> names) => supportPresenceLine(
      persona: persona,
      teamNames: names,
      replyTime: 'under an hour',
    );
    expect(
      line('Sam', ['Jay', 'Ana']),
      'Sam replies instantly · Jay and the team in under an hour',
    );
    expect(
      line('Sam', ['Jay']),
      'Sam replies instantly · Jay and the team in under an hour',
    );
    expect(
      line('Sam', []),
      'Sam replies instantly · the team in under an hour',
    );
    expect(line(null, []), 'We usually reply in under an hour');
    expect(line(null, ['Jay']), 'Jay · usually replies in under an hour');
    expect(
      line(null, ['Jay', 'Ana']),
      'Jay and the team · usually under an hour',
    );
  });

  test('quick replies follow an answer but never a hand-over', () {
    expect(supportShowsQuickReplies(null), isFalse);
    expect(supportShowsQuickReplies({'from': 'customer'}), isFalse);
    expect(supportShowsQuickReplies({'from': 'team'}), isTrue);
    expect(supportShowsQuickReplies({'from': 'bot'}), isTrue);
    expect(supportShowsQuickReplies({'from': 'bot', 'handoff': true}), isFalse);
  });

  test('onAccent is dark on a bright yellow and white on purple', () {
    expect(
      SupportPalette(const Color(0xffffd60a)).onAccent,
      const Color(0xff141414),
    );
    expect(SupportPalette(const Color(0xff7955ff)).onAccent, Colors.white);
    expect(SupportPalette(const Color(0xff6e4aff)).onAccent, Colors.white);
  });

  test('palette neighbours follow the iOS maths', () {
    final p = SupportPalette(const Color(0xff7955ff));
    final accent = HSVColor.fromColor(p.accent);
    final light = HSVColor.fromColor(p.light);
    final hot = HSVColor.fromColor(p.hot);
    final deep = HSVColor.fromColor(p.deep);
    expect(light.hue, closeTo((accent.hue - 7.2) % 360, 1));
    expect(light.saturation, closeTo(accent.saturation * 0.72, 0.01));
    expect(light.value, 1); // b * 1.08 + 0.05 clamps
    expect(hot.hue, closeTo((accent.hue + 82.8) % 360, 1));
    expect(hot.value, 1);
    expect(deep.value, closeTo(accent.value * 0.86, 0.01));
  });

  test('continue picks unread first, then the newest open conversation', () {
    Map<String, dynamic> c(
      String id,
      String at, {
      int unread = 0,
      String status = 'open',
    }) => {'id': id, 'lastMessageAt': at, 'unread': unread, 'status': status};
    final newest = c('newest', '2026-10-15T12:00:00Z');
    final unread = c('unread', '2026-10-14T09:00:00Z', unread: 2);
    final closed = c(
      'closed',
      '2026-10-15T13:00:00Z',
      unread: 1,
      status: 'closed',
    );
    final older = c('older', '2026-10-13T09:00:00Z');

    var s = supportContinueSelection([closed, newest, unread, older]);
    expect(s.current, same(unread));
    expect(s.others.map((x) => x['id']), ['closed', 'newest', 'older']);

    s = supportContinueSelection([older, newest, closed]);
    expect(s.current, same(newest));
    expect(s.others.map((x) => x['id']), ['older', 'closed']);

    s = supportContinueSelection([closed]);
    expect(s.current, isNull);
    expect(s.others, [closed]);
  });

  test('first names never show an email', () {
    expect(supportFirstName('Jay Smith'), 'Jay');
    expect(supportFirstName('jay@example.com'), isNull);
    expect(supportFirstName('  '), isNull);
  });

  group('header style (0.11.1)', () {
    bool neutral(Color c) =>
        (c.r - c.g).abs() < 0.002 && (c.g - c.b).abs() < 0.002;
    double contrast(Color a, Color b) {
      final x = a.computeLuminance(), y = b.computeLuminance();
      return ((x > y ? x : y) + 0.05) / ((x > y ? y : x) + 0.05);
    }

    const accents = [
      Color(0xff7852ff),
      Colors.white,
      Color(0xffffd60a),
      Color(0xff1fb866),
    ];

    test('defaults to accent and is exported', () {
      expect(
        AppReferSupport.instance.headerStyle,
        AppReferSupportHeaderStyle.accent,
      );
      expect(AppReferSupportHeaderStyle.values, [
        AppReferSupportHeaderStyle.accent,
        AppReferSupportHeaderStyle.plain,
      ]);
    });

    test('accent keeps the existing look', () {
      for (final accent in accents) {
        final p = SupportPalette(accent);
        for (final dark in [true, false]) {
          final h = SupportHeaderLook(
            AppReferSupportHeaderStyle.accent,
            p,
            dark: dark,
          );
          expect(h.plain, isFalse);
          expect(h.glows, isTrue);
          expect(h.background, p.accent);
          expect(h.foreground, p.onAccent);
          expect(h.foregroundIsDark, p.darkOnAccent);
          expect(
            h.pillFill,
            Colors.black.withValues(alpha: p.darkOnAccent ? 0.06 : 0.16),
          );
          expect(h.pillBorder, p.onAccent.withValues(alpha: 0.3));
          expect(h.avatars, isNull);
          expect(h.iconText, p.light);
          expect(h.iconTile, const [Color(0xff29205c), Color(0xff0f0a1f)]);
        }
      }
    });

    test('a white accent glows tinted, which is why plain exists', () {
      final p = SupportPalette(Colors.white);
      expect(neutral(p.hot) && neutral(p.warm), isFalse);
    });

    test('plain is neutral, glow-free and readable', () {
      for (final accent in accents) {
        final p = SupportPalette(accent);
        for (final dark in [true, false]) {
          final h = SupportHeaderLook(
            AppReferSupportHeaderStyle.plain,
            p,
            dark: dark,
          );
          expect(h.plain, isTrue);
          expect(h.glows, isFalse);
          expect(h.background, SupportHeaderLook.plainBackground(dark));
          expect(h.foreground, SupportHeaderLook.plainInk(dark));
          expect(h.foregroundIsDark, !dark);
          for (final c in [
            h.background,
            h.foreground,
            h.closeFill,
            h.closeBorder,
            h.pillFill,
            h.pillBorder,
            h.avatarRing,
            h.iconText,
            ...h.avatars!,
            ...h.iconTile,
          ]) {
            expect(neutral(c), isTrue, reason: '$c');
          }
          expect(
            contrast(h.foreground, h.background),
            greaterThanOrEqualTo(4.5),
          );
          for (final a in h.avatars!) {
            expect(contrast(Colors.white, a), greaterThanOrEqualTo(4.5));
          }
        }
      }
    });

    test('the hero painter skips the glows for plain', () {
      final p = SupportPalette(Colors.white);
      final plain = SupportHeaderLook(
        AppReferSupportHeaderStyle.plain,
        p,
        dark: true,
      );
      final accent = SupportHeaderLook(
        AppReferSupportHeaderStyle.accent,
        p,
        dark: true,
      );
      expect(
        SupportHeroPainter(
          p,
          null,
          plain,
        ).shouldRepaint(SupportHeroPainter(p, null, accent)),
        isTrue,
      );
      expect(SupportHeroPainter(p, null).look.glows, isTrue);
    });
  });
}
