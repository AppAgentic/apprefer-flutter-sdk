import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'billing_error.dart';
import 'offerings.dart';

/// Who opened a purchase sheet, saved before it opens, so a purchase that
/// completes after an app restart, logout or user switch (Ask to Buy, SCA, a
/// slow payment method) is still recorded for them.
class PurchaseIntent {
  final String appUserId;
  final String productId;

  /// The account token the purchase was tagged with, when there was one.
  final String? accountToken;
  final DateTime startedAt;
  final PresentedOfferingContext? presentedOfferingContext;
  final String? bucketId;

  const PurchaseIntent({
    required this.appUserId,
    required this.productId,
    required this.accountToken,
    required this.startedAt,
    this.presentedOfferingContext,
    this.bucketId,
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
    if (presentedOfferingContext != null)
      'presentedOfferingContext': presentedOfferingContext!.toJson(),
    if (bucketId != null) 'bucketId': bucketId,
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
      presentedOfferingContext: json['presentedOfferingContext'] is Map
          ? PresentedOfferingContext.fromJson(
              Map<String, dynamic>.from(
                json['presentedOfferingContext'] as Map,
              ),
            )
          : null,
      bucketId: json['bucketId'] as String?,
    );
  }
}

/// Set when the stored intents could not be parsed (they were quarantined):
/// some purchase may have lost the record of who started it.
class IntentsLost {
  final DateTime lostAt;

  /// Untagged new purchases left open meanwhile (`store:id`), with when each
  /// was first deferred.
  final Map<String, DateTime> deferred;

  const IntentsLost(this.lostAt, this.deferred);

  Map<String, dynamic> toJson() => {
    'lostAtMs': lostAt.millisecondsSinceEpoch,
    'deferred': {
      for (final e in deferred.entries) e.key: e.value.millisecondsSinceEpoch,
    },
  };

  static IntentsLost? fromJson(Object? json) {
    if (json is! Map) return null;
    final ms = json['lostAtMs'];
    if (ms is! num) return null;
    final deferred = json['deferred'];
    return IntentsLost(DateTime.fromMillisecondsSinceEpoch(ms.round()), {
      if (deferred is Map)
        for (final e in deferred.entries)
          if (e.key is String && e.value is num)
            e.key as String: DateTime.fromMillisecondsSinceEpoch(
              (e.value as num).round(),
            ),
    });
  }
}

/// Disk-backed purchase intents. An intent stays until its purchase is
/// recorded, saved for retry or for support, cancelled or failed: none is
/// dropped for its age or for being missing from a store query, and a new
/// purchase never replaces an older intent. Stored intents that can't be
/// parsed are quarantined under their own key and an "intents lost" marker
/// is saved, so untagged new purchases are held back rather than given to
/// whoever is signed in. Owned by `BillingEngine`.
class PurchaseIntentStore {
  /// How long an untagged new purchase is left open while intents are lost
  /// before it goes to the current user (inside Google's 3-day
  /// acknowledgement window).
  static const lostHold = Duration(hours: 48);

  final SharedPreferences _prefs;
  final String _key;
  final DateTime Function() _now;

