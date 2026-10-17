import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/registry.dart';
import '../support/support_strings.dart';
import 'engagement_client.dart';
import 'engagement_payload.dart';

export 'engagement_client.dart'
    show
        AppReferEngagementState,
        AppReferEngagementStatus,
        AppReferEngagementPreferences,
        AppReferEngagementErrorReason,
        AppReferEngagementException;
export 'engagement_payload.dart';

const engagementChannel = MethodChannel('com.apprefer.sdk/engagement');

/// Body key a queued product event keeps its engagement stamp under (removed before sending).
const engagementStampKey = '_apprefer_engagement_stamp';

/// Options for [AppReferEngagement.start].
class AppReferEngagementOptions {
  const AppReferEngagementOptions({
    this.trackedEvents,
    this.allowedImageHosts = const {},
    this.androidSmallIcon,
    this.appGroup,
    this.notificationServiceExtension = false,
  });

  /// Product events that carry the engagement credential (null = every event; `_` names never).
  final Set<String>? trackedEvents;

  /// Android: exact host names notification images may come from (empty = text only).
  final Set<String> allowedImageHosts;

  /// Android: a monochrome drawable resource name for notifications (null = the app icon).
  final String? androidSmallIcon;

  /// iOS: the App Group shared with your Notification Service Extension.
  final String? appGroup;

  /// iOS: set when the app ships the Notification Service Extension with `AppReferNotificationService`.
  final bool notificationServiceExtension;
}

/// Something that happened to an AppRefer notification, delivered once.
class AppReferEngagementNotificationEvent {
  const AppReferEngagementNotificationEvent({
    required this.kind,
    required this.messageId,
    required this.purpose,
    this.destination,
    this.actionId,
    this.actionKind,
  });

  /// `received`, `opened`, `action`, `snoozed` or `dismissed`.
  final String kind;
  final String messageId;
  final String purpose;

  /// In-app path for `opened` and `action`; your app maps it to a screen (null = default screen).
  final String? destination;
  final String? actionId;
  final String? actionKind;

  /// Navigation events wait for [AppReferEngagement.setNavigationReady] and are dropped after an account change.
  bool get isNavigation => kind == 'opened' || kind == 'action';

  @override
  String toString() =>
      'AppReferEngagementNotificationEvent($kind, $messageId, $destination, $actionId)';
}

class _SharedPrefs implements EngagementPrefs {
  _SharedPrefs(this.prefs);
  final SharedPreferences prefs;
  @override
  String? get(String key) => prefs.getString(key);
  @override
  Future<void> set(String key, String? value) async {
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }
}

class _ChannelSecureStore implements EngagementSecureStore {
  @override
  Future<SecureRead> read(String key) async {
    try {
      final value = await engagementChannel.invokeMethod<String>(
        'secureRead',
        key,
      );
      return value == null
          ? const SecureRead(SecureReadStatus.missing)
          : SecureRead(SecureReadStatus.found, value);
    } catch (_) {
      return const SecureRead(SecureReadStatus.unavailable);
    }
  }

