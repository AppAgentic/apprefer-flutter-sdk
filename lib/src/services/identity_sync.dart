import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';
import 'http_client.dart';
import 'tracking_consent.dart';

/// Durable full identity snapshots. A later revision wins even if an older HTTP request arrives late.
class IdentitySync {
  static Future<void> _tail = Future.value();
  static Future<void> replace(
    AppReferHttpClient client,
    String deviceId,
    String? userId,
    Map<String, String> matching, {
    bool Function()? isCurrent,
    bool awaitDelivery = true,
  }) {
    final task = _tail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (isCurrent != null && !isCurrent()) return null;
      final revision =
          max(
            prefs.getInt('apprefer_identity_revision') ?? 0,
            DateTime.now().millisecondsSinceEpoch,
          ) +
          1;
      final body = {
        'device_id': deviceId,
        'revision': revision,
        'user_id': userId,
        'advanced_matching': userId == null ? <String, String>{} : matching,
      };
      if (!await prefs.setInt('apprefer_identity_revision', revision) ||
          !await prefs.setString('apprefer_identity_pending', jsonEncode(body)))
        throw StateError('Identity snapshot could not be persisted');
      return body;
    });
    _tail = task.then<void>((_) {}).catchError((Object _) {});
    return task.then((body) async {
      if (body == null) return;
      final send = _send(client, await SharedPreferences.getInstance(), body);
      if (awaitDelivery) {
        await send;
      } else {
        send.catchError((Object _) {});
      }
    });
  }

  static Future<void> retry(AppReferHttpClient client) {
    final task = _tail.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('apprefer_identity_pending');
      return raw == null
          ? null
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    });
    _tail = task.then<void>((_) {}).catchError((Object _) {});
    return task.then((body) async {
      if (body != null)
        await _send(client, await SharedPreferences.getInstance(), body);
    });
  }

  static Future<void> _send(
    AppReferHttpClient client,
    SharedPreferences prefs,
    Map<String, dynamic> body,
  ) async {
    final consent = await TrackingConsent.current();
    final wire = Map<String, dynamic>.from(body);
    if (!TrackingConsent.allowed(consent))
      wire['advanced_matching'] = <String, String>{};
    final response = await client.post(
      '/api/track/identity',
      wire,
      consent: consent,
      consentSnapshot: true,
    );
    final serverRevision = response?['revision'];
    if (serverRevision is int && serverRevision > (body['revision'] as int)) {
      // Do not reapply an old retry as a new login. A fresh authoritative host call may retry.
      if (prefs.getInt('apprefer_identity_revision') == body['revision']) {
        await prefs.setInt('apprefer_identity_revision', serverRevision);
      }
      throw StateError(
        'Identity revision conflict; retry current authoritative auth state',
      );
    }
    if (response?['revision'] == body['revision'] &&
        prefs.getInt('apprefer_identity_revision') == body['revision'])
      await prefs.remove('apprefer_identity_pending');
    if (response?['revision'] != body['revision']) {
      throw StateError(
        'Identity delivery not acknowledged; current snapshot remains queued',
      );
    }
    // Failure stays durable; next configure/resume retries the current snapshot only.
  }
}
