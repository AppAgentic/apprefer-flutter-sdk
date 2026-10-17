import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../services/registry.dart';
import '../services/storage.dart';
import 'support_help.dart';

String newSupportMessageId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

const supportChannel = MethodChannel('com.apprefer.sdk/support');

/// What kind of failure, so the chat can explain it in the customer's
/// language ([SupportException.message] stays English, for logs).
enum SupportErrorReason { server, locked, upload, unavailable, reset }

class SupportException implements Exception {
  final int status;

  /// The server's (or the SDK's) English message, for logs. The chat shows
  /// its own localized text instead (`SupportStrings.errorText`).
  final String message;
  final SupportErrorReason reason;
  SupportException(
    this.status,
    this.message, {
    this.reason = SupportErrorReason.server,
  });
  @override
  String toString() => message;
}

/// The app's AI support assistant, set in AppRefer. Every message from it is tagged "AI".
@immutable
class AppReferSupportPersona {
  const AppReferSupportPersona({
    required this.name,
    this.avatarUrl,
    this.handoffTo,
  });
  final String name;
  final String? avatarUrl;

  /// Who it passes conversations to ("Jay"); null means the team.
  final String? handoffTo;

  /// Null when the key is missing (older servers), null, or has no name.
  static AppReferSupportPersona? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final avatar = json['avatarUrl'], to = json['handoffTo'];
    return AppReferSupportPersona(
      name: name.trim(),
      avatarUrl: avatar is String && avatar.isNotEmpty ? avatar : null,
      handoffTo: to is String && to.trim().isNotEmpty ? to.trim() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppReferSupportPersona &&
      other.name == name &&
      other.avatarUrl == avatarUrl &&
      other.handoffTo == handoffTo;
  @override
  int get hashCode => Object.hash(name, avatarUrl, handoffTo);
}

/// The AI assistant's note that it passed the conversation to a person.
bool supportIsHandoff(Map<String, dynamic>? message) =>
    message?['handoff'] == true;

/// Customer-side API. Transport and token store can be injected in tests.
class SupportAPI {
  SupportAPI({
    http.Client? client,
    this.baseUrl = 'https://apprefer.com',
    Future<String?> Function(String)? read,
    Future<void> Function(String, String?)? write,
    Future<Map<String, dynamic>> Function()? profile,
    String? Function()? apiKey,
    Future<List<String>> Function()? keys,
    Future<bool> Function()? identityCleared,
    bool? isIOS,
    Future<String?> Function()? detectPushEnvironment,
  }) : _injectedClient = client != null,
       isIOS = isIOS ?? Platform.isIOS,
       _detectPushEnvironment =
           detectPushEnvironment ??
           (() => supportChannel.invokeMethod<String>('pushEnvironment')),
       client = client ?? http.Client(),
       read =
           read ?? ((key) => supportChannel.invokeMethod<String>('read', key)),
       write =
           write ??
           ((key, value) => supportChannel.invokeMethod<void>('write', {
             'key': key,
             'value': value,
           })),
       profile = profile ?? defaultProfile,
       // An injected profile owns the identity (tests, custom profiles).
       identityCleared =
           identityCleared ??
           (profile == null ? defaultIdentityCleared : () async => false),
       apiKey = apiKey ?? (() => AppReferRegistry.supportKey),
       keys =
           keys ??
           (() async =>
               await supportChannel.invokeListMethod<String>('keys') ?? []);
  final bool _injectedClient;
  final bool isIOS;
  http.Client client;

  /// 'production' or 'sandbox' set by the app (`AppReferSupport.pushEnvironment`);
  /// null reads it from the build's signing (iOS).
  String? pushEnvironmentOverride;
  final Future<String?> Function() _detectPushEnvironment;
  Future<String?>? _detectedPushEnvironment;

  /// The APNs environment tokens are registered for and readiness is checked
  /// against: the app's choice, else (iOS) the native plugin's reading of the
  /// embedded provisioning profile (development = sandbox; none, App Store or
  /// TestFlight = production; Simulator = sandbox). Android and a failed
  /// native read: production. Never throws.
  Future<String> pushEnvironment() async {
    final explicit = pushEnvironmentOverride;
    if (explicit != null) return explicit;
    if (!isIOS) return 'production';
    final pending = _detectedPushEnvironment ??= _detectOnce();
    final detected = await pending;
    // Unknown: not cached, the next call asks the plugin again.
    if (detected == null && identical(_detectedPushEnvironment, pending)) {
      _detectedPushEnvironment = null;
    }
    return pushEnvironmentOverride ?? detected ?? 'production';
  }

