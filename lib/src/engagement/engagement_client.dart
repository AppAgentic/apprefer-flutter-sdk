import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../version.dart';

/// Where lifecycle engagement stands on this install.
enum AppReferEngagementState {
  /// `start()` hasn't run in this process.
  notStarted,

  /// Registered with AppRefer and verified ([AppReferEngagementStatus.installId]).
  active,

  /// Offline, secure storage unavailable or a server error: retried on resume and start.
  pending,

  /// Engagement is off for this app on the server; checked again after six hours.
  disabled,
}

class AppReferEngagementStatus {
  const AppReferEngagementStatus(this.state, [this.installId]);
  final AppReferEngagementState state;
  final String? installId;
  static const notStarted = AppReferEngagementStatus(
    AppReferEngagementState.notStarted,
  );
  static const pending = AppReferEngagementStatus(
    AppReferEngagementState.pending,
  );
  static const disabled = AppReferEngagementStatus(
    AppReferEngagementState.disabled,
  );
  bool get isActive => state == AppReferEngagementState.active;
  @override
  bool operator ==(Object other) =>
      other is AppReferEngagementStatus &&
      other.state == state &&
      other.installId == installId;
  @override
  int get hashCode => Object.hash(state, installId);
  @override
  String toString() =>
      installId == null ? state.name : '${state.name}($installId)';
}

/// The person's own choices per purpose; separate from the notification
/// permission and from tracking consent.
class AppReferEngagementPreferences {
  const AppReferEngagementPreferences({
    required this.marketing,
    required this.reminders,
    required this.service,
  });
  final bool marketing, reminders, service;
  @override
  bool operator ==(Object other) =>
      other is AppReferEngagementPreferences &&
      other.marketing == marketing &&
      other.reminders == reminders &&
      other.service == service;
  @override
  int get hashCode => Object.hash(marketing, reminders, service);
}

enum AppReferEngagementErrorReason {
  notStarted,
  disabled,
  identityChanged,
  invalidAssertion,
  unavailable,
  server,
}

class AppReferEngagementException implements Exception {
  AppReferEngagementException(this.reason, {this.status, this.code});
  final AppReferEngagementErrorReason reason;
  final int? status;
  final String? code;
  @override
  String toString() =>
      'AppReferEngagementException(${reason.name}${status == null ? '' : ', $status'}${code == null ? '' : ', $code'})';
}

/// What the event queue and notification handling read synchronously.
class EngagementSnapshot {
  const EngagementSnapshot(
    this.slot,
    this.installId,
    this.accountEpoch,
    this.serial,
    this.header,
    this.trackedEvents,
  );
  final String slot, installId, header;

  /// Null while an account change is in progress or unconfirmed.
  final int? accountEpoch;

  /// Advances on every reset, logout, sign-in, deletion and server-side account change.
  final int serial;
  final Set<String>? trackedEvents;

  /// Queued events carry this and get the header only while it is current. The epoch is part
  /// of it (and is sent as `X-AppRefer-Install-Epoch`), so an event queued under one account
  /// never matches after a cold start that learned another, and the server refuses it if the
  /// install moved on before the SDK knew.
  String get stamp => '$slot:$installId:$serial:${accountEpoch ?? '-'}';
}

class EngagementDeviceState {
  const EngagementDeviceState({
    required this.timezone,
    this.locale,
    required this.collectionEnabled,
    required this.permission,
  });
  final String timezone;
  final String? locale;
  final bool collectionEnabled;
  final String permission;
}

/// Small non-secret key-value store (SharedPreferences in the app).
abstract class EngagementPrefs {
  String? get(String key);
  Future<void> set(String key, String? value);
}

enum SecureReadStatus { found, missing, unavailable }

class SecureRead {
  const SecureRead(this.status, [this.value]);
  final SecureReadStatus status;
  final String? value;
}

/// The install credential's store: iOS Keychain or an Android Keystore-encrypted
/// file, through the plugin. Never SharedPreferences.
abstract class EngagementSecureStore {
  Future<SecureRead> read(String key);

