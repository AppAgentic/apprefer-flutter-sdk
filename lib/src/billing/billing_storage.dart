import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'billing_error.dart';
import 'customer_info.dart';

/// A login that still has to be sent to `/identify`.
typedef PendingIdentify = ({String anonymousId, String appUserId});

/// Persistent billing state in SharedPreferences (NSUserDefaults / Android
/// SharedPreferences on disk). Owned by `BillingEngine`.
class BillingStorage {
  static const anonymousPrefix = r'$ARAnon:';

  static const _anonymousId = 'apprefer_billing_anonymous_id';
  static const _appUserId = 'apprefer_billing_app_user_id';
  static const _accountTokens = 'apprefer_billing_account_tokens';
  static const _pendingAttributes = 'apprefer_billing_pending_attributes';
  static const _learnedEntitlements = 'apprefer_billing_learned_entitlements';
  static const _pendingIdentify = 'apprefer_billing_pending_identify';
  static const _pendingIdentifies = 'apprefer_billing_pending_identifies';
  static const _customerInfo = 'apprefer_billing_customer_info';
  static const _productKinds = 'apprefer_billing_product_kinds';
  static const pendingPurchasesKey = 'apprefer_billing_pending_purchases';

  final SharedPreferences prefs;

  /// Identity writes not yet confirmed on disk, by key, with how to redo
  /// each one. A newer write to a key replaces the older one, so a failed
  /// stale write is never redone over a newer value.
  final _pendingWrites = <String, (Future<bool>, Future<bool> Function())>{};

  /// The one flush running now; every caller waits on it.
  Future<bool>? _flushing;

  BillingStorage(this.prefs);

  static bool isAnonymous(String appUserId) =>
      appUserId.startsWith(anonymousPrefix);

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool isUuid(String value) => _uuid.hasMatch(value);

  // --- Identity ---

  /// Reads an identity value. Missing returns null; a value that can't be
  /// read throws [AppReferBillingErrorCode.storage], so a caller never mints a
  /// new identity in place of one it merely failed to read.
  String? _readIdentity(String key) {
    try {
      return prefs.getString(key);
    } catch (e) {
      throw AppReferBillingException(
        AppReferBillingErrorCode.storage,
        message: 'could not read $key: $e',
      );
    }
  }

  bool get hasAnonymousId => _readIdentity(_anonymousId) != null;

  /// `$ARAnon:<UUID>`, minted once and kept for the install. Minted only
  /// when the read confirms there is none (or what is stored is not an
  /// anonymous id); throws [AppReferBillingErrorCode.storage] when the stored
  /// id can't be read. A minted id is in memory until [flush] confirms it on
  /// disk, and `BillingEngine` sends or binds nothing under it before then.
  String anonymousId() {
    final existing = _readIdentity(_anonymousId);
    if (existing != null && isAnonymous(existing)) return existing;
    return resetAnonymousId();
  }

  String resetAnonymousId() {
    final id = '$anonymousPrefix${generateUuidV4().toUpperCase()}';
    _write(_anonymousId, () => prefs.setString(_anonymousId, id));
    return id;
  }

  /// The logged-in app user id, or null while anonymous. Throws
  /// [AppReferBillingErrorCode.storage] when it can't be read.
  String? get loggedInAppUserId => _readIdentity(_appUserId);

  set loggedInAppUserId(String? value) {
    if (value == null) {
      _write(_appUserId, () => prefs.remove(_appUserId));
    } else {
      _write(_appUserId, () => prefs.setString(_appUserId, value));
    }
  }

  String get currentAppUserId => loggedInAppUserId ?? anonymousId();

  /// SharedPreferences updates its in-memory copy at once and writes to disk
  /// later; the write's result is kept so [flush] can check it.
  void _write(String key, Future<bool> Function() write) {
    _pendingWrites[key] = (_attempt(write), write);
  }

  static Future<bool> _attempt(Future<bool> Function() write) async {
    try {
      return await write();
    } catch (_) {
      return false;
    }
  }

  /// Waits for identity writes, including ones made while it waits, and
  /// redoes any that failed once. False when one still did not reach disk:
  /// callers then must not send that identity or finish a purchase made
  /// under it. Concurrent callers share one flush, so none sees an empty list
  /// while another's writes are still unconfirmed.
  Future<bool> flush() {
    return _flushing ??= _flush().whenComplete(() => _flushing = null);
  }

  Future<bool> _flush() async {
    while (_pendingWrites.isNotEmpty) {
      final writes = Map.of(_pendingWrites);
      var ok = true;
      for (final MapEntry(key: key, value: (result, redo)) in writes.entries) {
        var done = await result;
        if (!done) done = await _attempt(redo);
        // Replaced by a newer write meanwhile: that one is checked next round.
        if (!identical(_pendingWrites[key]?.$2, redo)) continue;
        if (done) {
          _pendingWrites.remove(key);
        } else {
          ok = false;
          _pendingWrites[key] = (Future.value(false), redo);
        }
      }
      if (!ok) return false;
    }
    return true;
  }

  // --- Account tokens (Apple appAccountToken / Google obfuscatedAccountId) ---

