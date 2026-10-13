import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A store purchase AppRefer has not accepted yet.
class PendingPurchase {
  /// Apple transaction id / Google purchase token.
  final String transactionId;
  final String productId;
  final String appUserId;
  final String? appreferId;

  /// The store-specific `/purchases` body fields (signed JWS or purchase token).
  final Map<String, String> storeFields;
  final DateTime enqueuedAt;
  final int attempts;

  const PendingPurchase({
    required this.transactionId,
    required this.productId,
    required this.appUserId,
    required this.appreferId,
    required this.storeFields,
    required this.enqueuedAt,
    this.attempts = 1,
  });

  PendingPurchase withAttempts(int attempts) => PendingPurchase(
    transactionId: transactionId,
    productId: productId,
    appUserId: appUserId,
    appreferId: appreferId,
    storeFields: storeFields,
    enqueuedAt: enqueuedAt,
    attempts: attempts,
  );

  Map<String, dynamic> toJson() => {
    'transactionId': transactionId,
    'productId': productId,
    'appUserId': appUserId,
    'appreferId': appreferId,
    'storeFields': storeFields,
    'enqueuedAtMs': enqueuedAt.millisecondsSinceEpoch,
    'attempts': attempts,
  };

  static PendingPurchase? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['transactionId'];
    final productId = json['productId'];
    final user = json['appUserId'];
    final fields = json['storeFields'];
    final ms = json['enqueuedAtMs'];
    if (id is! String || productId is! String || user is! String) return null;
    if (fields is! Map || ms is! num) return null;
    return PendingPurchase(
      transactionId: id,
      productId: productId,
      appUserId: user,
      appreferId: json['appreferId'] as String?,
      storeFields: {
        for (final e in fields.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      },
      enqueuedAt: DateTime.fromMillisecondsSinceEpoch(ms.round()),
      attempts: json['attempts'] is int ? json['attempts'] as int : 1,
    );
  }
}

/// Disk-backed retry queue. Purchases are completed with the store as soon as
/// they are queued (so the store never redelivers forever and Google never
/// auto-refunds an unacknowledged purchase); the signed data stays here until
/// AppRefer accepts it. Owned by `BillingEngine`.
class PendingPurchaseQueue {
  static const maxAttempts = 50;
  static const maxAge = Duration(days: 90);

  final SharedPreferences _prefs;
  final String _key;
  List<PendingPurchase> _entries;

  PendingPurchaseQueue(this._prefs, this._key) : _entries = _load(_prefs, _key);

  static List<PendingPurchase> _load(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map(PendingPurchase.fromJson)
          .whereType<PendingPurchase>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  List<PendingPurchase> get entries => List.unmodifiable(_entries);

  bool get isEmpty => _entries.isEmpty;

  bool containsUser(String appUserId) =>
      _entries.any((e) => e.appUserId == appUserId);

  /// Adds or refreshes an entry; one entry per transaction id. Completes once
  /// the entry is written, so the purchase can then be completed with the store.
  Future<void> add(PendingPurchase entry) async {
    final index = _entries.indexWhere(
      (e) => e.transactionId == entry.transactionId,
    );
    if (index >= 0) {
      _entries[index] = entry;
    } else {
      _entries.add(entry);
    }
    await _save();
  }

  void remove(String transactionId) {
    _entries.removeWhere((e) => e.transactionId == transactionId);
    _save();
  }

  void recordAttempt(String transactionId) {
    final index = _entries.indexWhere((e) => e.transactionId == transactionId);
    if (index < 0) return;
    _entries[index] = _entries[index].withAttempts(
      _entries[index].attempts + 1,
    );
    _save();
  }

  /// Drops entries that have failed too often or are too old. The server still
  /// gets those purchases from App Store / Google Play notifications.
  List<PendingPurchase> prune(DateTime now) {
    final dropped = _entries
        .where(
          (e) =>
              e.attempts >= maxAttempts ||
              now.difference(e.enqueuedAt) > maxAge,
        )
        .toList();
    if (dropped.isEmpty) return const [];
    final ids = dropped.map((e) => e.transactionId).toSet();
    _entries.removeWhere((e) => ids.contains(e.transactionId));
    _save();
    return dropped;
  }

  Future<bool> _save() {
    return _prefs.setString(
      _key,
      jsonEncode(_entries.map((e) => e.toJson()).toList()),
    );
  }
}
