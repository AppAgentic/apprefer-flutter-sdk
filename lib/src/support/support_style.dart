import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'support_strings.dart';

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

/// How `AppReferSupport.headerStyle` draws the home screen's header.
enum AppReferSupportHeaderStyle {
  /// The accent with soft coloured glows (the default).
  accent,

  /// A flat neutral grey surface with the page's text colour: no accent,
  /// glow or colour.
  plain,
}

/// How the home header is drawn for an [AppReferSupportHeaderStyle] (the
/// iOS/Android `SupportHeaderLook`). Accent is the accent with three soft
/// glows and text that follows it; plain is one flat neutral grey with the
/// page's text colour: no accent, glow or coloured avatar in the header.
class SupportHeaderLook {
  factory SupportHeaderLook(
    AppReferSupportHeaderStyle style,
    SupportPalette palette, {
    required bool dark,
  }) {
    if (style == AppReferSupportHeaderStyle.plain) {
      final background = plainBackground(dark);
      final ink = plainInk(dark);
      return SupportHeaderLook._(
        plain: true,
        background: background,
        foreground: ink,
        foregroundIsDark: !dark,
        closeFill: ink.withValues(alpha: 0.08),
        closeBorder: ink.withValues(alpha: 0.16),
        pillFill: ink.withValues(alpha: 0.06),
        pillBorder: ink.withValues(alpha: 0.16),
        avatars: plainAvatar,
        avatarRing: background,
        iconTile: const [Color(0xff3d3d3d), Color(0xff1c1c1c)],
        iconText: Colors.white,
      );
    }
    final on = palette.onAccent;
    return SupportHeaderLook._(
      plain: false,
      background: palette.accent,
      foreground: on,
      foregroundIsDark: palette.darkOnAccent,
      closeFill: palette.darkOnAccent
          ? Colors.black.withValues(alpha: 0.06)
          : Colors.white.withValues(alpha: 0.24),
      closeBorder: Colors.white.withValues(alpha: 0.45),
      pillFill: Colors.black.withValues(
        alpha: palette.darkOnAccent ? 0.06 : 0.16,
      ),
      pillBorder: on.withValues(alpha: 0.3),
      avatars: null,
      avatarRing: Colors.white.withValues(alpha: 0.9),
      iconTile: const [Color(0xff29205c), Color(0xff0f0a1f)],
      iconText: palette.light,
    );
  }

  const SupportHeaderLook._({
    required this.plain,
    required this.background,
    required this.foreground,
    required this.foregroundIsDark,
    required this.closeFill,
    required this.closeBorder,
    required this.pillFill,
    required this.pillBorder,
    required this.avatars,
    required this.avatarRing,
    required this.iconTile,
    required this.iconText,
  });

  final bool plain;

  /// The header's base fill; accent draws its glows on top.
  final Color background;
  bool get glows => !plain;

  /// Title, greeting, subtitle, presence text and the close icon.
  final Color foreground;

  /// Whether [foreground] is dark (the status bar over the header follows it).
  final bool foregroundIsDark;
  final Color closeFill, closeBorder, pillFill, pillBorder;

  /// Avatars in the presence pill and on the Continue card; null keeps the
  /// accent's and per-person colours.
  final List<Color>? avatars;

  /// The ring that separates overlapping avatars.
  final Color avatarRing;

  /// The initials tile shown when the app has no icon.
  final List<Color> iconTile;
  final Color iconText;

  /// Neutral (R = G = B) greys: a step up from the page in dark mode, a step down in light.
  static Color plainBackground(bool dark) =>
      dark ? const Color(0xff1c1c1c) : const Color(0xffebebeb);

  /// White, or a neutral near-black (the page's ink has a faint tint the plain header avoids).
  static Color plainInk(bool dark) =>
      dark ? Colors.white : const Color(0xff121212);

  /// White initials on these read at 5:1 or better.
  static const plainAvatar = [Color(0xff6b6b6b), Color(0xff3a3a3a)];
}