  @override
  Future<bool> write(String key, String value) async {
    try {
      await engagementChannel.invokeMethod<void>('secureWrite', {
        'key': key,
        'value': value,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> delete(String key) async {
    try {
      await engagementChannel.invokeMethod<void>('secureWrite', {
        'key': key,
        'value': null,
      });
    } catch (_) {}
  }
}

/// AppRefer lifecycle engagement: registers this install (only when your app
/// calls [start]), keeps its push token, time zone, language and permission
/// current, records the person's own choices per purpose, binds the install to
/// an account only with an assertion from your backend, and hands AppRefer's
/// notifications to the native layer (Android renders them; iOS shows them and
/// your Notification Service Extension adds images). Separate from Support:
/// Support tokens and `support_reply` messages never enroll anyone. Nothing
/// here asks for a permission.
class AppReferEngagement {
  AppReferEngagement._();
  static final AppReferEngagement instance = AppReferEngagement._();

  EngagementClient? _client;
  AppReferEngagementOptions _options = const AppReferEngagementOptions();
  final List<(AppReferEngagementNotificationEvent, Map)> _pending = [];
  bool _ready = false;
  bool _channelAttached = false;
  void Function(AppReferEngagementNotificationEvent event)? _handler;

  /// Tests: replaces the client (and its transport and stores).
  static void setClientForTesting(EngagementClient? client) {
    instance._client = client;
    instance._pending.clear();
    instance._ready = false;
  }

  Future<EngagementClient> _ensureClient() async {
    if (_client != null) return _client!;
    final prefs = await SharedPreferences.getInstance();
    return _client = EngagementClient(
      secure: _ChannelSecureStore(),
      prefs: _SharedPrefs(prefs),
      platform: Platform.isIOS ? 'ios' : 'android',
      deviceState: () async => EngagementDeviceState(
        timezone:
            await _nativeString('timezone') ?? DateTime.now().timeZoneName,
        locale: _locale(),
        collectionEnabled:
            prefs.getBool('apprefer_collection_enabled') != false,
        permission: await _nativeString('permission') ?? 'unknown',
      ),
      deviceId: AppReferRegistry.linkableDeviceId,
      identitySink: (iid, epoch) async {
        try {
          await engagementChannel.invokeMethod<void>('setIdentity', {
            'installId': iid,
            'accountEpoch': epoch,
            'appGroup': _options.appGroup,
          });
        } catch (_) {}
      },
      pushEnvironment: Platform.isIOS
          ? () async =>
                await const MethodChannel(
                  'com.apprefer.sdk/support',
                ).invokeMethod<String>('pushEnvironment') ??
                'production'
          : null,
    );
  }

  static String? _locale() {
    final tag = PlatformDispatcher.instance.locale.toLanguageTag();
    return RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$').hasMatch(tag)
        ? tag
        : null;
  }

  static Future<String?> _nativeString(String method) async {
    try {
      return await engagementChannel.invokeMethod<String>(method);
    } catch (_) {
      return null;
    }
  }

  void _attachChannel() {
    if (_channelAttached) return;
    _channelAttached = true;
    engagementChannel.setMethodCallHandler((call) async {
      if (call.method == 'eventsAvailable') await drain();
      return null;
    });
  }

  /// Registers this install for lifecycle engagement (once; the credential is in
  /// the iOS Keychain or encrypted with an Android Keystore key) and verifies
  /// it, with the key passed to `AppReferSDK.configure` unless you pass one.
  /// Also registers the native notification buttons and channels in the app's
  /// language. Never prompts.
  Future<AppReferEngagementStatus> start({
    String? apiKey,
    AppReferEngagementOptions options = const AppReferEngagementOptions(),
  }) async {
    final key = apiKey ?? AppReferRegistry.apiKey;
    if (key == null) return AppReferEngagementStatus.notStarted;
    _options = options;
    _attachChannel();
    try {
      await engagementChannel.invokeMethod<void>('configureNotifications', {
        'labels': {
          for (final k in AppReferEngagementPayload.kinds)
            k: SupportStrings.text('engagement.action.$k'),
        },
        'channels': {
          for (final p in AppReferEngagementPayload.purposes)
            p: SupportStrings.text('engagement.channel.$p'),
        },
        'allowedImageHosts': options.allowedImageHosts
            .where(AppReferEngagementPayload.isHost)
            .toList(),
        'smallIcon': options.androidSmallIcon,
        'appGroup': options.appGroup,
      });
    } catch (_) {}
    final client = await _ensureClient();
    final status = await client.start(
      key,
      explicit: apiKey != null,
      trackedEvents: options.trackedEvents,
      images: Platform.isIOS
          ? options.notificationServiceExtension
          : options.allowedImageHosts.isNotEmpty,
    );
    await drain();
    return status;
  }

  AppReferEngagementStatus get status =>
      _client?.status ?? AppReferEngagementStatus.notStarted;

  /// The push token: FCM registration token on Android, the APNs device token
  /// (hex) on iOS. Sent for the APNs environment the app is signed for.
  Future<void> setPushToken(String? token) async =>
      _client?.setPushToken(token);

  /// Re-reads permission, time zone and language (call after your own permission request).
  Future<void> refreshDeviceState() async => _client?.refreshDeviceState();

  /// `granted`, `provisional`, `denied` or `unknown`. Never prompts.
  Future<String> notificationPermission() async =>
      await _nativeString('permission') ?? 'unknown';

  /// Android 8+: whether the purpose's channel is on; null when unknown (and on iOS).
  Future<bool?> channelEnabled(String purpose) async {
    try {
      return await engagementChannel.invokeMethod<bool>(
        'channelEnabled',
        purpose,
      );
    } catch (_) {
      return null;
    }
  }

  Future<AppReferEngagementPreferences> preferences() async {
    final c = _client;
    if (c == null)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.notStarted,
      );
    return c.preferences();
  }

  /// Saves the person's own choices (only the ones you pass) for the identity in use now.
  Future<AppReferEngagementPreferences> setPreferences({
    bool? marketing,
    bool? reminders,
    bool? service,
  }) async {
    final c = _client;
    if (c == null)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.notStarted,
      );
    return c.setPreferences({
      if (marketing != null) 'marketing': marketing,
      if (reminders != null) 'reminders': reminders,
      if (service != null) 'service': service,
    });
  }

  /// Binds this install to the signed-in account with an assertion from your
  /// backend; a user id alone is never accepted.
  Future<void> identify(String assertion) async {
    await _resetForAccountChange();
    final c = _client;
    if (c == null)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.notStarted,
      );
    await c.identify(assertion);
  }

  /// Sign-out (also done by `AppReferSDK.reset()`): messages planned for the
  /// account stop. Saved and sent later when offline.
  Future<void> logout() async {
    await _resetForAccountChange();
    await (await _ensureClient()).logout();
  }

  /// Forgets this install's engagement registration here and on the server.
  Future<void> deleteInstall() async {
    await _resetForAccountChange();
    await _client?.deleteInstall();
  }

  Future<void> _resetForAccountChange() async {
    _pending.clear();
    try {
      await engagementChannel.invokeMethod<void>('clearForAccountChange');
    } catch (_) {}
  }

  /// Android: from your FCM handler (`FirebaseMessaging.onMessage` and the
  /// background handler): shows AppRefer's notification natively and returns
  /// true; false for anything else (Support replies, your own messages).
  /// iOS: true when it is AppRefer's (iOS shows it; nothing else to do).
  Future<bool> handleMessage(Map<String, dynamic> data) async {
    if (!AppReferEngagementPayload.isEngagement(data) &&
        !(data['apprefer'] is Map &&
            (data['apprefer'] as Map)['type'] == 'engagement'))
      return false;
    if (Platform.isAndroid) {
      try {
        await engagementChannel.invokeMethod<String>(
          'showNotification',
          data.map((k, v) => MapEntry(k, '$v')),
        );
      } catch (_) {}
    }
    await drain();
    return true;
  }

  /// Opened notifications, buttons, snoozes, dismissals and receipts, each once.
  set onNotificationEvent(
    void Function(AppReferEngagementNotificationEvent event)? handler,
  ) {
    _handler = handler;
    _deliver();
  }

  /// Call with true once your app knows who is signed in and can show screens.
  void setNavigationReady(bool ready) {
    _ready = ready;
    _deliver();
  }

  /// Moves the native layer's recorded outcomes into receipts and events.
  Future<void> drain() async {
    final c = _client;
    if (c == null) return;
    List<Object?> events;
    try {
      events =
          await engagementChannel.invokeListMethod<Object?>('takeEvents') ??
          const [];
    } catch (_) {
      return;
    }
    for (final raw in events) {
      if (raw is! Map) continue;
      final kind = raw['kind'];
      if (kind is! String ||
          !const [
            'received',
            'opened',
            'action',
            'snoozed',
            'dismissed',
          ].contains(kind))
        continue;
      final dest = raw['destination'];
      final event = AppReferEngagementNotificationEvent(
        kind: kind,
        messageId: '${raw['messageId']}',
        purpose: '${raw['purpose']}',
        destination: AppReferEngagementPayload.isDestination(dest)
            ? dest as String
            : null,
        actionId: raw['actionId'] as String?,
        actionKind: raw['actionKind'] as String?,
      );
      final epoch = raw['accountEpoch'];
      unawaited(
        c.queueReceipt(
          kind: kind == 'snoozed' ? 'snooze' : kind,
          messageId: event.messageId,
          token: '${raw['receiptToken']}',
          installId: '${raw['installId']}',
          accountEpoch: epoch is num ? epoch.toInt() : -1,
          actionId: event.actionId,
          at:
              (raw['at'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
      );
      _pending.add((event, raw));
      if (_pending.length > 20) _pending.removeAt(0);
    }
    _deliver();
  }

  void _deliver() {
    final handler = _handler;
    if (handler == null) return;
    final now = <(AppReferEngagementNotificationEvent, Map)>[];
    _pending.removeWhere((item) {
      if (item.$1.isNavigation && !_ready) return false;
      now.add(item);
      return true;
    });
    for (final (event, raw) in now) {
      if (stillDeliverable(event, raw, _client?.snapshot, _clock()))
        handler(event);
    }
  }

  /// The clock deferred events are checked with (tests replace it).
  @visibleForTesting
  DateTime Function() clock = DateTime.now;
  int _clock() => clock().millisecondsSinceEpoch;

  /// Re-checked at delivery, with the real clock: an event whose notification expired while it
  /// waited (navigation not ready, no handler yet) is dropped, and navigation also needs a known
  /// expiry and the same install and account it was tapped under.
  @visibleForTesting
  static bool stillDeliverable(
    AppReferEngagementNotificationEvent event,
    Map raw,
    EngagementSnapshot? snap,
    int nowMs,
  ) {
    final exp = raw['expiresAt'];
    if (exp is num && nowMs >= exp) return false;
    if (!event.isNavigation) return true;
    return exp is num &&
        snap != null &&
        snap.installId == raw['installId'] &&
        snap.accountEpoch == raw['accountEpoch'];
  }

  /// The stamp a new product event carries (never the credential).
  String? eventStamp(String eventName, String apiKey) {
    final snap = _client?.snapshot;
    if (snap == null ||
        eventName.startsWith('_') ||
        snap.accountEpoch == null ||
        snap.slot != EngagementClient.slotFor(apiKey))
      return null;
    if (snap.trackedEvents != null && !snap.trackedEvents!.contains(eventName))
      return null;
    return snap.stamp;
  }

  /// The headers for a queued event, only while its stamp is current: the credential and the
  /// account epoch the event was queued under.
  Map<String, String>? headersFor(Object? stamp) {
    final snap = _client?.snapshot;
    final epoch = snap?.accountEpoch;
    return stamp is String &&
            snap != null &&
            epoch != null &&
            snap.stamp == stamp
        ? {
            'X-AppRefer-Install': snap.header,
            'X-AppRefer-Install-Epoch': '$epoch',
          }
        : null;
  }

  Future<void> configurationChanged(String apiKey) async =>
      _client?.configurationChanged(apiKey);
  Future<void> becameActive() async {
    await _client?.becameActive();
    await drain();
  }

  Future<void> collectionChanged() async => _client?.refreshDeviceState();
}