  Future<String?> _detectOnce() async {
    try {
      final value = await _detectPushEnvironment();
      if (value == 'sandbox' || value == 'production') return value;
    } catch (_) {}
    return null;
  }
  int _generation = 0;
  int get actionGeneration => _generation;
  final Future<List<String>> Function() keys;
  Future<void> _storageWork = Future.value();
  Future<void> _resetting = Future.value();
  final _invalidatedSlots = <String>{};
  Future<T> _store<T>(Future<T> Function() action) {
    final result = _storageWork.then((_) => action());
    _storageWork = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> reset() => _reset(keepPush: false);

  /// [keepPush] (clearIdentity): the current key's push token and its
  /// environment stay on the device, and the revocation is flagged to move
  /// the token to the new session once the old one is revoked.
  Future<void> _reset({required bool keepPush}) {
    _generation++;
    client.close();
    if (!_injectedClient) client = http.Client();
    _session = null;
    name = null;
    email = null;
    final currentKey = apiKey();
    _resetting = _store(() async {
      // A full reset: no pending push token move reaches the next account.
      if (!keepPush) await _dropMoves();
      final cleared = <String>{};
      final kept = keepPush && currentKey != null
          ? {'support_$currentKey.push', 'support_$currentKey.pushEnv'}
          : const <String>{};
      Future<void> clear(List<String> slots) async {
        for (final slot in slots) {
          if (!slot.startsWith('support_') ||
              cleared.contains(slot) ||
              kept.contains(slot))
            continue;
          if (slot.endsWith('.token')) {
            _invalidatedSlots.add(slot);
            final token = await _safeRead(slot);
            final prefix = slot.substring(0, slot.length - 6);
            if (token != null)
              _deferredRevocations.add(
                await _revocation(
                  token,
                  prefix.substring(8),
                  move: kept.contains('$prefix.push'),
                ),
              );
            await _saveRevocations();
          }
          try {
            await write(slot, null);
          } catch (_) {}
          cleared.add(slot);
        }
      }

      if (currentKey != null)
        await clear([
          'support_$currentKey.token',
          'support_$currentKey.profile',
          'support_$currentKey.push',
          'support_$currentKey.pushEnv',
          'support_$currentKey.cleared',
        ]);
      try {
        await clear(await keys());
      } catch (_) {}
      await _saveRevocations();
    }).catchError((Object _) {});
    return _resetting.then((_) {
      persona.value = null;
      resumeRevocations();
    });
  }

  /// Consent withdrawn: revokes the current session through the durable
  /// revocation list, exactly like [reset], and forgets name and email. The
  /// next request mints a new session from [profile], which then leaves the
  /// app user id and device id out, so it keeps no link to the old one. A
  /// registered push token stays on the device and moves to the new session
  /// only once the old session's revocation succeeded (a token saved without
  /// its environment, before 0.9.2, waits for the app to register it again).
  Future<void> clearIdentity() => _reset(keepPush: true);

  /// A revocation entry for [token] under [key]. With [move], the push token
  /// registered on that session moves to the current session once it is
  /// revoked, if its environment is known.
  Future<Map<String, dynamic>> _revocation(
    String token,
    String key, {
    required bool move,
  }) async {
    final push = await _safeRead('support_$key.push');
    final environment = push == null
        ? null
        : await _safeRead('support_$key.pushEnv');
    return {
      'token': token,
      'key': key,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'attempts': 0,
      if (push != null) 'push': push,
      if (move && push != null && environment != null) ...{
        'move': true,
        'environment': environment,
      },
    };
  }

  Future<void> _dropMoves() async {
    for (final v in _deferredRevocations) {
      v.remove('move');
      v.remove('environment');
    }
    try {
      final saved = _parseRevocations(await read('apprefer_revocations'));
      if (!saved.any((v) => v.containsKey('move'))) return;
      await write(
        'apprefer_revocations',
        jsonEncode([
          for (final v in saved)
            v
              ..remove('move')
              ..remove('environment'),
        ]),
      );
    } catch (_) {}
  }

  /// Whether [token] waits to move to the current session after an old
  /// session's revocation.
  Future<bool> pushMovePending(String token) async {
    try {
      final pending = await _store(_savedRevocations);
      return pending.any((v) => v['move'] == true && v['push'] == token);
    } catch (_) {
      return false;
    }
  }

  /// [token] is being registered while a pending revocation still holds it
  /// (moving or not, with or without a saved environment): saves it as the
  /// current key's push token, flags those revocations to move it with
  /// [environment] and returns true, so the revocation pass posts it to the
  /// current session once the old one is revoked. False (nothing changed)
  /// when no pending revocation of the current key holds it: post it now.
  Future<bool> deferPushRegistration(
    String token,
    int epoch, {
    required String environment,
  }) => _store(() async {
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    final key = apiKey();
    if (key == null) return false;
    bool holds(Map<String, dynamic> v) =>
        v['push'] == token && (v['key'] as String? ?? key) == key;
    final List<Map<String, dynamic>> saved;
    try {
      saved = _parseRevocations(await read('apprefer_revocations'));
    } catch (_) {
      return false;
    }
    final deferred = _deferredRevocations.where(holds).toList();
    if (!saved.any(holds) && deferred.isEmpty) return false;
    await write('support_$key.push', token);
    await write('support_$key.pushEnv', environment);
    for (final v in [...saved.where(holds), ...deferred]) {
      v['move'] = true;
      v['environment'] = environment;
    }
    if (saved.any(holds)) {
      await write('apprefer_revocations', jsonEncode(saved));
    }
    return true;
  });

  /// Registers [token] taken at [epoch] for [environment] (null: the effective
  /// [pushEnvironment]). The environment is resolved after the epoch was
  /// taken, so a reset or account switch while the plugin answers throws
  /// (reset) and nothing reaches the next account.
  Future<void> registerPushToken(
    String token,
    int epoch, {
    String? environment,
  }) async {
    environment ??= await pushEnvironment();
    if (await deferPushRegistration(token, epoch, environment: environment)) {
      // Still on a session being revoked (also a token saved before 0.9.2
      // without its environment): it moves once that revocation succeeded,
      // so the old and new sessions never hold it at the same time.
      resumeRevocations();
      return;
    }
    await call('POST', '/push-token', {
      'platform': isIOS ? 'ios' : 'android',
      'token': token,
      'environment': environment,
    }, epoch);
    await persistPushToken(token, epoch, environment: environment);
  }

  /// Registers a moved push token on the current session, only if it is
  /// still the one saved on the device (a reset since then cleared it, so it
  /// never reaches the next account). Failures are left to the app's next
  /// registration.
  Future<void> _movePush(Map<String, dynamic> item, String key) async {
    try {
      final token = item['push'];
      if (token is! String || apiKey() != key) return;
      final epoch = _generation;
      final saved = await _store(() => _safeRead('support_$key.push'));
      if (saved != token || epoch != _generation) return;
      final environment =
          await _store(() => _safeRead('support_$key.pushEnv')) ??
          (item['environment'] is String
              ? item['environment'] as String
              : null);
      if (environment == null) return;
      await call('POST', '/push-token', {
        'platform': isIOS ? 'ios' : 'android',
        'token': token,
        'environment': environment,
      }, epoch);
    } catch (_) {}
  }

  final _deferredRevocations = <Map<String, dynamic>>[];
  Future<String?> _safeRead(String slot) async {
    try {
      return await read(slot);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _parseRevocations(String? raw) {
    try {
      final value = jsonDecode(raw ?? '[]');
      if (value is! List) return [];
      return value
          .whereType<Map>()
          .where(
            (v) =>
                v['token'] is String &&
                (v['key'] == null || v['key'] is String) &&
                (v['push'] == null || v['push'] is String),
          )
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _savedRevocations() async {
    final result = _parseRevocations(await read('apprefer_revocations'));
    for (final item in _deferredRevocations) {
      if (!result.any(
        (v) => v['token'] == item['token'] && v['key'] == item['key'],
      ))
        result.add(item);
    }
    return result;
  }

  Future<void> _saveRevocations() async {
    try {
      final encoded = jsonEncode(await _savedRevocations());
      if (encoded != (await read('apprefer_revocations') ?? '[]')) {
        await write('apprefer_revocations', encoded);
      }
    } catch (_) {}
  }

  void resumeRevocations() {
    unawaited(_revokePending().catchError((Object _) {}));
  }

  Future<void>? _revoking;
  bool _revokeAgain = false;

  /// One pass at a time; a request during a pass (e.g. a session retired
  /// meanwhile) runs one more pass after it.
  Future<void> _revokePending() {
    final running = _revoking;
    if (running != null) {
      _revokeAgain = true;
      return running;
    }
    // The handle is set before the loop starts and cleared in the same step
    // that decides to stop, so a request can never land after the last
    // re-run check but before the handle is gone (it would be dropped).
    final pass = Completer<void>();
    _revoking = pass.future;
    () async {
      try {
        do {
          _revokeAgain = false;
          await _runRevocations();
        } while (_revokeAgain);
        _revoking = null;
        pass.complete();
      } catch (e, s) {
        _revoking = null;
        pass.completeError(e, s);
      }
    }();
    return pass.future;
  }

  Future<void> _runRevocations() async {
    final pending = await _store(_savedRevocations);
    for (final original in pending) {
      final item = Map<String, dynamic>.from(original);
      final created =
          (item['createdAt'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch;
      var attempts = (item['attempts'] as num?)?.toInt() ?? 0;
      item['createdAt'] = created;
      final key = item['key'] as String? ?? apiKey();
      var remove =
          DateTime.now().millisecondsSinceEpoch - created > 400 * 86400000 ||
          attempts >= 20;
      // Revoked (or already gone), not merely dropped for age or attempts.
      var revoked = false;
      if (!remove && key != null) {
        try {
          await _raw(
            'DELETE',
            '/session',
            null,
            item['token'] as String,
            keyOverride: key,
            timeout: const Duration(seconds: 5),
          );
          remove = revoked = true;
        } on SupportException catch (e) {
          remove = revoked = [401, 403, 404].contains(e.status);
        } catch (_) {
          /* Retry at the next lifecycle pass. */
        }
        if (!remove) {
          attempts++;
          remove = attempts >= 20;
        }
      }
      item['attempts'] = attempts;
      await _store(() async {
        final current = await _savedRevocations();
        // A registerPushToken during the attempt may have flagged the entry
        // to move its token: keep that, and act on it below.
        for (final v in current) {
          if (v['token'] == item['token'] &&
              v['key'] == item['key'] &&
              v['move'] == true) {
            item['move'] = true;
            item['environment'] = v['environment'];
          }
        }
        final remaining = current
            .expand(
              (v) => v['token'] == item['token'] && v['key'] == item['key']
                  ? (remove ? <Map<String, dynamic>>[] : [item])
                  : [v],
            )
            .toList();
        final encoded = jsonEncode(remaining);
        if (encoded != (await read('apprefer_revocations') ?? '[]')) {
          await write('apprefer_revocations', encoded);
        }
        _deferredRevocations.removeWhere(
          (v) => v['token'] == item['token'] && v['key'] == item['key'],
        );
      });
      if (revoked && item['move'] == true && key != null)
        await _movePush(item, key);
    }
  }

  final String baseUrl;
  final Future<String?> Function(String) read;
  final Future<void> Function(String, String?) write;
  final Future<Map<String, dynamic>> Function() profile;

  /// `AppReferSDK.support.clearIdentity()` is in effect (until the user id
  /// changes or reset() runs).
  final Future<bool> Function() identityCleared;
  final String? Function() apiKey;
  String? name, email;
  Future<String>? _session;

  /// The app's AI assistant from the latest list or conversation read (null
  /// when the app has none). The help screens listen to it.
  final ValueNotifier<AppReferSupportPersona?> persona = ValueNotifier(null);
  static Future<Map<String, dynamic>> defaultProfile() async {
    final storage = AppReferStorage();
    await storage.init();
    final cleared = await storage.isSupportIdentityCleared();
    return {
      // Only after configure in this process: never in Support-only apps, after
      // reset() (until configure runs again) or while collection is off. Never
      // after clearIdentity() either: attribution maps the device id to the
      // old account.
      if (!cleared &&
          AppReferRegistry.installLinkAllowed(storage) &&
          storage.existingDeviceId() != null)
        'deviceId': storage.existingDeviceId(),
      // Left out after clearIdentity() until the user id changes.
      if (!cleared && storage.getUserId() != null)
        'appUserId': storage.getUserId(),
    };
  }

  /// Throws a retryable [SupportException] while the secure store can't be
  /// read (e.g. before first unlock): no session is minted or adopted under
  /// an unknown flag, so a session is never marked "minted while cleared" by
  /// mistake and later retired.
  static Future<bool> defaultIdentityCleared() async {
    final storage = AppReferStorage();
    await storage.init();
    final cleared = await storage.supportIdentityClearedState();
    if (cleared == null) {
      throw SupportException(
        0,
        'Support storage is unavailable; try again.',
        reason: SupportErrorReason.locked,
      );
    }
    return cleared;
  }

  Future<Map<String, dynamic>> _raw(
    String method,
    String path,
    Map<String, dynamic>? body,
    String? token, {
    String? keyOverride,
    int? expectedGeneration,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final epoch = expectedGeneration ?? _generation;
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    final key = keyOverride ?? apiKey();
    if (key == null)
      throw SupportException(
        0,
        'Configure AppRefer before opening support.',
        reason: SupportErrorReason.unavailable,
      );
    final request = http.Request(
      method,
      Uri.parse('$baseUrl/api/support/v1$path'),
    );
    request.headers['X-AppRefer-Key'] = key;
    if (token != null) request.headers['X-AppRefer-Support-Session'] = token;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await client.send(request).timeout(timeout),
    );
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    Map<String, dynamic> data = {};
    try {
      if (response.body.isNotEmpty)
        data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      /* HTTP error below */
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SupportException(
        response.statusCode,
        '${data['error'] ?? data['message'] ?? 'Unable to connect (${response.statusCode})'}',
      );
    }
    return data;
  }

  Future<void> ensureSession() async {
    await call('GET', '/conversations');
  }

  Future<String> _token() {
    final epoch = _generation;
    return _session ??= _ensure().whenComplete(() {
      if (epoch == _generation) _session = null;
    });
  }

  Future<String> _ensure() async {
    final epoch = _generation;
    final prefix = 'support_${apiKey()}';
    final cleared = await identityCleared();
    final p = await profile();
    p.addAll({
      if (name != null) 'name': name,
      if (email != null) 'email': email,
    });
    final fingerprint = jsonEncode(p);
    await _resetting;
    var token = await _store(() => read('$prefix.token'));
    final pending = await _savedRevocations();
    if (_invalidatedSlots.contains('$prefix.token') ||
        pending.any((item) => item['token'] == token))
      token = null;
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    if (token != null && !cleared && await read('$prefix.cleared') == '1') {
      // Minted while the identity was cleared, and a different user id has
      // been stored since without reset(): never hand it to that account.
      await _retireClearedSession(prefix, token, epoch);
      token = null;
    }
    if (token == null || await read('$prefix.profile') != fingerprint) {
      final response = await _raw(
        'POST',
        '/session',
        p,
        token,
        expectedGeneration: epoch,
      );
      token = response['session'] as String? ?? token;
      if (token == null || token.isEmpty)
        throw SupportException(0, 'Invalid support session');
      if (epoch != _generation)
        throw SupportException(
          0,
          'Support reset',
          reason: SupportErrorReason.reset,
        );
      await _store(() async {
        if (epoch != _generation)
          throw SupportException(
            0,
            'Support reset',
            reason: SupportErrorReason.reset,
          );
        await write('$prefix.token', token);
        _invalidatedSlots.remove('$prefix.token');
        await write('$prefix.profile', fingerprint);
        await write('$prefix.cleared', cleared ? '1' : null);
      });
    }
    return token;
  }

  /// Revokes a session minted while the identity was cleared (durably, with
  /// its push token flagged to move) and forgets it locally, without
  /// cancelling in-flight calls or forgetting name and email.
  Future<void> _retireClearedSession(
    String prefix,
    String token,
    int epoch,
  ) async {
    await _store(() async {
      if (epoch != _generation)
        throw SupportException(
          0,
          'Support reset',
          reason: SupportErrorReason.reset,
        );
      _deferredRevocations.add(
        await _revocation(token, prefix.substring(8), move: true),
      );
      await _saveRevocations();
      // Only the session it retired: a token saved meanwhile stays.
      if (await _safeRead('$prefix.token') != token) return;
      for (final slot in ['.token', '.profile', '.cleared']) {
        try {
          await write('$prefix$slot', null);
        } catch (_) {}
      }
    });
    resumeRevocations();
  }

  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
    int? expectedGeneration,
  ]) async {
    final epoch = expectedGeneration ?? _generation;
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    await _resetting;
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    for (var attempt = 0; ; attempt++) {
      try {
        final token = await _token();
        if (epoch != _generation)
          throw SupportException(
            0,
            'Support reset',
            reason: SupportErrorReason.reset,
          );
        return await _raw(method, path, body, token, expectedGeneration: epoch);
      } on SupportException catch (e) {
        if (epoch != _generation) rethrow;
        if (attempt != 0 ||
            e.status != 401 ||
            !e.message.toLowerCase().contains('support session'))
          rethrow;
        await write('support_${apiKey()}.token', null);
        await write('support_${apiKey()}.cleared', null);
      }
    }
  }

  Future<void> persistPushToken(
    String? token,
    int epoch, {
    String? environment,
  }) => _store(() async {
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    await write('support_${apiKey()}.push', token);
    // Kept so clearIdentity() re-registers the token for the same APNs
    // environment after a relaunch.
    await write(
      'support_${apiKey()}.pushEnv',
      token == null ? null : environment,
    );
  });

  /// Whether this install has registered for reply notifications.
  Future<bool> hasPushToken() async =>
      apiKey() != null && await _safeRead('support_${apiKey()}.push') != null;

  /// Help centre and status: SDK key only, no session (support_help.dart).
  late final SupportHelpClient help = SupportHelpClient(
    client: () => client,
    apiKey: apiKey,
    baseUrl: baseUrl,
    isIOS: isIOS,
    pushEnvironment: pushEnvironment,
  );

  Future<List<Map<String, dynamic>>> conversations() async {
    final epoch = _generation;
    final list = await call('GET', '/conversations');
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    persona.value = AppReferSupportPersona.fromJson(list['persona']);
    return List<Map<String, dynamic>>.from(list['conversations']);
  }

  Future<Map<String, dynamic>> thread(String id, {String? after}) async {
    final epoch = _generation;
    final thread = await call(
      'GET',
      '/conversations/${Uri.encodeComponent(id)}${after == null ? '' : '?after=${Uri.encodeQueryComponent(after)}'}',
    );
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    persona.value = AppReferSupportPersona.fromJson(thread['persona']);
    return thread;
  }

  Future<Map<String, dynamic>> start(
    String text,
    List<String> ids,
    Map<String, dynamic> context, {
    required String clientMessageId,
    String? subject,
    int? generation,
  }) => call('POST', '/conversations', {
    'text': text,
    if (subject != null && subject.isNotEmpty) 'subject': subject,
    if (ids.isNotEmpty) 'attachmentIds': ids,
    'context': context,
    'clientMessageId': clientMessageId,
  }, generation);
  Future<Map<String, dynamic>> send(
    String id,
    String text,
    List<String> ids, {
    required String clientMessageId,
    int? generation,
  }) async => Map<String, dynamic>.from(
    (await call('POST', '/conversations/${Uri.encodeComponent(id)}/messages', {
      'text': text,
      'clientMessageId': clientMessageId,
      if (ids.isNotEmpty) 'attachmentIds': ids,
    }, generation))['message'],
  );
  Future<String> upload(Uint8List jpeg, {int? generation}) async {
    final epoch = generation ?? _generation;
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    final slot = await call('POST', '/attachments', {
      'contentType': 'image/jpeg',
      'size': jpeg.length,
      'name': 'screenshot.jpg',
    }, epoch);
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    final response = await client
        .put(
          Uri.parse(slot['uploadUrl'] as String),
          headers: Map<String, String>.from(slot['headers']),
          body: jpeg,
        )
        .timeout(const Duration(seconds: 60));
    if (epoch != _generation)
      throw SupportException(
        0,
        'Support reset',
        reason: SupportErrorReason.reset,
      );
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw SupportException(
        response.statusCode,
        'The screenshot did not upload. Try again.',
        reason: SupportErrorReason.upload,
      );
    return slot['attachmentId'] as String;
  }
}
