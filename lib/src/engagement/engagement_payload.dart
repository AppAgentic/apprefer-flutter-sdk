import 'dart:convert';

/// An AppRefer lifecycle notification (wire schema 1), parsed and validated.
///
/// The server sends one `engagement` object in both transports: on APNs as the
/// custom key `apprefer` (`{"type": "engagement", ...}`, next to Support's
/// `{"type": "support_reply"}`), on FCM as the data field `engagement` (JSON)
/// with `type = "engagement"`. Validation is strict and never executes
/// anything: `destination` is an in-app path your app maps to a screen, never
/// a URL to open. The native layer applies the same rules before rendering.
class AppReferEngagementPayload {
  AppReferEngagementPayload._({
    required this.messageId,
    required this.purpose,
    required this.expiresAt,
    required this.accountEpoch,
    required this.installId,
    required this.destination,
    required this.collapseKey,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.imageUrl,
    required this.actions,
    required this.receiptToken,
  });

  final String messageId;

  /// `marketing`, `reminders` or `service`.
  final String purpose;
  final DateTime expiresAt;
  final int accountEpoch;
  final String installId;
  final String? destination;
  final String? collapseKey;
  final String title;
  final String? subtitle;
  final String body;
  final String? imageUrl;
  final List<AppReferEngagementAction> actions;

  /// Narrow proof for this message's receipts (not a credential).
  final String receiptToken;

  bool isExpired([DateTime? now]) =>
      !(now ?? DateTime.now()).isBefore(expiresAt);

  static const purposes = ['marketing', 'reminders', 'service'];
  static const kinds = ['open', 'view', 'start', 'snooze'];

  /// Whether an FCM data map is an AppRefer engagement notification (valid or not).
  static bool isEngagement(Map<String, dynamic>? data) =>
      data?['type'] == 'engagement';

