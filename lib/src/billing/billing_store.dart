import 'package:in_app_purchase/in_app_purchase.dart';

import 'customer_info.dart';

enum StoreProductKind { autoRenewable, nonRenewable, consumable, nonConsumable }

enum StorePurchaseStatus { pending, purchased, restored, canceled, error }

/// One purchase delivered by the store (new purchase, renewal, restore or
/// left unfinished by a previous launch). Plugin-independent so the engine is
/// testable without platform channels.
class StorePurchase {
  /// Apple transaction id / Google purchase token. Retry-queue and dedupe key.
  final String id;
  final String productId;
  final BillingStore store;
  final StorePurchaseStatus status;

  /// Apple StoreKit 2 `jwsRepresentation` (sent as `signedTransaction`).
  final String? signedTransaction;

  /// Google Play purchase token.
  final String? purchaseToken;

  /// Null when the store did not say (the engine then treats it as a subscription).
  final StoreProductKind? kind;

  /// Whether the store still waits for `completePurchase` / consume.
  final bool needsCompletion;
  final String? errorMessage;

  /// The plugin object, handed back to the app in `PurchaseResult`.
  final PurchaseDetails? details;

  /// `completePurchase` (Apple finish / Google acknowledge), or consume for
  /// Google consumables.
  final Future<void> Function() complete;

  StorePurchase({
    required this.id,
    required this.productId,
    required this.store,
    required this.status,
    this.signedTransaction,
    this.purchaseToken,
    this.kind,
    this.needsCompletion = true,
    this.errorMessage,
    this.details,
    Future<void> Function()? complete,
  }) : complete = complete ?? _noop;

  static Future<void> _noop() async {}

  /// The store fields of the `/purchases` body, or null when the store gave
  /// nothing AppRefer can verify.
  Map<String, String>? get storeFields {
    switch (store) {
      case BillingStore.appStore:
        final jws = signedTransaction;
        if (jws == null || jws.isEmpty) return null;
        return {'store': 'app_store', 'signedTransaction': jws};
      case BillingStore.playStore:
        final token = purchaseToken;
        if (token == null || token.isEmpty) return null;
        return {
          'store': 'play_store',
          'purchaseToken': token,
          'productId': productId,
          'productType': switch (kind) {
            StoreProductKind.consumable => 'consumable',
            StoreProductKind.nonConsumable => 'non_consumable',
            _ => 'subscription',
          },
        };
      default:
        return null;
    }
  }
}

/// A store-verified purchase that currently grants access, used for the
/// outage fallback (Apple: verified `Transaction.all`; Google: owned purchases).
class StoreEntitlement {
  final String productId;
  final String originalId;
  final StoreProductKind kind;
  final BillingStore store;
  final DateTime? expirationDate;
  final DateTime? revocationDate;
  final bool isUpgraded;
  final BillingPeriodType periodType;

  const StoreEntitlement({
    required this.productId,
    required this.originalId,
    required this.kind,
    required this.store,
    this.expirationDate,
    this.revocationDate,
    this.isUpgraded = false,
    this.periodType = BillingPeriodType.normal,
  });
}

/// Options for one purchase, passed through to the platform plugin.
class StorePurchaseOptions {
  /// Apple `appAccountToken` / Google `obfuscatedAccountId`.
  final String? accountToken;
  final Object? promotionalOffer;
  final String? winBackOfferId;
  final Object? changeSubscriptionParam;

  const StorePurchaseOptions({
    this.accountToken,
    this.promotionalOffer,
    this.winBackOfferId,
    this.changeSubscriptionParam,
  });
}

/// The store behind an interface so the engine can be tested with fakes.
abstract class BillingStoreAdapter {
  BillingStore get store;

  /// Purchase updates (new purchases, renewals, Ask to Buy approvals,
  /// cancellations). `restored` purchases are delivered by [restore] instead.
  Stream<List<StorePurchase>> get purchaseUpdates;

  /// Product details, in the order requested.
  Future<List<ProductDetails>> products(List<String> productIds);

