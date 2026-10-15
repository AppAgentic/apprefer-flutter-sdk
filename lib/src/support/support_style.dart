import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Colours for the chat, built from the app's accent (same maths as iOS).
class SupportPalette {
  SupportPalette._(
    this.accent,
    this.light,
    this.hot,
    this.warm,
    this.deep,
    this.onAccent,
  );

  factory SupportPalette(Color accent) {
    final hsv = HSVColor.fromColor(accent);
    final h = hsv.hue / 360, s = hsv.saturation, b = hsv.value;
    Color hsb(double hue, double sat, double bri) => HSVColor.fromAHSV(
      1,
      ((hue % 1) + 1) % 1 * 360,
      sat.clamp(0.0, 1.0),
      bri.clamp(0.0, 1.0),
    ).toColor();
    final luminance = 0.2126 * accent.r + 0.7152 * accent.g + 0.0722 * accent.b;
    return SupportPalette._(
      accent,
      hsb(h - 0.02, s * 0.72, b * 1.08 + 0.05),
      hsb(h + 0.23, s * 0.6 < 0.2 ? 0.2 : s * 0.6, 1),
      hsb(h + 0.38, s * 0.62 < 0.2 ? 0.2 : s * 0.62, 1),
      hsb(h + 0.005, s * 1.05, b * 0.86),
      luminance > 0.62 ? const Color(0xff141414) : Colors.white,
    );
  }

  final Color accent;

  /// Lighter, hotter and warmer neighbours of the accent for the hero and avatars.
  final Color light, hot, warm, deep;

  /// Text and icons drawn on the accent (dark on a bright accent such as yellow).
  final Color onAccent;
  bool get darkOnAccent => onAccent != Colors.white;

  /// Customer bubbles and the send button.
  LinearGradient get bubble => LinearGradient(
    colors: [light, deep],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class SupportColors {
  const SupportColors(this.dark);
  final bool dark;
  Color get background =>
      dark ? const Color(0xff0d0d12) : const Color(0xfff5f4f9);
  Color get card => dark ? const Color(0xff1f1d24) : Colors.white;
  Color get muted => dark ? const Color(0xff9e9e9e) : const Color(0xff8a8698);
  Color get primary => dark ? Colors.white : const Color(0xff111111);
  static const shadow = Color(0xff29145a);
}

/// The open conversation to pick up again (unread first, then the newest) and the rest.
({Map<String, dynamic>? current, List<Map<String, dynamic>> others})
supportContinueSelection(List<Map<String, dynamic>> conversations) {
  Map<String, dynamic>? current;
  int unread(Map<String, dynamic> c) => (c['unread'] as int? ?? 0) > 0 ? 1 : 0;
  for (final c in conversations) {
    if (c['status'] == 'closed') continue;
    if (current == null) {
      current = c;
      continue;
    }
    final byUnread = unread(c).compareTo(unread(current));
    if (byUnread > 0 ||
        (byUnread == 0 &&
            '${c['lastMessageAt']}'.compareTo('${current['lastMessageAt']}') >
                0)) {
      current = c;
    }
  }
  return (
    current: current,
    others: [
      for (final c in conversations)
        if (!identical(c, current)) c,
    ],
  );
}

/// A person's first name, never an email address.
String? supportFirstName(String? name) {
  final trimmed = name?.trim();
  if (trimmed == null || trimmed.isEmpty || trimmed.contains('@')) return null;
  return trimmed.split(RegExp(r'\s+')).first;
}

/// The hero: accent plus three soft radial glows. Paints upward into the
/// overscroll gap when the home is pulled down, so the colour never ends early.
class SupportHeroPainter extends CustomPainter {
  SupportHeroPainter(this.palette, this.scroll) : super(repaint: scroll);
  final SupportPalette palette;
  final ScrollController? scroll;

  @override
  void paint(Canvas canvas, Size size) {
    final pull = scroll != null && scroll!.hasClients
        ? (-scroll!.offset).clamp(0.0, double.infinity)
        : 0.0;
    final rect = Rect.fromLTRB(0, -pull, size.width, size.height);
    canvas.drawRect(rect, Paint()..color = palette.accent);
    void glow(Color color, double x, double y, double radius) {
      final center = Offset(
        rect.left + rect.width * x,
        rect.top + rect.height * y,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(center, radius, [
            color,
            color.withValues(alpha: 0),
          ]),
      );
    }

    glow(palette.light, 0.1, 0, 380);
    glow(palette.hot, 1, 0.2, 320);
    glow(palette.warm.withValues(alpha: 0.95), 0.6, 1.05, 340);
  }

  @override
  bool shouldRepaint(SupportHeroPainter old) =>
      old.palette.accent != palette.accent || old.scroll != scroll;
}

/// A round avatar: a person's initial, or an icon, on a gradient.
class SupportAvatar extends StatelessWidget {
  const SupportAvatar({
    super.key,
    this.name,
    required this.size,
    required this.colors,
    this.icon,
    this.ring = false,
  });
  final String? name;
  final double size;
  final List<Color> colors;
  final IconData? icon;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final initial = name?.trim().isNotEmpty == true
        ? name!.trim().characters.first.toUpperCase()
        : '•';
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: colors,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: ring
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.9),
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignOutside,
                )
              : null,
        ),
        child: icon != null
            ? Icon(icon, size: size * 0.45, color: Colors.white)
            : Text(
                initial,
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontSize: size * 0.4,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }
}