/// The hero: accent plus three soft radial glows, or the plain header's flat
/// grey. Paints upward into the overscroll gap when the home is pulled down,
/// so the colour never ends early.
class SupportHeroPainter extends CustomPainter {
  SupportHeroPainter(this.palette, this.scroll, [SupportHeaderLook? look])
    : look =
          look ??
          SupportHeaderLook(
            AppReferSupportHeaderStyle.accent,
            palette,
            dark: false,
          ),
      super(repaint: scroll);
  final SupportPalette palette;
  final SupportHeaderLook look;
  final ScrollController? scroll;

  @override
  void paint(Canvas canvas, Size size) {
    final pull = scroll != null && scroll!.hasClients
        ? (-scroll!.offset).clamp(0.0, double.infinity)
        : 0.0;
    final rect = Rect.fromLTRB(0, -pull, size.width, size.height);
    canvas.drawRect(rect, Paint()..color = look.background);
    if (!look.glows) return;
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
      old.palette.accent != palette.accent ||
      old.look.background != look.background ||
      old.look.glows != look.glows ||
      old.scroll != scroll;
}

/// A round avatar: a person's initial, or an icon, on a gradient.
/// The avatar on the home's Continue card (found by tests).
const supportContinueAvatarKey = ValueKey('apprefer.support.continueAvatar');

class SupportAvatar extends StatelessWidget {
  const SupportAvatar({
    super.key,
    this.name,
    required this.size,
    required this.colors,
    this.icon,
    this.ring = false,
    this.ringColor,
    this.imageUrl,
  });
  final String? name;
  final double size;
  final List<Color> colors;
  final IconData? icon;
  final bool ring;

  /// The ring's colour; white by default.
  final Color? ringColor;

  /// A portrait (the AI assistant's); the initial shows until it loads, or if it can't.
  final String? imageUrl;

  @override
  Widget build(BuildContext context) {
    final initial = name?.trim().isNotEmpty == true
        ? name!.trim().characters.first.toUpperCase()
        : '•';
    final url = imageUrl;
    final base = _base(initial);
    return ExcludeSemantics(
      child: url == null || url.isEmpty
          ? base
          : Stack(
              clipBehavior: Clip.none,
              children: [
                base,
                ClipOval(
                  child: Image.network(
                    url,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    errorBuilder: (_, e, s) => const SizedBox.shrink(),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _base(String initial) => Container(
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
              color: ringColor ?? Colors.white.withValues(alpha: 0.9),
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
  );
}

/// The small "AI" tag on everything the AI assistant says.
class SupportAITag extends StatelessWidget {
  const SupportAITag({super.key, required this.palette});
  final SupportPalette palette;

  @override
  Widget build(BuildContext context) => Semantics(
    label: SupportStrings.text('support.a11y.aiAssistant'),
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        SupportStrings.text('support.ai.tag'),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.4,
          color: palette.accent,
        ),
      ),
    ),
  );
}

/// The presence pill's text on the help home (same wording as iOS), in the
/// chat's language.
String supportPresenceLine({
  String? persona,
  required List<String> teamNames,
  required String replyTime,
}) {
  final all = teamNames.where((n) => n.trim().isNotEmpty).toList();
  if (persona != null) {
    return all.isEmpty
        ? SupportStrings.text('support.presence.persona', {
            'persona': persona,
            'time': replyTime,
          })
        : SupportStrings.text('support.presence.personaWithTeam', {
            'persona': persona,
            'name': all.first,
            'time': replyTime,
          });
  }
  if (all.isEmpty) {
    return SupportStrings.text('support.presence.team', {'time': replyTime});
  }
  return all.length == 1
      ? SupportStrings.text('support.presence.one', {
          'name': all.first,
          'time': replyTime,
        })
      : SupportStrings.text('support.presence.many', {
          'name': all.first,
          'time': replyTime,
        });
}

/// The thank-you / another-question chips: only after an answer, never after
/// a hand-over (the customer is waiting for a person, not done).
bool supportShowsQuickReplies(Map<String, dynamic>? last) =>
    last != null && last['from'] != 'customer' && last['handoff'] != true;
