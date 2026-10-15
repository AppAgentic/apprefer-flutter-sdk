import 'package:apprefer/src/support/support_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