  String? accountToken(String appUserId) {
    final token = _stringMap(_accountTokens)[appUserId];
    return token != null && isUuid(token) ? token : null;
  }

  /// The app user a store account token was issued to on this device.
  String? appUserIdForAccountToken(String token) {
    for (final e in _stringMap(_accountTokens).entries) {
      if (e.value.toLowerCase() == token.toLowerCase()) return e.key;
    }
    return null;
  }

  void setAccountToken(String token, String appUserId) {
    if (!isUuid(token)) return;
    final all = _stringMap(_accountTokens)..[appUserId] = token;
    prefs.setString(_accountTokens, jsonEncode(all));
  }

  // --- Attributes waiting to be sent ---

  Map<String, String> get pendingAttributes => _stringMap(_pendingAttributes);

  void mergePendingAttributes(Map<String, String> attributes) {
    final all = pendingAttributes..addAll(attributes);
    prefs.setString(_pendingAttributes, jsonEncode(all));
  }

  /// Removes attributes that were sent, unless they changed while the request was in flight.
  void clearSentAttributes(Map<String, String> sent) {
    if (sent.isEmpty) return;
    final all = pendingAttributes;
    sent.forEach((key, value) {
      if (all[key] == value) all.remove(key);
    });
    prefs.setString(_pendingAttributes, jsonEncode(all));
  }

  // --- productId -> entitlement ids learned from server responses ---

  Map<String, List<String>> get learnedEntitlements {
    final raw = _json(_learnedEntitlements);
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (e.key is String && e.value is List)
          e.key as String: (e.value as List).whereType<String>().toList(),
    };
  }

  void learnEntitlements(AppReferCustomerInfo info) {
    final map = learnedEntitlements;
    var changed = false;
    info.entitlements.all.forEach((id, ent) {
      if (ent.productIdentifier.isEmpty) return;
      final ids = map[ent.productIdentifier] ?? <String>[];
      if (!ids.contains(id)) {
        map[ent.productIdentifier] = [...ids, id]..sort();
        changed = true;
      }
    });
    if (changed) prefs.setString(_learnedEntitlements, jsonEncode(map));
  }

  // --- logIns that still need to reach the server, oldest first ---

  /// Survives logOut: an anonymous purchase still has to move to the user who
  /// logged in. Also reads the single entry earlier builds saved.
  List<PendingIdentify> get pendingIdentifies {
    final raw = _decodeJson(_readIdentity(_pendingIdentifies));
    if (raw is List) {
      return [
        for (final e in raw)
          if (e is Map &&
              e['anonymousId'] is String &&
              e['appUserId'] is String)
            (
              anonymousId: e['anonymousId'] as String,
              appUserId: e['appUserId'] as String,
            ),
      ];
    }
    final d = _stringMap(_pendingIdentify, identity: true);
    final anon = d['anonymousId'];
    final user = d['appUserId'];
    if (anon == null || user == null) return [];
    return [(anonymousId: anon, appUserId: user)];
  }

  set pendingIdentifies(List<PendingIdentify> value) {
    _write(_pendingIdentify, () => prefs.remove(_pendingIdentify));
    if (value.isEmpty) {
      _write(_pendingIdentifies, () => prefs.remove(_pendingIdentifies));
    } else {
      final encoded = jsonEncode([
        for (final e in value)
          {'anonymousId': e.anonymousId, 'appUserId': e.appUserId},
      ]);
      _write(
        _pendingIdentifies,
        () => prefs.setString(_pendingIdentifies, encoded),
      );
    }
  }

  void addPendingIdentify(PendingIdentify entry) {
    final list = pendingIdentifies;
    if (list.contains(entry)) return;
    pendingIdentifies = [...list, entry];
  }

  /// Removes [entry] only; a newer login queued meanwhile stays.
  void removePendingIdentify(PendingIdentify entry) {
    final list = pendingIdentifies;
    if (!list.contains(entry)) return;
    pendingIdentifies = [
      for (final e in list)
        if (e != entry) e,
    ];
  }

  // --- Cached CustomerInfo (last server answer) ---

  AppReferCustomerInfo? cachedCustomerInfo() =>
      AppReferCustomerInfo.tryDecode(prefs.getString(_customerInfo));

  void setCachedCustomerInfo(AppReferCustomerInfo info) {
    prefs.setString(_customerInfo, jsonEncode(info.toJson()));
  }

  // --- Google Play product kinds (subscription / one-time), learned from the store ---

  Map<String, String> get productKinds => _stringMap(_productKinds);

  void setProductKind(String productId, String kind) {
    final all = productKinds..[productId] = kind;
    prefs.setString(_productKinds, jsonEncode(all));
  }

  // --- helpers ---

  /// Non-identity values: unreadable counts as absent.
  Object? _json(String key) {
    try {
      return _decodeJson(prefs.getString(key));
    } catch (_) {
      return null;
    }
  }

  static Object? _decodeJson(String? raw) {
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _stringMap(String key, {bool identity = false}) {
    final raw = identity ? _decodeJson(_readIdentity(key)) : _json(key);
    if (raw is! Map) return {};
    return {
      for (final e in raw.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  }

  static String generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
