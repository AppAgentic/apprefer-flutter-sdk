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

  /// Queued by Restore Purchases, so the retry is still sent as a restore.
  final bool restore;

  const PendingPurchase({
    required this.transactionId,
    required this.productId,
    required this.appUserId,
    required this.appreferId,
    required this.storeFields,
    required this.enqueuedAt,
    this.attempts = 1,
    this.restore = false,
  });

  /// A Google Play consumable: consumed only once AppRefer recorded it.
  bool get isConsumable => storeFields['productType'] == 'consumable';

  PendingPurchase copyWith({
    int? attempts,
    DateTime? enqueuedAt,
    bool? restore,
  }) => PendingPurchase(
    transactionId: transactionId,
    productId: productId,
    appUserId: appUserId,
    appreferId: appreferId,
    storeFields: storeFields,
    enqueuedAt: enqueuedAt ?? this.enqueuedAt,
    attempts: attempts ?? this.attempts,
    restore: restore ?? this.restore,
  );

  PendingPurchase withAttempts(int attempts) => copyWith(attempts: attempts);

  Map<String, dynamic> toJson() => {
    'transactionId': transactionId,
    'productId': productId,
    'appUserId': appUserId,
    'appreferId': appreferId,
    'storeFields': storeFields,
    'enqueuedAtMs': enqueuedAt.millisecondsSinceEpoch,
    'attempts': attempts,
    if (restore) 'restore': true,
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
      restore: json['restore'] == true,
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

  /// The stored queue could not be read. Nothing is written then, so the
  /// purchases it holds are never overwritten with an empty list.
  bool _unreadable = false;

  PendingPurchaseQueue(this._prefs, this._key) : _entries = [] {
    final String? raw;
    try {
      raw = _prefs.getString(_key);
    } catch (_) {
      _unreadable = true;
      return;
    }
    _entries = _decode(raw);
  }

  /// Whether the stored queue could not be read (writes are refused).
  bool get isUnreadable => _unreadable;

  static List<PendingPurchase> _decode(String? raw) {
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

  bool contains(String transactionId) =>
      _entries.any((e) => e.transactionId == transactionId);

  /// Adds or refreshes an entry; one entry per transaction id. A refreshed
  /// entry keeps its first queue time and adds to its attempts, and a restore
  /// stays a restore. Returns whether the queue was written to disk: only then
  /// may the purchase be finished with the store.
  Future<bool> add(PendingPurchase entry) async {
    final index = _entries.indexWhere(
      (e) => e.transactionId == entry.transactionId,
    );
    if (index >= 0) {
      final old = _entries[index];
      _entries[index] = entry.copyWith(
        enqueuedAt: old.enqueuedAt,
        attempts: old.attempts + entry.attempts,
        restore: old.restore || entry.restore,
      );
    } else {
      _entries.add(entry);
    }
    return _save();
  }

  Future<bool> remove(String transactionId) {
    _entries.removeWhere((e) => e.transactionId == transactionId);
    return _save();
  }

  Future<bool> recordAttempt(String transactionId) {
    final index = _entries.indexWhere((e) => e.transactionId == transactionId);
    if (index < 0) return Future.value(true);
    _entries[index] = _entries[index].withAttempts(
      _entries[index].attempts + 1,
    );
    return _save();
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

  Future<bool> _save() async {
    if (_unreadable) return false;
    try {
      return await _prefs.setString(
        _key,
        jsonEncode(_entries.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      return false;
    }
  }
}
