import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'billing_error.dart';

/// Who opened a purchase sheet, saved before it opens, so a purchase that
/// completes after an app restart, logout or user switch (Ask to Buy, SCA, a
/// slow payment method) is still recorded for them.
class PurchaseIntent {
  final String appUserId;
  final String productId;

  /// The account token the purchase was tagged with, when there was one.
  final String? accountToken;
  final DateTime startedAt;

  const PurchaseIntent({
    required this.appUserId,
    required this.productId,
    required this.accountToken,
    required this.startedAt,
  });

  bool sameAs(PurchaseIntent other) =>
      appUserId == other.appUserId &&
      productId == other.productId &&
      startedAt == other.startedAt;

  Map<String, dynamic> toJson() => {
    'appUserId': appUserId,
    'productId': productId,
    'accountToken': accountToken,
    'startedAtMs': startedAt.millisecondsSinceEpoch,
  };

  static PurchaseIntent? fromJson(Object? json) {
    if (json is! Map) return null;
    final user = json['appUserId'];
    final productId = json['productId'];
    final ms = json['startedAtMs'];
    if (user is! String || productId is! String || ms is! num) return null;
    final token = json['accountToken'];
    return PurchaseIntent(
      appUserId: user,
      productId: productId,
      accountToken: token is String && token.isNotEmpty ? token : null,
      startedAt: DateTime.fromMillisecondsSinceEpoch(ms.round()),
    );
  }
}

/// Disk-backed purchase intents. An intent stays until its purchase is
/// recorded, saved for retry or for support, cancelled or failed: none is
/// dropped for its age, because Ask to Buy and slow payments can take any
/// time. A new purchase of the same product by the same user replaces that
/// user's older intent for it, which bounds the list. Owned by `BillingEngine`.
class PurchaseIntentStore {
  final SharedPreferences _prefs;
  final String _key;

  PurchaseIntentStore(this._prefs, this._key);

  /// The saved intents. Throws [AppReferBillingErrorCode.storage] when they
  /// can't be read, so a caller never takes "none" for "unreadable".
  List<PurchaseIntent> read() {
    final String? raw;
    try {
      raw = _prefs.getString(_key);
    } catch (e) {
      throw AppReferBillingException(
        AppReferBillingErrorCode.storage,
        message: 'could not read purchase intents: $e',
      );
    }
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map(PurchaseIntent.fromJson)
          .whereType<PurchaseIntent>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Saves [intent]. True only once it is on disk; false when the write
  /// failed or the stored intents can't be read (they are never overwritten).
  Future<bool> add(PurchaseIntent intent) async {
    final List<PurchaseIntent> stored;
    try {
      stored = read();
    } on AppReferBillingException {
      return false;
    }
    final next = [
      for (final e in stored)
        if (!(e.appUserId == intent.appUserId &&
            e.productId == intent.productId))
          e,
      intent,
    ];
    if (await _write(next)) return true;
    // The in-memory copy took the failed write: put the stored list back.
    await _write(stored);
    return false;
  }

  /// Removes [intent] only; one saved for a newer purchase stays.
  Future<void> remove(PurchaseIntent intent) async {
    final List<PurchaseIntent> stored;
    try {
      stored = read();
    } on AppReferBillingException {
      return;
    }
    final next = [
      for (final e in stored)
        if (!e.sameAs(intent)) e,
    ];
    if (next.length != stored.length) await _write(next);
  }

  Future<bool> _write(List<PurchaseIntent> intents) async {
    try {
      return await _prefs.setString(
        _key,
        jsonEncode([for (final e in intents) e.toJson()]),
      );
    } catch (_) {
      return false;
    }
  }
}