  /// Parses an FCM data map (`engagement` as JSON text) or an APNs `userInfo`
  /// (`apprefer` dictionary). Null when it is not an engagement notification;
  /// throws [FormatException] (message = reason) when AppRefer owns it but
  /// can't use it.
  static AppReferEngagementPayload? parse(Map<String, dynamic>? data) {
    if (data == null) return null;
    final apns = data['apprefer'];
    if (apns is Map && apns['type'] == 'engagement') {
      return parseObject(Map<String, dynamic>.from(apns));
    }
    if (!isEngagement(data)) return null;
    final text = data['engagement'];
    if (text is Map) return parseObject(Map<String, dynamic>.from(text));
    if (text is! String || text.length > 8192)
      throw const FormatException('malformed');
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      throw const FormatException('malformed');
    }
    if (decoded is! Map) throw const FormatException('malformed');
    return parseObject(Map<String, dynamic>.from(decoded));
  }

  static final _messageId = RegExp(r'^[A-Za-z0-9_.:-]{1,400}$');
  static final _installId = RegExp(r'^ei_[a-z2-7]{26}$');
  static final _destination = RegExp(r'^/[A-Za-z0-9/_\-.~%?=&]*$');
  static final _collapse = RegExp(r'^[a-z0-9_-]{1,32}$');
  static final _actionId = RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$');
  static final _token = RegExp(r'^er1\.[A-Za-z0-9_-]{43}$');
  static final _image = RegExp(
    r'^https://([a-z0-9.-]+)(/[A-Za-z0-9_\-.~%]+)*/[A-Za-z0-9_\-.~%]+\.(png|jpe?g)$',
  );
  static final _host = RegExp(
    r'^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
  );

  static bool isDestination(Object? value) =>
      value is String &&
      value.length <= 256 &&
      !value.startsWith('//') &&
      _destination.hasMatch(value);

  static bool isHost(String host) =>
      host.length >= 4 && host.length <= 253 && _host.hasMatch(host);

  /// The URL's host when it is an allowed image URL shape, else null.
  static String? imageHost(Object? url) {
    if (url is! String || url.length > 512) return null;
    final m = _image.firstMatch(url);
    if (m == null || !isHost(m.group(1)!)) return null;
    final path = url.substring(8 + m.group(1)!.length);
    if (path.contains('//')) return null;
    for (final segment in path.split('/')) {
      if (segment == '.' ||
          segment == '..' ||
          RegExp(r'%2e|%2f|%5c', caseSensitive: false).hasMatch(segment))
        return null;
    }
    return m.group(1);
  }

  static int? _int(Object? v) {
    if (v is int) return v;
    if (v is double && v == v.roundToDouble() && v.isFinite) return v.toInt();
    return null;
  }

  static AppReferEngagementPayload parseObject(Map<String, dynamic> o) {
    Never fail(String reason) => throw FormatException(reason);
    if (o['type'] != 'engagement') fail('type');
    if (_int(o['v']) != 1) fail('unsupported_version');
    final mid = o['mid'];
    if (mid is! String || !_messageId.hasMatch(mid)) fail('message_id');
    final purpose = o['purpose'];
    if (purpose is! String || !purposes.contains(purpose)) fail('purpose');
    final exp = o['exp'];
    if (exp is! num || exp is bool || !exp.isFinite || exp <= 0) fail('expiry');
    final epoch = _int(o['epoch']);
    if (epoch == null || epoch < 0) fail('epoch');
    final iid = o['iid'];
    if (iid is! String || !_installId.hasMatch(iid)) fail('install');
    final dest = o['dest'];
    if (dest != null && !isDestination(dest)) fail('destination');
    final ck = o['ck'];
    if (ck != null && (ck is! String || !_collapse.hasMatch(ck)))
      fail('collapse_key');
    final title = o['title'], body = o['body'], subtitle = o['subtitle'];
    if (title is! String ||
        title.isEmpty ||
        title.length > 128 ||
        body is! String ||
        body.isEmpty ||
        body.length > 512)
      fail('copy');
    if (subtitle != null && (subtitle is! String || subtitle.length > 128))
      fail('copy');
    final img = o['img'];
    if (img != null && imageHost(img) == null) fail('image');
    final actions = <AppReferEngagementAction>[];
    final list = o['actions'];
    if (list != null) {
      if (list is! List || list.length > 2) fail('actions');
      for (final raw in list) {
        if (raw is! Map) fail('actions');
        final id = raw['id'], kind = raw['kind'];
        if (id is! String ||
            !_actionId.hasMatch(id) ||
            kind is! String ||
            !kinds.contains(kind))
          fail('actions');
        if (actions.any((a) => a.id == id || a.kind == kind)) fail('actions');
        if (kind == 'snooze') {
          final min = _int(raw['min']);
          if (min == null || min < 5 || min > 1440 || raw.containsKey('dest'))
            fail('actions');
          actions.add(
            AppReferEngagementAction(
              id: id,
              kind: kind,
              destination: null,
              snoozeMinutes: min,
            ),
          );
        } else {
          final d = raw['dest'];
          if (d != null && !isDestination(d)) fail('actions');
          actions.add(
            AppReferEngagementAction(
              id: id,
              kind: kind,
              destination: d as String?,
              snoozeMinutes: null,
            ),
          );
        }
      }
    }
    final rt = o['rt'];
    if (rt is! String || !_token.hasMatch(rt)) fail('receipt_token');
    return AppReferEngagementPayload._(
      messageId: mid,
      purpose: purpose,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(exp.toInt()),
      accountEpoch: epoch,
      installId: iid,
      destination: dest as String?,
      collapseKey: ck as String?,
      title: title,
      subtitle: subtitle as String?,
      body: body,
      imageUrl: img as String?,
      actions: List.unmodifiable(actions),
      receiptToken: rt,
    );
  }
}

/// A notification button. Labels come from the SDK's 35-language table by kind.
class AppReferEngagementAction {
  const AppReferEngagementAction({
    required this.id,
    required this.kind,
    required this.destination,
    required this.snoozeMinutes,
  });
  final String id;

  /// `open`, `view`, `start` or `snooze`.
  final String kind;
  final String? destination;
  final int? snoozeMinutes;
}