  /// False when it couldn't be saved.
  Future<bool> write(String key, String value);
  Future<void> delete(String key);
}

class _Credential {
  _Credential(this.installId, this.secret, {this.pendingDelete = false});
  final String installId, secret;
  final bool pendingDelete;
  String encode() => jsonEncode({
    'installId': installId,
    'secret': secret,
    'pendingDelete': pendingDelete,
  });
  static _Credential? decode(String raw) {
    try {
      final m = jsonDecode(raw) as Map;
      return _Credential(
        m['installId'] as String,
        m['secret'] as String,
        pendingDelete: m['pendingDelete'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  _Credential markDeleted() =>
      _Credential(installId, secret, pendingDelete: true);
}

class _Receipt {
  _Receipt(
    this.slot,
    this.installId,
    this.accountEpoch,
    this.serial,
    this.messageId,
    this.token,
    this.kind,
    this.actionId,
    this.at,
    this.attempts,
  );
  final String slot, installId, messageId, token, kind;
  final int accountEpoch, serial, at, attempts;
  final String? actionId;
  Map<String, dynamic> toJson() => {
    'slot': slot,
    'installId': installId,
    'accountEpoch': accountEpoch,
    'serial': serial,
    'messageId': messageId,
    'token': token,
    'kind': kind,
    'actionId': actionId,
    'at': at,
    'attempts': attempts,
  };
  static _Receipt fromJson(Map m) => _Receipt(
    m['slot'] as String,
    m['installId'] as String,
    m['accountEpoch'] as int,
    m['serial'] as int,
    m['messageId'] as String,
    m['token'] as String,
    m['kind'] as String,
    m['actionId'] as String?,
    m['at'] as int,
    m['attempts'] as int,
  );
  _Receipt retried() => _Receipt(
    slot,
    installId,
    accountEpoch,
    serial,
    messageId,
    token,
    kind,
    actionId,
    at,
    attempts + 1,
  );
}

/// Lifecycle engagement client (contract: web/lib/engagement): registration,
/// credential storage, device state, preferences, account binding and
/// receipts. Every operation runs in call order on one chain, so a logout
/// never overtakes a sign-in that started before it; results arriving after a
/// reset, logout, sign-in or key switch are discarded (generation check).
class EngagementClient {
  EngagementClient({
    required this.secure,
    required this.prefs,
    required this.deviceState,
    http.Client Function()? client,
    this.baseUrl = 'https://apprefer.com',
    DateTime Function()? now,
    this.deviceId,
    this.identitySink,
    this.platform = 'ios',
    this.pushEnvironment,
  }) : _client = client ?? http.Client.new,
       _now = now ?? DateTime.now;

  final EngagementSecureStore secure;
  final EngagementPrefs prefs;
  final Future<EngagementDeviceState> Function() deviceState;
  final http.Client Function() _client;
  final String baseUrl;
  final DateTime Function() _now;
  final Future<String?> Function()? deviceId;

  /// Mirrors the identity to the native notification layer (epoch -1 = nothing matches).
  final Future<void> Function(String? installId, int epoch)? identitySink;
  final String platform;

  /// iOS: the APNs environment the app is signed for (0.10.1 detection).
  final Future<String> Function()? pushEnvironment;

  EngagementSnapshot? snapshot;
  AppReferEngagementStatus status = AppReferEngagementStatus.notStarted;
  String? _apiKey;
  bool _explicitKey = false;
  bool _started = false;
  Set<String>? _trackedEvents;
  bool _images = false;
  _Credential? _credential;
  int? _accountEpoch;
  String? _pushToken;
  int _generation = 0;
  bool _registrationRetried = false;
  Future<void> _tail = Future.value();

  bool get isStarted => _started;

  static String slotFor(String apiKey) =>
      sha256.convert(utf8.encode(apiKey)).toString().substring(0, 16);
  String? get _slot => _apiKey == null ? null : slotFor(_apiKey!);
  String _key(String name) => 'apprefer_engagement_${name}_${_slot ?? 'none'}';
  int get _serial => int.tryParse(prefs.get(_key('serial')) ?? '') ?? 0;
  Future<void> _setSerial(int v) => prefs.set(_key('serial'), '$v');
  bool get _pendingLogout => prefs.get(_key('pending_logout')) == '1';
  Future<void> _setPendingLogout(bool v) async {
    await prefs.set(_key('pending_logout'), v ? '1' : null);
    if (!v) await prefs.set(_key('pending_logout_epoch'), null);
  }

  /// The epoch a saved logout was made under (null: not known then).
  int? get _pendingLogoutEpoch =>
      int.tryParse(prefs.get(_key('pending_logout_epoch')) ?? '');

  /// Sets the epoch and persists it with the install id, so a cold start sees an epoch the
  /// server moved meanwhile.
  Future<void> _setEpoch(int? epoch) async {
    _accountEpoch = epoch;
    final c = _credential;
    if (epoch != null && c != null)
      await prefs.set(_key('epoch'), '${c.installId}:$epoch');
  }

  /// The epoch in memory, else the last one persisted for this install.
  int? get _knownEpoch {
    if (_accountEpoch != null) return _accountEpoch;
    final c = _credential;
    final parts = prefs.get(_key('epoch'))?.split(':');
    if (c == null ||
        parts == null ||
        parts.length != 2 ||
        parts[0] != c.installId)
      return null;
    return int.tryParse(parts[1]);
  }

  int get _disabledUntil =>
      int.tryParse(prefs.get(_key('disabled_until')) ?? '') ?? 0;
  static const _pendingLogoutAny = 'apprefer_engagement_pending_logout_any';
  static const _receiptsKey = 'apprefer_engagement_receipts';

  /// Runs [op] after every earlier operation finished.
  Future<T> _serially<T>(Future<T> Function() op) {
    final previous = _tail;
    final result = previous.then((_) => op());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> _publish() async {
    final c = _credential, slot = _slot;
    if (slot == null || c == null || c.pendingDelete || !status.isActive) {
      snapshot = null;
      await identitySink?.call(null, -1);
      return;
    }
    snapshot = EngagementSnapshot(
      slot,
      c.installId,
      _accountEpoch,
      _serial,
      '${c.installId}.${c.secret}',
      _trackedEvents,
    );
    await identitySink?.call(c.installId, _accountEpoch ?? -1);
  }

  Future<void> _beginIdentityChange() async {
    _generation++;
    await _setSerial(_serial + 1);
    _accountEpoch = null;
    await _dropReceipts((_) => true);
    await _publish();
  }

  // ---------------------------------------------------------------- start

  Future<AppReferEngagementStatus> start(
    String apiKey, {
    required bool explicit,
    Set<String>? trackedEvents,
    bool images = false,
  }) => _serially(() async {
    if (_apiKey != apiKey) {
      _generation++;
      _credential = null;
      _accountEpoch = null;
      _registrationRetried = false;
      status = AppReferEngagementStatus.pending;
      _apiKey = apiKey;
      await _publish();
    }
    _apiKey = apiKey;
    _explicitKey = explicit;
    _trackedEvents = trackedEvents;
    _images = images;
    _started = true;
    return _activate();
  });

  Future<void> configurationChanged(String apiKey) async {
    if (!_started || _explicitKey || apiKey == _apiKey) return;
    await start(
      apiKey,
      explicit: false,
      trackedEvents: _trackedEvents,
      images: _images,
    );
  }

  Future<void> becameActive() async {
    if (_started) await _serially(_activate);
  }

  Future<AppReferEngagementStatus> _activate() async {
    final key = _apiKey;
    if (key == null) return AppReferEngagementStatus.notStarted;
    if (_disabledUntil > _now().millisecondsSinceEpoch) {
      status = AppReferEngagementStatus.disabled;
      await _publish();
      return status;
    }
    final gen = _generation;
    if (_credential == null) {
      final read = await secure.read('apprefer_engagement_install_$_slot');
      if (read.status == SecureReadStatus.unavailable) {
        // Locked or failing: never mint a second install meanwhile.
        status = AppReferEngagementStatus.pending;
        await _publish();
        return status;
      }
      if (read.status == SecureReadStatus.found) {
        _credential = _Credential.decode(read.value!);
        if (_credential == null)
          await secure.delete('apprefer_engagement_install_$_slot');
      }
    }
    if (_credential?.pendingDelete == true && !await _sendDelete(key)) {
      status = AppReferEngagementStatus.pending;
      await _publish();
      return status;
    }
    if (_credential == null && !await _register(key, gen)) {
      await _publish();
      return status;
    }
    if (gen != _generation) return status;
    final c = _credential!;
    if (prefs.get(_pendingLogoutAny) == '1') {
      // Saved before this slot started in that process: it signs out of the identity this
      // slot last knew (persisted), never one the server moved to afterwards.
      final epoch = _knownEpoch;
      await prefs.set(_pendingLogoutAny, null);
      await _setPendingLogout(true);
      await prefs.set(_key('pending_logout_epoch'), epoch?.toString());
      await _setSerial(_serial + 1);
    }
    if (_pendingLogout) {
      var expected = _pendingLogoutEpoch;
      if (expected == null) {
        // Nothing was known about this install's identity when it was saved: sign out of
        // what is there now.
        final me = await _send('GET', '/api/engagement/v1/installs/me', key, c);
        if (gen != _generation) return status;
        final install = me.body?['install'];
        expected = me.status == 200 && install is Map
            ? _intOf(install['accountEpoch'])
            : null;
        if (expected == null) {
          if (!await _handleFailure(me))
            status = AppReferEngagementStatus.pending;
          await _publish();
          return status;
        }
      }
      final r = await _send(
        'POST',
        '/api/engagement/v1/installs/me/logout',
        key,
        c,
        body: {'expectedEpoch': expected},
      );
      if (gen != _generation) return status;
      if (r.status == 200) {
        await _setPendingLogout(false);
        await _setEpoch(_intOf(r.body?['accountEpoch']));
      } else if (r.status == 409) {
        // The install already left that identity (another sign-in or a backend change):
        // done, and the newer one stays.
        await _setPendingLogout(false);
      } else if (await _handleFailure(r)) {
        return status;
      } else {
        status = AppReferEngagementStatus.pending;
        await _publish();
        return status;
      }
    }
    final r = await _send('GET', '/api/engagement/v1/installs/me', key, c);
    if (gen != _generation) return status;
    final install = r.body?['install'];
    if (r.status != 200 || install is! Map) {
      if (r.status == 401 && !_registrationRetried) {
        _registrationRetried = true;
        await _forgetCredential();
        return _activate();
      }
      if (!await _handleFailure(r)) status = AppReferEngagementStatus.pending;
      await _publish();
      return status;
    }
    await _observeEpoch(_intOf(install['accountEpoch']));
    status = AppReferEngagementStatus(
      AppReferEngagementState.active,
      c.installId,
    );
    await _publish();
    await _syncDevice(false);
    await _flushReceipts();
    return status;
  }

  Future<void> _forgetCredential() async {
    if (_slot != null)
      await secure.delete('apprefer_engagement_install_$_slot');
    await prefs.set(_key('epoch'), null);
    _credential = null;
    _accountEpoch = null;
    await prefs.set(_key('sync_hash'), null);
    await _setSerial(_serial + 1);
    await _dropReceipts((_) => true);
    await _publish();
  }

  Future<bool> _register(String key, int gen) async {
    final state = await deviceState();
    final id = await deviceId?.call();
    final r = await _send(
      'POST',
      '/api/engagement/v1/installs',
      key,
      null,
      body: {
        'platform': platform,
        'timezone': state.timezone,
        'collectionEnabled': state.collectionEnabled,
        if (state.locale != null) 'locale': state.locale,
        if (id != null) 'deviceId': id,
      },
    );
    final installId = r.body?['installId'], secret = r.body?['installSecret'];
    if (r.status != 201 || installId is! String || secret is! String) {
      if (!await _handleFailure(r)) status = AppReferEngagementStatus.pending;
      return false;
    }
    final minted = _Credential(installId, secret);
    if (gen != _generation ||
        _apiKey != key ||
        !await secure.write(
          'apprefer_engagement_install_${slotFor(key)}',
          minted.encode(),
        )) {
      // Stale or unsaveable: an install nobody can use. Remove it.
      await _send('DELETE', '/api/engagement/v1/installs/me', key, minted);
      if (gen == _generation) status = AppReferEngagementStatus.pending;
      return false;
    }
    _credential = minted;
    await _setEpoch(0);
    await _setSerial(_serial + 1);
    await prefs.set(_key('sync_hash'), null);
    return true;
  }

  /// Server-side account changes (backend bind/unbind) also move the epoch. Compared with the
  /// last epoch known for this install, persisted across launches, so a change made while the
  /// app wasn't running still advances the serial and nothing queued for the old identity
  /// matches.
  Future<void> _observeEpoch(int? epoch) async {
    if (epoch == null) return;
    if (_knownEpoch != epoch) await _setSerial(_serial + 1);
    if (_accountEpoch != epoch) await _setEpoch(epoch);
  }

  /// True when handled as a terminal state (engagement disabled, invalid install).
  Future<bool> _handleFailure(_Response r) async {
    if (r.status == 404 && r.code == 'ENGAGEMENT_DISABLED') {
      await prefs.set(
        _key('disabled_until'),
        '${_now().millisecondsSinceEpoch + 6 * 3600000}',
      );
      status = AppReferEngagementStatus.disabled;
      await _publish();
      return true;
    }
    if (r.status == 401 && r.code == 'INVALID_INSTALL') {
      await _forgetCredential();
      status = AppReferEngagementStatus.pending;
      return true;
    }
    return false;
  }

  // ---------------------------------------------------------------- device state

  Future<void> setPushToken(String? token) => _serially(() async {
    _pushToken = token;
    await _syncDevice(false);
  });

  Future<void> refreshDeviceState() => _serially(() => _syncDevice(false));

  Future<void> _syncDevice(bool force) async {
    final key = _apiKey, c = _credential;
    if (key == null || c == null || !status.isActive) return;
    final gen = _generation;
    final state = await deviceState();
    final body = <String, dynamic>{
      'timezone': state.timezone,
      'collectionEnabled': state.collectionEnabled,
      'notificationPermission': state.permission,
      'capabilities': {'schema': 1, 'images': _images, 'actions': true},
      if (state.locale != null) 'locale': state.locale,
      if (_pushToken != null) 'pushToken': _pushToken,
      if (_pushToken != null && pushEnvironment != null)
        'pushEnvironment': await pushEnvironment!(),
    };
    final sorted = Map.fromEntries(
      body.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final hash = sha256.convert(utf8.encode(jsonEncode(sorted))).toString();
    final lastHash = prefs.get(_key('sync_hash'));
    final lastAt = int.tryParse(prefs.get(_key('sync_at')) ?? '') ?? 0;
    if (!force &&
        lastHash == hash &&
        _now().millisecondsSinceEpoch - lastAt < 86400000)
      return;
    final r = await _send(
      'PATCH',
      '/api/engagement/v1/installs/me',
      key,
      c,
      body: body,
    );
    if (gen != _generation) return;
    if (r.status == 200) {
      await prefs.set(_key('sync_hash'), hash);
      await prefs.set(_key('sync_at'), '${_now().millisecondsSinceEpoch}');
      final before = _serial;
      final install = r.body?['install'];
      await _observeEpoch(
        install is Map ? _intOf(install['accountEpoch']) : null,
      );
      if (before != _serial) await _publish();
    } else {
      await _handleFailure(r);
    }
  }

  // ---------------------------------------------------------------- identity

  Future<void> identify(String assertion) => _serially(() async {
    final key = _apiKey, c = _credential;
    if (!status.isActive || key == null || c == null)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.notStarted,
      );
    // The identity this sign-in replaces: the server refuses it (409) if that changed meanwhile.
    if (_knownEpoch == null) await _reverify(_generation);
    final expected = _knownEpoch;
    if (expected == null)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.unavailable,
      );
    await _beginIdentityChange();
    final gen = _generation;
    final r = await _send(
      'POST',
      '/api/engagement/v1/installs/me/account',
      key,
      c,
      body: {'assertion': assertion, 'expectedEpoch': expected},
    );
    if (gen != _generation)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.identityChanged,
      );
    final epoch = _intOf(r.body?['accountEpoch']);
    if (r.status == 200 && epoch != null) {
      await _setPendingLogout(false);
      await _setEpoch(epoch);
      await prefs.set(_key('sync_hash'), null);
      await _publish();
      await _syncDevice(true);
      return;
    }
    final error = r.status == 401 && r.code == 'INVALID_ASSERTION'
        ? AppReferEngagementException(
            AppReferEngagementErrorReason.invalidAssertion,
          )
        : _failure(r);
    if (!await _handleFailure(r)) await _reverify(gen);
    throw error;
  });

  Future<void> _reverify(int gen) async {
    final key = _apiKey, c = _credential;
    if (key == null || c == null) return;
    final r = await _send('GET', '/api/engagement/v1/installs/me', key, c);
    if (gen != _generation || r.status != 200) return;
    final install = r.body?['install'];
    await _observeEpoch(
      install is Map ? _intOf(install['accountEpoch']) : null,
    );
    await _publish();
  }

  /// Sign-out (or reset): messages planned for the account stop. Saved and sent
  /// first next time when offline, or when engagement isn't started yet.
  Future<void> logout() => _serially(() async {
    if (!_started || _credential == null) {
      await prefs.set(_pendingLogoutAny, '1');
      _generation++;
      return;
    }
    // Saved with the identity it signs out of (an older unsent logout keeps its own).
    final expected = _knownEpoch;
    await _beginIdentityChange();
    if (!_pendingLogout || _pendingLogoutEpoch == null) {
      await _setPendingLogout(true);
      await prefs.set(_key('pending_logout_epoch'), expected?.toString());
    }
    final key = _apiKey, c = _credential, epoch = _pendingLogoutEpoch;
    if (!status.isActive || key == null || c == null || epoch == null) return;
    final gen = _generation;
    final r = await _send(
      'POST',
      '/api/engagement/v1/installs/me/logout',
      key,
      c,
      body: {'expectedEpoch': epoch},
    );
    if (gen != _generation) return;
    if (r.status == 200) {
      await _setPendingLogout(false);
      await _setEpoch(_intOf(r.body?['accountEpoch']));
      await prefs.set(_key('sync_hash'), null);
      await _publish();
    } else if (r.status == 409) {
      // Already signed out of that identity on the server (a newer one is there): done.
      await _setPendingLogout(false);
      await _reverify(gen);
    } else {
      await _handleFailure(r);
    }
  });

  Future<void> deleteInstall() => _serially(() async {
    final key = _apiKey;
    if (key == null) return;
    if (_credential == null) {
      final read = await secure.read(
        'apprefer_engagement_install_${slotFor(key)}',
      );
      if (read.status == SecureReadStatus.found)
        _credential = _Credential.decode(read.value!);
    }
    final marked = _credential?.markDeleted();
    if (marked == null) return;
    await _beginIdentityChange();
    await prefs.set(_key('epoch'), null);
    _credential = marked;
    await secure.write(
      'apprefer_engagement_install_${slotFor(key)}',
      marked.encode(),
    );
    await _sendDelete(key);
    status = _credential == null
        ? AppReferEngagementStatus.notStarted
        : AppReferEngagementStatus.pending;
    _started = false;
    await _publish();
  });

  Future<bool> _sendDelete(String key) async {
    final c = _credential;
    if (c == null) return true;
    final r = await _send('DELETE', '/api/engagement/v1/installs/me', key, c);
    // 401: already gone. 404 disabled: nothing there can be sent.
    if (r.status != 200 && r.status != 401 && r.status != 404) return false;
    await secure.delete('apprefer_engagement_install_${slotFor(key)}');
    _credential = null;
    _accountEpoch = null;
    await _setPendingLogout(false);
    await prefs.set(_key('sync_hash'), null);
    return true;
  }

  // ---------------------------------------------------------------- preferences

  Future<AppReferEngagementPreferences> preferences() => _serially(() async {
    final key = _apiKey, c = _credential;
    if (!status.isActive || key == null || c == null)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.notStarted,
      );
    final gen = _generation;
    final r = await _send(
      'GET',
      '/api/engagement/v1/installs/me/preferences',
      key,
      c,
    );
    if (gen != _generation)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.identityChanged,
      );
    final prefs = _parsePreferences(r.body);
    final epoch = _intOf(r.body?['accountEpoch']);
    if (r.status == 200 && prefs != null && epoch != null) {
      // The choices are for the epoch they came with: learn it, so a later change is made for it.
      final before = _serial;
      await _observeEpoch(epoch);
      if (before != _serial) await _publish();
      return prefs;
    }
    await _handleFailure(r);
    throw _failure(r);
  });

  Future<AppReferEngagementPreferences> setPreferences(
    Map<String, bool> choices,
  ) => _serially(() async {
    if (choices.isEmpty)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.server,
        status: 400,
        code: 'INVALID_BODY',
      );
    final key = _apiKey, c = _credential;
    if (!status.isActive || key == null || c == null)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.notStarted,
      );
    // Only for the identity in use now: never mid sign-in or sign-out. The server refuses it
    // (409) if the install's identity is no longer this epoch.
    final epoch = _accountEpoch;
    if (epoch == null)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.identityChanged,
      );
    final gen = _generation;
    final r = await _send(
      'PUT',
      '/api/engagement/v1/installs/me/preferences',
      key,
      c,
      body: {...choices, 'expectedEpoch': epoch},
    );
    if (gen != _generation)
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.identityChanged,
      );
    if (r.status == 409) {
      await _reverify(gen);
      throw AppReferEngagementException(
        AppReferEngagementErrorReason.identityChanged,
      );
    }
    final prefs = _parsePreferences(r.body);
    if (r.status == 200 && prefs != null) return prefs;
    await _handleFailure(r);
    throw _failure(r);
  });

  static AppReferEngagementPreferences? _parsePreferences(
    Map<String, dynamic>? body,
  ) {
    final p = body?['purposes'];
    if (p is! Map) return null;
    bool? g(String n) => p[n] is Map ? (p[n] as Map)['granted'] as bool? : null;
    final m = g('marketing'), r = g('reminders'), s = g('service');
    if (m == null || r == null || s == null) return null;
    return AppReferEngagementPreferences(
      marketing: m,
      reminders: r,
      service: s,
    );
  }

  AppReferEngagementException _failure(_Response r) {
    final status = r.status;
    if (status == null)
      return AppReferEngagementException(
        AppReferEngagementErrorReason.unavailable,
      );
    if (status == 404 && r.code == 'ENGAGEMENT_DISABLED')
      return AppReferEngagementException(
        AppReferEngagementErrorReason.disabled,
      );
    if (status == 409)
      return AppReferEngagementException(
        AppReferEngagementErrorReason.identityChanged,
      );
    if (status >= 500 || status == 429)
      return AppReferEngagementException(
        AppReferEngagementErrorReason.unavailable,
      );
    return AppReferEngagementException(
      AppReferEngagementErrorReason.server,
      status: status,
      code: r.code,
    );
  }

  // ---------------------------------------------------------------- receipts

  List<_Receipt> _loadReceipts() {
    try {
      final raw = prefs.get(_receiptsKey);
      if (raw == null) return [];
      return (jsonDecode(raw) as List)
          .map((m) => _Receipt.fromJson(m as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveReceipts(List<_Receipt> items) async {
    final now = _now().millisecondsSinceEpoch;
    final fresh = items
        .where((r) => now - r.at < 7 * 86400000 && r.attempts < 10)
        .toList();
    await prefs.set(
      _receiptsKey,
      jsonEncode(
        (fresh.length > 100 ? fresh.sublist(fresh.length - 100) : fresh)
            .map((r) => r.toJson())
            .toList(),
      ),
    );
  }

  Future<void> _dropReceipts(bool Function(_Receipt) test) async =>
      _saveReceipts(_loadReceipts().where((r) => !test(r)).toList());

  int get pendingReceiptCount => _loadReceipts().length;

  /// Queues a receipt for a notification that matched this install and epoch.
  Future<void> queueReceipt({
    required String kind,
    required String messageId,
    required String token,
    required String installId,
    required int accountEpoch,
    String? actionId,
    required int at,
  }) async {
    final snap = snapshot;
    if (snap == null ||
        snap.installId != installId ||
        snap.accountEpoch != accountEpoch)
      return;
    final items = _loadReceipts();
    if (items.any((r) => r.messageId == messageId && r.kind == kind)) return;
    items.add(
      _Receipt(
        snap.slot,
        installId,
        accountEpoch,
        snap.serial,
        messageId,
        token,
        kind,
        actionId,
        at,
        0,
      ),
    );
    await _saveReceipts(items);
    await _serially(_flushReceipts);
  }

  Future<void> _flushReceipts() async {
    final key = _apiKey, c = _credential, slot = _slot, epoch = _accountEpoch;
    if (key == null ||
        c == null ||
        slot == null ||
        epoch == null ||
        !status.isActive)
      return;
    final gen = _generation;
    final serial = _serial;
    // An earlier identity's receipts are never sent under the current one.
    await _dropReceipts(
      (r) =>
          r.slot == slot &&
          (r.installId != c.installId ||
              r.accountEpoch != epoch ||
              r.serial != serial),
    );
    final batch = _loadReceipts()
        .where((r) => r.slot == slot)
        .take(20)
        .toList();
    if (batch.isEmpty) return;
    final r = await _send(
      'POST',
      '/api/engagement/v1/installs/me/receipts',
      key,
      c,
      body: {
        'receipts': [
          for (final x in batch)
            {
              'messageId': x.messageId,
              'token': x.token,
              'kind': x.kind,
              'occurredAt': x.at,
              if (x.actionId != null) 'actionId': x.actionId,
            },
        ],
      },
    );
    if (gen != _generation) return;
    bool sent(_Receipt x) => batch.any(
      (b) => b.messageId == x.messageId && b.kind == x.kind && b.slot == x.slot,
    );
    if (r.status == 200 || r.status == 400) {
      // Every answered item is final (accepted, duplicate or rejected); a malformed batch too.
      await _saveReceipts(_loadReceipts().where((x) => !sent(x)).toList());
      if (r.status == 200 && batch.length == 20) await _flushReceipts();
    } else if (!await _handleFailure(r)) {
      await _saveReceipts(
        _loadReceipts().map((x) => sent(x) ? x.retried() : x).toList(),
      );
    }
  }

  // ---------------------------------------------------------------- test and transport

  ({int? epoch, int serial, bool pendingLogout}) stateForTesting() =>
      (epoch: _accountEpoch, serial: _serial, pendingLogout: _pendingLogout);

  static int? _intOf(Object? v) => v is int ? v : (v is num ? v.toInt() : null);

  Future<_Response> _send(
    String method,
    String path,
    String key,
    _Credential? c, {
    Map<String, dynamic>? body,
  }) async {
    final client = _client();
    try {
      final request = http.Request(method, Uri.parse('$baseUrl$path'))
        ..headers['X-AppRefer-Key'] = key
        ..headers['X-SDK-Version'] = appReferVersion;
      if (c != null)
        request.headers['X-AppRefer-Install'] = '${c.installId}.${c.secret}';
      if (body != null) {
        request.headers['Content-Type'] = 'application/json';
        request.body = jsonEncode(body);
      }
      request.followRedirects = false;
      final response = await http.Response.fromStream(
        await client.send(request).timeout(const Duration(seconds: 15)),
      );
      Map<String, dynamic>? json;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) json = Map<String, dynamic>.from(decoded);
      } catch (_) {}
      return _Response(response.statusCode, json);
    } catch (_) {
      return const _Response(null, null);
    } finally {
      client.close();
    }
  }
}

class _Response {
  const _Response(this.status, this.body);
  final int? status;
  final Map<String, dynamic>? body;
  String? get code =>
      body?['error'] is Map ? (body!['error'] as Map)['code'] as String? : null;
}
