import 'dart:convert';

/// The customer's entitlements as AppRefer Billing sees them.
///
/// Mirrors RevenueCat's `CustomerInfo`, so
/// `customerInfo.entitlements['premium']?.isActive` works the same way.
/// Decoded from the server's `CustomerInfo` JSON (`web/lib/billing/types.ts`
/// in the AppRefer repo).
///
/// Also available as `AppReferCustomerInfo`, for files that import both
/// AppRefer and RevenueCat during a migration.
typedef CustomerInfo = AppReferCustomerInfo;

/// One entitlement (for example `premium`). Also available as
/// `AppReferEntitlementInfo`.
typedef EntitlementInfo = AppReferEntitlementInfo;

/// Where a [AppReferCustomerInfo] snapshot came from.
enum CustomerInfoSource {
  /// Returned by the AppRefer server just now.
  server,

  /// The last server response, re-checked against the clock.
  cache,

  /// AppRefer was unreachable or refused the request; entitlements come from
  /// the store's own verified active purchases, merged with the cache.
  localFallback,
}

enum BillingStore {
  appStore('app_store'),
  playStore('play_store'),
  stripe('stripe'),
  unknown('unknown');

  const BillingStore(this.value);
  final String value;

  static BillingStore parse(Object? raw) => BillingStore.values.firstWhere(
    (s) => s.value == raw,
    orElse: () => BillingStore.unknown,
  );
}

enum BillingPeriodType {
  trial,
  intro,
  normal,
  promotional,
  unknown;

  static BillingPeriodType parse(Object? raw) =>
      BillingPeriodType.values.firstWhere(
        (s) => s.name == raw,
        orElse: () => BillingPeriodType.unknown,
      );
}

enum BillingSubscriptionState {
  active('active'),

  /// Billing failed but the store is still retrying; access continues.
  inGracePeriod('in_grace_period'),

  /// Billing failed; no access.
  inBillingRetry('in_billing_retry'),
  paused('paused'),
  expired('expired'),
  revoked('revoked'),
  unknown('unknown');

  const BillingSubscriptionState(this.value);
  final String value;

  static BillingSubscriptionState parse(Object? raw) =>
      BillingSubscriptionState.values.firstWhere(
        (s) => s.value == raw,
        orElse: () => BillingSubscriptionState.unknown,
      );
}

class AppReferCustomerInfo {
  final String appUserId;
  final EntitlementInfos entitlements;

  /// Product ids of auto-renewing subscriptions that currently grant access.
  final Set<String> activeSubscriptions;

  /// When the snapshot was computed.
  final DateTime requestDate;
  final CustomerInfoSource source;

  const AppReferCustomerInfo({
    required this.appUserId,
    required this.entitlements,
    required this.activeSubscriptions,
    required this.requestDate,
    required this.source,
  });

  /// True when any entitlement is active.
  bool get hasActiveEntitlement => entitlements.active.isNotEmpty;

  AppReferCustomerInfo withSource(CustomerInfoSource source) =>
      AppReferCustomerInfo(
        appUserId: appUserId,
        entitlements: entitlements,
        activeSubscriptions: activeSubscriptions,
        requestDate: requestDate,
        source: source,
      );

  /// Same user, entitlements and subscriptions (ignores request date and source).
  bool hasSameContent(AppReferCustomerInfo other) =>
      appUserId == other.appUserId &&
      entitlements == other.entitlements &&
      _setEquals(activeSubscriptions, other.activeSubscriptions);

  /// Re-checks a cached snapshot against the clock, so an expired subscription
  /// never stays unlocked from an old cache. Grace periods keep the server's verdict.
  AppReferCustomerInfo reevaluated(DateTime now) {
    final all = <String, AppReferEntitlementInfo>{};
    final activeSubs = Set<String>.of(activeSubscriptions);
    entitlements.all.forEach((id, ent) {
      final expires = ent.expirationDate;
      if (ent.isActive &&
          ent.state != BillingSubscriptionState.inGracePeriod &&
          expires != null &&
          !expires.isAfter(now)) {
        all[id] = ent.expired();
        activeSubs.remove(ent.productIdentifier);
      } else {
        all[id] = ent;
      }
    });
    return AppReferCustomerInfo(
      appUserId: appUserId,
      entitlements: EntitlementInfos(all),
      activeSubscriptions: activeSubs,
      requestDate: now,
      source: CustomerInfoSource.cache,
    );
  }

  factory AppReferCustomerInfo.fromJson(
    Map<String, dynamic> json, {
    CustomerInfoSource? source,
  }) {
    final appUserId = json['appUserId'];
    if (appUserId is! String) {
      throw const FormatException('CustomerInfo.appUserId missing');
    }
    final rawEnts = json['entitlements'];
    final ents = <String, AppReferEntitlementInfo>{};
    if (rawEnts is Map) {
      rawEnts.forEach((key, value) {
        if (key is String && value is Map) {
          final ent = AppReferEntitlementInfo.fromJson(
            Map<String, dynamic>.from(value),
          );
          ents[key] = ent.identifier.isEmpty ? ent.withIdentifier(key) : ent;
        }
      });
    }
    final rawSubs = json['activeSubscriptions'];
    final ms = json['requestDateMs'];
    return AppReferCustomerInfo(
      appUserId: appUserId,
      entitlements: EntitlementInfos(ents),
      activeSubscriptions: rawSubs is List
          ? rawSubs.whereType<String>().toSet()
          : <String>{},
      requestDate: ms is num
          ? DateTime.fromMillisecondsSinceEpoch(ms.round())
          : DateTime.now(),
      source:
          source ??
          CustomerInfoSource.values.firstWhere(
            (s) => s.name == json['source'],
            orElse: () => CustomerInfoSource.server,
          ),
    );
  }

