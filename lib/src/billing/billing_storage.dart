import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'customer_info.dart';

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
  static const _customerInfo = 'apprefer_billing_customer_info';
  static const _productKinds = 'apprefer_billing_product_kinds';
  static const pendingPurchasesKey = 'apprefer_billing_pending_purchases';

  final SharedPreferences prefs;

  BillingStorage(this.prefs);

  static bool isAnonymous(String appUserId) =>
      appUserId.startsWith(anonymousPrefix);

  static final _uuid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static bool isUuid(String value) => _uuid.hasMatch(value);

  // --- Identity ---

  bool get hasAnonymousId => prefs.getString(_anonymousId) != null;

  /// `$ARAnon:<UUID>`, minted once and kept for the install.
  String anonymousId() {
    final existing = prefs.getString(_anonymousId);
    if (existing != null && isAnonymous(existing)) return existing;
    return resetAnonymousId();
  }

  String resetAnonymousId() {
    final id = '$anonymousPrefix${generateUuidV4().toUpperCase()}';
    prefs.setString(_anonymousId, id);
    return id;
  }

  /// The logged-in app user id, or null while anonymous.
  String? get loggedInAppUserId => prefs.getString(_appUserId);

  set loggedInAppUserId(String? value) {
    if (value == null) {
      prefs.remove(_appUserId);
    } else {
      prefs.setString(_appUserId, value);
    }
  }

  String get currentAppUserId => loggedInAppUserId ?? anonymousId();

  // --- Account tokens (Apple appAccountToken / Google obfuscatedAccountId) ---

  String? accountToken(String appUserId) {
    final token = _stringMap(_accountTokens)[appUserId];
    return token != null && isUuid(token) ? token : null;
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

  // --- logIn that still needs to reach the server ---

  ({String anonymousId, String appUserId})? get pendingIdentify {
    final d = _stringMap(_pendingIdentify);
    final anon = d['anonymousId'];
    final user = d['appUserId'];
    if (anon == null || user == null) return null;
    return (anonymousId: anon, appUserId: user);
  }

  set pendingIdentify(({String anonymousId, String appUserId})? value) {
    if (value == null) {
      prefs.remove(_pendingIdentify);
    } else {
      prefs.setString(
        _pendingIdentify,
        jsonEncode({
          'anonymousId': value.anonymousId,
          'appUserId': value.appUserId,
        }),
      );
    }
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

  Object? _json(String key) {
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _stringMap(String key) {
    final raw = _json(key);
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
