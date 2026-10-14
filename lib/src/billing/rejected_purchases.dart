import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'customer_info.dart';

/// A store purchase AppRefer finally refused (400/413/422), that had nothing
/// AppRefer can verify, or that the retry queue gave up on. Kept on the device
/// so support can recover it and Restore Purchases can send it again; it is
/// saved before the purchase is completed with the store.
class RejectedPurchase {
  /// Apple transaction id / Google purchase token (empty when the store gave none).
  final String transactionId;
  final String productId;
  final BillingStore store;

  /// The customer it was sent for; null when the purchase never got that far.
  final String? appUserId;
  final String? appreferId;

  /// The `/purchases` body fields (signed JWS or purchase token); null when
  /// the store gave none.
  final Map<String, String>? storeFields;

  /// Apple `appAccountToken` / Google `obfuscatedAccountId` the purchase carries.
  final String? accountToken;

  /// `consumable`, `non_consumable`, `auto_renewable`, `non_renewable`, when known.
  final String? kind;

  /// Why AppRefer did not take it.
  final String reason;
  final DateTime rejectedAt;

  /// What the store plugin delivered, as JSON, when it gave no verifiable data.
  final String? raw;

  /// For support: e.g. that its owner was guessed because the saved purchase
  /// intents were lost.
  final String? note;

  const RejectedPurchase({
    required this.transactionId,
    required this.productId,
    required this.store,
    required this.appUserId,
    required this.appreferId,
    required this.storeFields,
    required this.accountToken,
    required this.kind,
    required this.reason,
    required this.rejectedAt,
    this.raw,
    this.note,
  });

  bool get isConsumable => kind == 'consumable';

  /// One entry per store purchase; a purchase without an id by product and time.
  String get key =>
      '${store.value}:${transactionId.isNotEmpty ? transactionId : '$productId@${rejectedAt.millisecondsSinceEpoch}'}';

  Map<String, dynamic> toJson() => {
    'transactionId': transactionId,
    'productId': productId,
    'store': store.value,
    'appUserId': appUserId,
    'appreferId': appreferId,
    'storeFields': storeFields,
    'accountToken': accountToken,
    'kind': kind,
    'reason': reason,
    'rejectedAtMs': rejectedAt.millisecondsSinceEpoch,
    if (raw != null) 'raw': raw,
    if (note != null) 'note': note,
  };

  static RejectedPurchase? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['transactionId'];
    final productId = json['productId'];
    final store = switch (json['store']) {
      'app_store' => BillingStore.appStore,
      'play_store' => BillingStore.playStore,
      _ => null,
    };
    if (id is! String || productId is! String || store == null) return null;
    final fields = json['storeFields'];
    String? str(Object? v) => v is String ? v : null;
    final ms = json['rejectedAtMs'];
    return RejectedPurchase(
      transactionId: id,
      productId: productId,
      store: store,
      appUserId: str(json['appUserId']),
      appreferId: str(json['appreferId']),
      storeFields: fields is Map
          ? {
              for (final e in fields.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            }
          : null,
      accountToken: str(json['accountToken']),
      kind: str(json['kind']),
      reason: str(json['reason']) ?? '',
      rejectedAt: DateTime.fromMillisecondsSinceEpoch(
        ms is num ? ms.round() : 0,
      ),
      raw: str(json['raw']),
      note: str(json['note']),
    );
  }
}

/// Disk-backed list of rejected purchases. Like the retry queue, a stored list
/// that can't be read is never overwritten: writes are refused (so nothing is
/// completed with the store) until it reads again, and then what was added
/// meanwhile is merged in. An entry counts as saved only while the stored list
/// holds it with the same contents ([isDurable]). There is no size cap and
/// nothing is evicted: an entry leaves only once AppRefer has recorded the
/// purchase ([remove]). Owned by `BillingEngine`.
class RejectedPurchaseLog {
  final SharedPreferences _prefs;
  final String _key;
  List<RejectedPurchase> _entries = [];

  /// What the stored list is known to hold: each key with its encoded entry.
  Map<String, String> _onDisk = {};
  bool _unreadable = false;
  final _removedWhileUnreadable = <String>{};

  RejectedPurchaseLog(this._prefs, this._key) {
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
      final known = {for (final e in _entries) e.key};
      _entries = [
        for (final e in stored)
          if (!known.contains(e.key) &&
              !_removedWhileUnreadable.contains(e.key))
            e,
        ..._entries,
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

  static List<RejectedPurchase> _decode(String? raw) {
    if (raw == null) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map(RejectedPurchase.fromJson)
          .whereType<RejectedPurchase>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static String _encode(RejectedPurchase e) => jsonEncode(e.toJson());

  static Map<String, String> _encodeAll(List<RejectedPurchase> entries) => {
    for (final e in entries) e.key: _encode(e),
  };

  List<RejectedPurchase> get entries {
    _reloadIfUnreadable();
    return List.unmodifiable(_entries);
  }

  RejectedPurchase? entry(BillingStore store, String transactionId) {
    for (final e in entries) {
      if (e.store == store && e.transactionId == transactionId) return e;
    }
    return null;
  }

  bool contains(BillingStore store, String transactionId) =>
      entry(store, transactionId) != null;

  /// Held by the stored list with its current contents: the purchase may be
  /// completed with the store.
  bool isDurable(BillingStore store, String transactionId) {
    final e = entry(store, transactionId);
    return e != null && _onDisk[e.key] == _encode(e);
  }

  /// Adds (or replaces) the entry. True only once the stored list holds it as
  /// given: only then may the purchase be completed with the store.
  Future<bool> add(RejectedPurchase entry) async {
    _reloadIfUnreadable();
    _entries = [
      for (final e in _entries)
        if (e.key != entry.key) e,
      entry,
    ];
    await _save();
    return _onDisk[entry.key] == _encode(entry);
  }

  /// Writes the list again (after a failed write or an unreadable read).
  Future<bool> persist() {
    _reloadIfUnreadable();
    return _save();
  }

  /// Drops the entry once AppRefer has recorded the purchase.
  Future<void> remove(BillingStore store, String transactionId) async {
    _reloadIfUnreadable();
    final key = '${store.value}:$transactionId';
    final before = _entries.length;
    _entries.removeWhere(
      (e) => e.store == store && e.transactionId == transactionId,
    );
    // While unreadable the stored copy may not be in memory yet: keep it out
    // of the later merge.
    if (_unreadable) _removedWhileUnreadable.add(key);
    if (_entries.length != before) await _save();
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