  Map<String, dynamic> toJson() => {
    'appUserId': appUserId,
    'entitlements': entitlements.all.map(
      (key, value) => MapEntry(key, value.toJson()),
    ),
    'activeSubscriptions': activeSubscriptions.toList()..sort(),
    'requestDateMs': requestDate.millisecondsSinceEpoch,
    'source': source.name,
  };

  static AppReferCustomerInfo? tryDecode(String? raw) {
    if (raw == null) return null;
    try {
      return AppReferCustomerInfo.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'CustomerInfo($appUserId, active: ${entitlements.active.keys.toList()}, source: ${source.name})';
}

/// Entitlements keyed by id. `entitlements['premium']?.isActive`.
class EntitlementInfos {
  final Map<String, AppReferEntitlementInfo> all;

  EntitlementInfos(Map<String, AppReferEntitlementInfo> all)
    : all = Map.unmodifiable(all);

  AppReferEntitlementInfo? operator [](String identifier) => all[identifier];

  /// Only the entitlements that currently grant access.
  Map<String, AppReferEntitlementInfo> get active =>
      Map.fromEntries(all.entries.where((e) => e.value.isActive));

  @override
  bool operator ==(Object other) {
    if (other is! EntitlementInfos || other.all.length != all.length) {
      return false;
    }
    for (final entry in all.entries) {
      if (other.all[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered(
    all.entries.map((e) => Object.hash(e.key, e.value)),
  );
}

class AppReferEntitlementInfo {
  final String identifier;
  final bool isActive;
  final String productIdentifier;
  final BillingStore store;

  /// Null for lifetime (non-consumable) purchases.
  final DateTime? expirationDate;
  final bool willRenew;
  final BillingPeriodType periodType;
  final BillingSubscriptionState state;

  /// Apple original transaction id / Google purchase-chain key.
  final String subscriptionKey;

  const AppReferEntitlementInfo({
    required this.identifier,
    required this.isActive,
    required this.productIdentifier,
    required this.store,
    required this.expirationDate,
    required this.willRenew,
    required this.periodType,
    required this.state,
    required this.subscriptionKey,
  });

  AppReferEntitlementInfo _copy({
    String? identifier,
    bool? isActive,
    bool? willRenew,
    BillingSubscriptionState? state,
  }) => AppReferEntitlementInfo(
    identifier: identifier ?? this.identifier,
    isActive: isActive ?? this.isActive,
    productIdentifier: productIdentifier,
    store: store,
    expirationDate: expirationDate,
    willRenew: willRenew ?? this.willRenew,
    periodType: periodType,
    state: state ?? this.state,
    subscriptionKey: subscriptionKey,
  );

  AppReferEntitlementInfo withIdentifier(String id) => _copy(identifier: id);

  AppReferEntitlementInfo expired() => _copy(
    isActive: false,
    willRenew: false,
    state: BillingSubscriptionState.expired,
  );

  /// Server rule for choosing between two sources of one entitlement:
  /// active beats inactive, then the later expiry (null = lifetime) wins.
  bool beats(AppReferEntitlementInfo other) {
    if (isActive != other.isActive) return isActive;
    final a = expirationDate?.millisecondsSinceEpoch ?? _distantFuture;
    final b = other.expirationDate?.millisecondsSinceEpoch ?? _distantFuture;
    return a > b;
  }

  static const _distantFuture = 8640000000000000;

  factory AppReferEntitlementInfo.fromJson(Map<String, dynamic> json) {
    final ms = json['expiresAtMs'];
    return AppReferEntitlementInfo(
      identifier: json['id'] is String ? json['id'] as String : '',
      isActive: json['isActive'] == true,
      productIdentifier: json['productId'] is String
          ? json['productId'] as String
          : '',
      store: BillingStore.parse(json['store']),
      expirationDate: ms is num
          ? DateTime.fromMillisecondsSinceEpoch(ms.round())
          : null,
      willRenew: json['willRenew'] == true,
      periodType: BillingPeriodType.parse(json['periodType']),
      state: BillingSubscriptionState.parse(json['state']),
      subscriptionKey: json['subscriptionKey'] is String
          ? json['subscriptionKey'] as String
          : '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': identifier,
    'isActive': isActive,
    'productId': productIdentifier,
    'store': store.value,
    'expiresAtMs': expirationDate?.millisecondsSinceEpoch,
    'willRenew': willRenew,
    'periodType': periodType.name,
    'state': state.value,
    'subscriptionKey': subscriptionKey,
  };

  @override
  bool operator ==(Object other) =>
      other is AppReferEntitlementInfo &&
      other.identifier == identifier &&
      other.isActive == isActive &&
      other.productIdentifier == productIdentifier &&
      other.store == store &&
      other.expirationDate == expirationDate &&
      other.willRenew == willRenew &&
      other.periodType == periodType &&
      other.state == state &&
      other.subscriptionKey == subscriptionKey;

  @override
  int get hashCode => Object.hash(
    identifier,
    isActive,
    productIdentifier,
    store,
    expirationDate,
    willRenew,
    periodType,
    state,
    subscriptionKey,
  );
}

/// Server response for the customers/purchases/identify endpoints.
class BillingCustomerResponse {
  final AppReferCustomerInfo info;
  final String? accountToken;

  const BillingCustomerResponse(this.info, this.accountToken);

  factory BillingCustomerResponse.fromJson(Map<String, dynamic> json) =>
      BillingCustomerResponse(
        AppReferCustomerInfo.fromJson(json, source: CustomerInfoSource.server),
        json['accountToken'] is String ? json['accountToken'] as String : null,
      );
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);