  /// Opens the purchase sheet. The result arrives on [purchaseUpdates].
  Future<void> buy(ProductDetails product, StorePurchaseOptions options);

  /// Purchases the store still waits to have completed (crash between
  /// purchase and complete, Google purchases never acknowledged).
  Future<List<StorePurchase>> unfinished();

  /// Store-verified purchases that currently grant access.
  Future<List<StoreEntitlement>> activeEntitlements();

  /// Apple `AppStore.sync()` (may show a sign-in sheet); no-op on Google.
  Future<void> sync();

  /// Every purchase the store currently owns for this account, with the data
  /// AppRefer needs to verify it.
  Future<List<StorePurchase>> restore();
}

/// Device-side entitlement logic: the outage fallback.
class LocalEntitlements {
  /// Entitlement ids for a product: the configured map, then what the server has
  /// told us before, then the default (the server's own default is `premium`).
  static List<String> entitlementIds(
    String productId, {
    required Map<String, List<String>> configured,
    required Map<String, List<String>> learned,
    String? defaultEntitlement,
  }) {
    final c = configured[productId];
    if (c != null && c.isNotEmpty) return c;
    final l = learned[productId];
    if (l != null && l.isNotEmpty) return l;
    return [defaultEntitlement ?? 'premium'];
  }

  /// Entitlements granted by store-verified purchases: not revoked, not
  /// upgraded away, not expired, not consumable.
  static ({
    Map<String, AppReferEntitlementInfo> entitlements,
    Set<String> activeSubscriptions,
  })
  compute(
    List<StoreEntitlement> purchases, {
    required Map<String, List<String>> configured,
    required Map<String, List<String>> learned,
    String? defaultEntitlement,
    required DateTime now,
  }) {
    final entitlements = <String, AppReferEntitlementInfo>{};
    final activeSubscriptions = <String>{};

    for (final p in purchases) {
      if (p.kind == StoreProductKind.consumable ||
          p.revocationDate != null ||
          p.isUpgraded) {
        continue;
      }
      final expires = p.expirationDate;
      if (expires != null && !expires.isAfter(now)) continue;
      if (p.kind == StoreProductKind.autoRenewable) {
        activeSubscriptions.add(p.productId);
      }

      for (final id in entitlementIds(
        p.productId,
        configured: configured,
        learned: learned,
        defaultEntitlement: defaultEntitlement,
      )) {
        final info = AppReferEntitlementInfo(
          identifier: id,
          isActive: true,
          productIdentifier: p.productId,
          store: p.store,
          expirationDate: p.expirationDate,
          // Renewal status needs another store call; unknown here.
          willRenew: false,
          periodType: p.periodType,
          state: BillingSubscriptionState.active,
          subscriptionKey: p.originalId,
        );
        final current = entitlements[id];
        if (current != null && !info.beats(current)) continue;
        entitlements[id] = info;
      }
    }
    return (
      entitlements: entitlements,
      activeSubscriptions: activeSubscriptions,
    );
  }

  /// Merges device entitlements into a server snapshot (fresh or cached). Per
  /// entitlement the server rule applies: active beats inactive, later expiry wins.
  static AppReferCustomerInfo merge({
    required AppReferCustomerInfo? server,
    required ({
      Map<String, AppReferEntitlementInfo> entitlements,
      Set<String> activeSubscriptions,
    })
    local,
    required String appUserId,
    required DateTime now,
    required CustomerInfoSource source,
  }) {
    final all = Map<String, AppReferEntitlementInfo>.of(
      server?.entitlements.all ?? const {},
    );
    local.entitlements.forEach((id, info) {
      final current = all[id];
      if (current != null && !info.beats(current)) return;
      all[id] = info;
    });
    return AppReferCustomerInfo(
      appUserId: appUserId,
      entitlements: EntitlementInfos(all),
      activeSubscriptions: {
        ...?server?.activeSubscriptions,
        ...local.activeSubscriptions,
      },
      requestDate: now,
      source: source,
    );
  }
}