  PurchaseIntentStore(this._prefs, this._key, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  String get _lostKey => '${_key}_lost';
  String get quarantinePrefix => '${_key}_quarantine_';

  String? _get(String key) {
    try {
      return _prefs.getString(key);
    } catch (e) {
      throw AppReferBillingException(
        AppReferBillingErrorCode.storage,
        message: 'could not read $key: $e',
      );
    }
  }

  /// The saved intents. Throws [AppReferBillingErrorCode.storage] when they
  /// can't be read, so a caller never takes "none" for "unreadable". Stored
  /// intents that can't be parsed are quarantined (the parseable ones kept)
  /// and the intents-lost marker is saved; until both are on disk this throws.
  Future<List<PurchaseIntent>> read() async {
    final raw = _get(_key);
    if (raw == null) return [];
    List<PurchaseIntent>? parsed;
    var valid = <PurchaseIntent>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        valid = decoded
            .map(PurchaseIntent.fromJson)
            .whereType<PurchaseIntent>()
            .toList();
        if (valid.length == decoded.length) parsed = valid;
      }
    } catch (_) {}
    if (parsed != null) return parsed;
    await _quarantine(raw, valid);
    return valid;
  }

  Future<void> _quarantine(String raw, List<PurchaseIntent> valid) async {
    final at = _now();
    final saved =
        await _set('$quarantinePrefix${at.millisecondsSinceEpoch}', raw) &&
        await _saveLost(lostMarker() ?? IntentsLost(at, const {})) &&
        await _write(valid);
    if (!saved) {
      throw const AppReferBillingException(
        AppReferBillingErrorCode.storage,
        message: 'could not quarantine unparseable purchase intents',
      );
    }
  }

  /// The intents-lost marker, or null when there is none. Throws
  /// [AppReferBillingErrorCode.storage] when it can't be read; a marker that
  /// can't be parsed counts as set now.
  IntentsLost? lostMarker() {
    final raw = _get(_lostKey);
    if (raw == null) return null;
    try {
      return IntentsLost.fromJson(jsonDecode(raw)) ??
          IntentsLost(_now(), const {});
    } catch (_) {
      return IntentsLost(_now(), const {});
    }
  }

  /// Notes that the untagged new purchase [key] is being held while intents
  /// are lost; returns when it was first held. Throws
  /// [AppReferBillingErrorCode.storage] when that can't be saved.
  Future<DateTime> hold(IntentsLost lost, String key) async {
    final first = lost.deferred[key];
    if (first != null) return first;
    final at = _now();
    if (!await _saveLost(
      IntentsLost(lost.lostAt, {...lost.deferred, key: at}),
    )) {
      throw const AppReferBillingException(
        AppReferBillingErrorCode.storage,
        message: 'could not save a held purchase',
      );
    }
    return at;
  }

  /// Ends the hold on [key] (its purchase was recorded, queued or archived),
  /// then clears the marker if nothing is held any more.
  Future<void> release(String key) async {
    final lost = lostMarker();
    if (lost == null || !lost.deferred.containsKey(key)) return;
    await _saveLost(IntentsLost(lost.lostAt, {...lost.deferred}..remove(key)));
    await clearLostIfDone();
  }

  /// Forgets held purchases the store no longer has open (only from a store
  /// query that succeeded), then clears the marker once nothing is held and
  /// it is at least [lostHold] old, so a purchase still in flight when the
  /// intents were lost gets its full hold.
  Future<void> clearLostIfDone({Set<String>? open}) async {
    final lost = lostMarker();
    if (lost == null) return;
    var deferred = lost.deferred;
    if (open != null) {
      deferred = {
        for (final e in deferred.entries)
          if (open.contains(e.key)) e.key: e.value,
      };
    }
    if (deferred.isEmpty && !_now().isBefore(lost.lostAt.add(lostHold))) {
      try {
        await _prefs.remove(_lostKey);
      } catch (_) {}
    } else if (deferred.length != lost.deferred.length) {
      await _saveLost(IntentsLost(lost.lostAt, deferred));
    }
  }

  Future<bool> _saveLost(IntentsLost lost) =>
      _set(_lostKey, jsonEncode(lost.toJson()));

  /// Saves [intent]. True only once it is on disk; false when the write
  /// failed or the stored intents can't be read (they are never overwritten).
  Future<bool> add(PurchaseIntent intent) async {
    final List<PurchaseIntent> stored;
    try {
      stored = await read();
    } on AppReferBillingException {
      return false;
    }
    if (await _write([...stored, intent])) return true;
    // The in-memory copy took the failed write: put the stored list back.
    await _write(stored);
    return false;
  }

  /// Removes [intent] only; one saved for a newer purchase stays.
  Future<void> remove(PurchaseIntent intent) async {
    final List<PurchaseIntent> stored;
    try {
      stored = await read();
    } on AppReferBillingException {
      return;
    }
    final next = [
      for (final e in stored)
        if (!e.sameAs(intent)) e,
    ];
    if (next.length != stored.length) await _write(next);
  }

  Future<bool> _write(List<PurchaseIntent> intents) =>
      _set(_key, jsonEncode([for (final e in intents) e.toJson()]));

  Future<bool> _set(String key, String value) async {
    try {
      return await _prefs.setString(key, value);
    } catch (_) {
      return false;
    }
  }
}
