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

/// Disk-backed retry queue. A purchase is completed with the store only once
/// its entry is on disk ([isDurable]), so the store never redelivers forever
/// and Google never auto-refunds; the signed data stays here until AppRefer
/// accepts it. Owned by `BillingEngine`.
class PendingPurchaseQueue {
  static const maxAttempts = 50;
  static const maxAge = Duration(days: 90);

  final SharedPreferences _prefs;
  final String _key;
  List<PendingPurchase> _entries = [];

  /// What the stored queue is known to hold: each transaction id with its
  /// encoded entry. An entry missing here, or whose in-memory contents differ
  /// (e.g. replaced by a redelivery whose save failed), is provisional: not
  /// yet safe to complete.
  Map<String, String> _onDisk = {};

  /// The stored queue could not be read. Nothing is written then, so the
  /// purchases it holds are never overwritten; it is read again on the next
  /// use and merged with what was queued meanwhile.
  bool _unreadable = false;

  /// Removed while the stored queue was unreadable, so the merge does not
  /// bring them back.
  final _removedWhileUnreadable = <String>{};

  PendingPurchaseQueue(this._prefs, this._key) {
    _load();
  }

  void _load() {
    final String? raw;
    try {
      raw = _prefs.getString(_key);
    } catch (_) {
      _unreadable = true;
      return;
    }
    final stored = _decode(raw);
    if (_unreadable) {
      // Recovered: keep what was queued meanwhile, add what disk held.
      final known = {for (final e in _entries) e.transactionId};
      _entries = [
        ..._entries,
        for (final e in stored)
          if (!known.contains(e.transactionId) &&
              !_removedWhileUnreadable.contains(e.transactionId))
            e,
      ];
      _removedWhileUnreadable.clear();
    } else {
      _entries = stored;
    }
    _onDisk = _encodeAll(stored);
    _unreadable = false;
  }

  void _reloadIfUnreadable() {
    if (_unreadable) _load();
  }

  /// Whether the stored queue could not be read (writes are refused).
  bool get isUnreadable {
    _reloadIfUnreadable();
    return _unreadable;
  }

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

  List<PendingPurchase> get entries {
    _reloadIfUnreadable();
    return List.unmodifiable(_entries);
  }

  bool get isEmpty {
    _reloadIfUnreadable();
    return _entries.isEmpty;
  }

  bool containsUser(String appUserId) =>
      entries.any((e) => e.appUserId == appUserId);

  bool contains(String transactionId) =>
      entries.any((e) => e.transactionId == transactionId);

  /// Queued and on disk as it is now: the purchase may be completed with the
  /// store.
  bool isDurable(String transactionId) {
    _reloadIfUnreadable();
    final stored = _onDisk[transactionId];
    if (stored == null) return false;
    for (final e in _entries) {
      if (e.transactionId == transactionId) return _encode(e) == stored;
    }
    return false;
  }

  static String _encode(PendingPurchase e) => jsonEncode(e.toJson());

  static Map<String, String> _encodeAll(List<PendingPurchase> entries) => {
    for (final e in entries) e.transactionId: _encode(e),
  };

  /// Adds or refreshes an entry; one entry per transaction id. A refreshed
  /// entry keeps its first queue time and adds to its attempts. An explicit
  /// restore ([PendingPurchase.restore]) takes the entry over for the
  /// restoring customer; any other redelivery keeps the queued owner and a
  /// queued restore stays a restore. Returns whether the queue was written to
  /// disk: only then may the purchase be completed with the store.
  Future<bool> add(PendingPurchase entry) {
    _reloadIfUnreadable();
    final index = _entries.indexWhere(
      (e) => e.transactionId == entry.transactionId,
    );
    if (index >= 0) {
      final old = _entries[index];
      final owner = entry.restore ? entry : old;
      _entries[index] = PendingPurchase(
        transactionId: old.transactionId,
        productId: old.productId,
        appUserId: owner.appUserId,
        appreferId: owner.appreferId,
        storeFields: entry.storeFields,
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
    _reloadIfUnreadable();
    _entries.removeWhere((e) => e.transactionId == transactionId);
    if (_unreadable) _removedWhileUnreadable.add(transactionId);
    return _save();
  }

  Future<bool> recordAttempt(String transactionId) {
    _reloadIfUnreadable();
    final index = _entries.indexWhere((e) => e.transactionId == transactionId);
    if (index < 0) return Future.value(true);
    _entries[index] = _entries[index].withAttempts(
      _entries[index].attempts + 1,
    );
    return _save();
  }

  /// Writes the queue again (after a failed write or an unreadable read).
  Future<bool> persist() {
    _reloadIfUnreadable();
    return _save();
  }

  /// Drops entries that have failed too often or are too old. The server still
  /// gets those purchases from App Store / Google Play notifications.
  Future<List<PendingPurchase>> prune(DateTime now) async {
    _reloadIfUnreadable();
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
    if (_unreadable) _removedWhileUnreadable.addAll(ids);
    await _save();
    return dropped;
  }

  Future<bool> _save() async {
    if (_unreadable) return false;
    final snapshot = List.of(_entries);
    try {
      final ok = await _prefs.setString(
        _key,
        jsonEncode(snapshot.map((e) => e.toJson()).toList()),
      );
      if (ok) _onDisk = _encodeAll(snapshot);
      return ok;
    } catch (_) {
      return false;
    }
  }
}
