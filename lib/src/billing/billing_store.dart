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

  /// Google: not acknowledged yet (Google refunds a purchase left
  /// unacknowledged for 3 days). Apple: same as [needsCompletion].
  final bool needsAcknowledgement;
  final String? errorMessage;

  /// Apple `appAccountToken` / Google `obfuscatedAccountId` the purchase was
  /// made with, when the store reports one.
  final String? accountToken;

  /// Apple `originalTransactionId`, when the store reports one.
  final String? originalTransactionId;

  /// Google Play order id (`GPA.1234-5678-9012-34567`, renewals end in `..N`).
  final String? orderId;

  /// When the store says the purchase was made, when it does.
  final DateTime? purchasedAt;

  /// The plugin object, handed back to the app in `PurchaseResult`.
  final PurchaseDetails? details;

  /// `completePurchase` (Apple finish / Google acknowledge), or consume for
  /// Google consumables. Throws when the store refused.
  final Future<void> Function() complete;

  /// Google acknowledge without consuming, so a consumable AppRefer has not
  /// recorded yet stays recoverable. Same as [complete] everywhere else.
  final Future<void> Function() acknowledge;

  StorePurchase({
    required this.id,
    required this.productId,
    required this.store,
    required this.status,
    this.signedTransaction,
    this.purchaseToken,
    this.kind,
    this.needsCompletion = true,
    bool? needsAcknowledgement,
    this.errorMessage,
    this.accountToken,
    this.originalTransactionId,
    this.orderId,
    this.purchasedAt,
    this.details,
    Future<void> Function()? complete,
    Future<void> Function()? acknowledge,
  }) : needsAcknowledgement = needsAcknowledgement ?? needsCompletion,
       complete = complete ?? _noop,
       acknowledge = acknowledge ?? complete ?? _noop;

  static Future<void> _noop() async {}

  static final _googleRenewalOrder = RegExp(r'\.\.\d+$');

  /// A subscription renewal, not a purchase someone started: Apple when the
  /// original transaction id differs from the transaction id, Google when the
  /// order id carries a `..N` renewal suffix (not the first order of its
  /// chain). A renewal never matches or uses up a saved purchase intent.
  bool get isRenewal => switch (store) {
    BillingStore.appStore =>
      originalTransactionId != null &&
          originalTransactionId!.isNotEmpty &&
          id.isNotEmpty &&
          originalTransactionId != id,
    BillingStore.playStore =>
      orderId != null && _googleRenewalOrder.hasMatch(orderId!),
    _ => false,
  };

  /// A Google Play consumable (consumed only after AppRefer recorded it).
  bool get isGoogleConsumable =>
      store == BillingStore.playStore && kind == StoreProductKind.consumable;

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

  /// Apple transaction id / Google purchase token: the retry-queue key.
  final String? transactionId;

  /// Apple `appAccountToken` / Google `obfuscatedAccountId`, when set.
  final String? accountToken;

  const StoreEntitlement({
    required this.productId,
    required this.originalId,
    required this.kind,
    required this.store,
    this.expirationDate,
    this.revocationDate,
    this.isUpgraded = false,
    this.periodType = BillingPeriodType.normal,
    this.transactionId,
    this.accountToken,
  });

  /// Not revoked, not upgraded away, not expired, not consumable.
  bool grantsAccessAt(DateTime now) {
    if (kind == StoreProductKind.consumable ||
        revocationDate != null ||
        isUpgraded) {
      return false;
    }
    final expires = expirationDate;
    return expires == null || expires.isAfter(now);
  }
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
  /// AppRefer needs to verify it. Throws rather than returning an incomplete
  /// list (e.g. when the App Store's answer did not arrive in time).
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
      if (!p.grantsAccessAt(now)) continue;
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
