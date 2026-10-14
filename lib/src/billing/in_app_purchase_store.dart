import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart';

import '../services/logger.dart';
import 'billing_error.dart';
import 'billing_storage.dart';
import 'billing_store.dart';
import 'customer_info.dart';

/// The live store: the official `in_app_purchase` plugins. On iOS the StoreKit 2
/// path (the plugin default) puts the transaction's `jwsRepresentation` in
/// `serverVerificationData` and turns `PurchaseParam.applicationUserName` into
/// `appAccountToken`; on Android `applicationUserName` becomes the Play
/// `obfuscatedAccountId` and `serverVerificationData` is the purchase token.
class InAppPurchaseBillingStore implements BillingStoreAdapter {
  final InAppPurchase _iap;
  final BillingStorage? _storage;
  final Set<String> _consumableProductIds;
  final AppReferLogger _logger;

  InAppPurchaseBillingStore({
    BillingStorage? storage,
    Set<String> consumableProductIds = const {},
    AppReferLogger logger = const AppReferLogger(),
    InAppPurchase? iap,
  }) : _iap = iap ?? InAppPurchase.instance,
       _storage = storage,
       _consumableProductIds = consumableProductIds,
       _logger = logger;

  @override
  BillingStore get store => Platform.isIOS || Platform.isMacOS
      ? BillingStore.appStore
      : BillingStore.playStore;

  bool get _isApple => store == BillingStore.appStore;

  // --- Updates ---

  @override
  late final Stream<List<StorePurchase>> purchaseUpdates = _iap.purchaseStream
      .asyncMap((list) async {
        final result = <StorePurchase>[];
        for (final details in list) {
          if (details.status == PurchaseStatus.restored) continue;
          result.add(await _map(details));
        }
        return result;
      })
      .where((list) => list.isNotEmpty)
      .asBroadcastStream();

  Future<StorePurchase> _map(PurchaseDetails details) async {
    final status = switch (details.status) {
      PurchaseStatus.pending => StorePurchaseStatus.pending,
      PurchaseStatus.purchased => StorePurchaseStatus.purchased,
      PurchaseStatus.restored => StorePurchaseStatus.restored,
      PurchaseStatus.canceled => StorePurchaseStatus.canceled,
      PurchaseStatus.error => StorePurchaseStatus.error,
    };
    if (details is GooglePlayPurchaseDetails) {
      final token = details.verificationData.serverVerificationData;
      final kind = await _googleKind(details.productID);
      final consumable = kind == StoreProductKind.consumable;
      final acknowledged = details.billingClientPurchase.isAcknowledged;
      return StorePurchase(
        id: token.isNotEmpty
            ? token
            : (details.purchaseID ?? details.productID),
        productId: details.productID,
        store: BillingStore.playStore,
        status: status,
        purchaseToken: token,
        kind: kind,
        needsCompletion: consumable || details.pendingCompletePurchase,
        needsAcknowledgement:
            !acknowledged &&
            (status == StorePurchaseStatus.purchased ||
                status == StorePurchaseStatus.restored),
        errorMessage: details.error?.message,
        errorCode: details.error?.code,
        accountToken: _nonEmpty(
          details.billingClientPurchase.obfuscatedAccountId,
        ),
        orderId: _nonEmpty(details.billingClientPurchase.orderId),
        purchasedAt: details.billingClientPurchase.purchaseTime > 0
            ? DateTime.fromMillisecondsSinceEpoch(
                details.billingClientPurchase.purchaseTime,
              )
            : null,
        details: details,
        complete: () =>
            consumable ? _consumeGoogle(details) : _acknowledgeGoogle(details),
        acknowledge: () => _acknowledgeGoogle(details),
      );
    }
    // App Store purchases, and the plain PurchaseDetails either plugin sends
    // for a cancelled or failed purchase.
    final jws = details.verificationData.serverVerificationData;
    final json = AppleTransactionJson.parse(
      details.verificationData.localVerificationData,
    );
    return StorePurchase(
      id: details.purchaseID ?? '',
      productId: details.productID,
      store: store,
      status: status,
      signedTransaction: jws,
      kind: json?.kind,
      needsCompletion: details.pendingCompletePurchase,
      errorMessage: details.error?.message,
      errorCode: details.error?.code,
      accountToken: json?.appAccountToken,
      originalTransactionId: json?.originalTransactionId,
      purchasedAt: json?.purchaseDate,
      details: details,
      complete: () async {
        if (details.pendingCompletePurchase)
          await _iap.completePurchase(details);
      },
    );
  }

  /// Acknowledges without consuming. Throws when Play refused, so the engine
  /// retries on the next foreground.
  Future<void> _acknowledgeGoogle(GooglePlayPurchaseDetails details) async {
    if (details.billingClientPurchase.isAcknowledged) return;
    // The Android platform answers completePurchase with a BillingResultWrapper.
    final Future<Object?> pending = _iap.completePurchase(details);
    _checkGoogleResult(await pending, 'acknowledge', details.productID);
  }

  Future<void> _consumeGoogle(GooglePlayPurchaseDetails details) async {
    final addition = _iap
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    _checkGoogleResult(
      await addition.consumePurchase(details),
      'consume',
      details.productID,
    );
  }

  void _checkGoogleResult(Object? result, String action, String productId) {
    if (result is! BillingResultWrapper) return;
    // Already consumed / not owned any more: nothing left to do.
    if (result.responseCode == BillingResponse.ok ||
        result.responseCode == BillingResponse.itemNotOwned) {
      return;
    }
    throw AppReferBillingException(
      AppReferBillingErrorCode.store,
      message: '$action $productId returned ${result.responseCode}',
    );
  }

  static String? _nonEmpty(String? value) =>
      value == null || value.isEmpty ? null : value;

  // --- Products and purchases ---

  @override
  Future<List<ProductDetails>> products(List<String> productIds) async {
    final response = await _iap.queryProductDetails(productIds.toSet());
    if (response.error != null && response.productDetails.isEmpty) {
      throw AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: response.error!.message,
      );
    }
    for (final p in response.productDetails) {
      if (p is GooglePlayProductDetails) {
        _storage?.setProductKind(
          p.id,
          p.productDetails.productType == ProductType.subs ? 'subs' : 'inapp',
        );
      }
    }
    return sortProducts(response.productDetails, productIds);
  }

  @override
  Future<void> buy(ProductDetails product, StorePurchaseOptions options) async {
    final PurchaseParam param;
    if (_isApple) {
      final offer = options.promotionalOffer;
      param = (offer is SK2PromotionalOffer || options.winBackOfferId != null)
          ? Sk2PurchaseParam(
              productDetails: product,
              applicationUserName: options.accountToken,
              promotionalOffer: offer is SK2PromotionalOffer ? offer : null,
              winBackOfferId: options.winBackOfferId,
            )
          : PurchaseParam(
              productDetails: product,
              applicationUserName: options.accountToken,
            );
    } else {
      final change = options.changeSubscriptionParam;
      param = GooglePlayPurchaseParam(
        productDetails: product,
        applicationUserName: options.accountToken,
        changeSubscriptionParam: change is ChangeSubscriptionParam
            ? change
            : null,
      );
    }
    // buyConsumable(autoConsume: true) would consume before AppRefer has
    // verified the purchase; the engine consumes after. Both plugins route
    // buyConsumable(autoConsume: false) to buyNonConsumable.
    final started = await _iap.buyNonConsumable(purchaseParam: param);
    if (!started) {
      throw const AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: 'The store could not start the purchase',
      );
    }
  }

  // --- Unfinished / restore / fallback ---

  @override
  Future<List<StorePurchase>> unfinished() async {
    if (_isApple) {
      final transactions = await SK2Transaction.unfinishedTransactions();
      return [
        for (final t in transactions)
          StorePurchase(
            id: t.id,
            productId: t.productId,
            store: BillingStore.appStore,
            status: StorePurchaseStatus.purchased,
            signedTransaction: t.receiptData,
            kind: AppleTransactionJson.parse(t.jsonRepresentation)?.kind,
            accountToken: _nonEmpty(t.appAccountToken),
            originalTransactionId: _nonEmpty(t.originalId),
            purchasedAt: AppleTransactionJson.parse(
              t.jsonRepresentation,
            )?.purchaseDate,
            complete: () => SK2Transaction.finish(int.parse(t.id)),
          ),
      ];
    }
    final owned = await _googleOwned();
    return owned.where((p) => p.needsCompletion).toList();
  }

  @override
  Future<List<StorePurchase>> migrationPurchases() async {
    if (!_isApple) return _googleOwned();
    final transactions = await SK2Transaction.transactions();
    final now = DateTime.now();
    final out = <StorePurchase>[];
    for (final t in transactions) {
      final json = AppleTransactionJson.parse(t.jsonRepresentation);
      if (json == null) {
        throw const AppReferBillingException(
          AppReferBillingErrorCode.store,
          message: 'Could not read a StoreKit transaction',
        );
      }
      final entitlement = json.toEntitlement(
        fallbackProductId: t.productId,
        fallbackOriginalId: t.originalId,
        transactionId: t.id,
        fallbackAccountToken: _nonEmpty(t.appAccountToken),
      );
      if (!entitlement.grantsAccessAt(now)) continue;
      out.add(
        StorePurchase(
          id: t.id,
          productId: t.productId,
          store: BillingStore.appStore,
          status: StorePurchaseStatus.restored,
          signedTransaction: t.receiptData,
          kind: json.kind,
          accountToken: _nonEmpty(t.appAccountToken),
          originalTransactionId: _nonEmpty(t.originalId),
          purchasedAt: json.purchaseDate,
          needsCompletion: false,
        ),
      );
    }
    return out;
  }

  @override
  Future<List<StorePurchase>> restore() async {
    if (!_isApple) return _googleOwned();

    final batch = await collectAppleRestore(
      stream: _iap.purchaseStream,
      restore: _iap.restorePurchases,
      hasCurrentEntitlements: () async {
        final now = DateTime.now();
        return (await activeEntitlements()).any((e) => e.grantsAccessAt(now));
      },
    );
    return [for (final d in batch) await _map(d)];
  }

  /// StoreKit 2: the plugin emits Transaction.currentEntitlements (with their
  /// JWS) as one `restored` batch on the purchase stream, sent separately from
  /// the restorePurchases reply. If the batch does not arrive in [timeout],
  /// the device's verified transactions decide: none active means there is
  /// truly nothing to restore; otherwise the restore fails rather than
  /// reporting an empty success.
  @visibleForTesting
  static Future<List<PurchaseDetails>> collectAppleRestore({
    required Stream<List<PurchaseDetails>> stream,
    required Future<void> Function() restore,
    required Future<bool> Function() hasCurrentEntitlements,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final gotBatch = Completer<List<PurchaseDetails>>();
    final sub = stream.listen((list) {
      final batch = list
          .where((d) => d.status == PurchaseStatus.restored)
          .toList();
      if (batch.isEmpty && list.isNotEmpty) return;
      if (!gotBatch.isCompleted) gotBatch.complete(batch);
    });
    try {
      await restore();
      return await gotBatch.future.timeout(timeout);
    } on TimeoutException {
      if (!await hasCurrentEntitlements()) return const [];
      throw const AppReferBillingException(
        AppReferBillingErrorCode.store,
        message:
            'The App Store did not return the restored purchases in time; try again',
      );
    } finally {
      await sub.cancel();
    }
  }

  @override
  Future<List<StoreEntitlement>> activeEntitlements() async {
    if (_isApple) {
      // Verified Transaction.all; expired, revoked and upgraded ones are filtered later.
      final transactions = await SK2Transaction.transactions();
      return [
        for (final t in transactions)
          if (AppleTransactionJson.parse(t.jsonRepresentation) case final json?)
            json.toEntitlement(
              fallbackProductId: t.productId,
              fallbackOriginalId: t.originalId,
              transactionId: t.id,
              fallbackAccountToken: _nonEmpty(t.appAccountToken),
            ),
      ];
    }
    final owned = await _googleOwned();
    return [
      for (final p in owned)
        StoreEntitlement(
          productId: p.productId,
          originalId: p.purchaseToken ?? p.id,
          kind: p.kind ?? StoreProductKind.autoRenewable,
          store: BillingStore.playStore,
          transactionId: p.id,
          accountToken: p.accountToken,
        ),
    ];
  }

  @override
  Future<void> sync() async {
    if (!_isApple) return;
    await _iap
        .getPlatformAddition<InAppPurchaseStoreKitPlatformAddition>()
        .sync();
  }

  /// Google purchases the account currently owns (active subscriptions and
  /// unconsumed one-time products), excluding pending ones.
  Future<List<StorePurchase>> _googleOwned() async {
    final addition = _iap
        .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final response = await addition.queryPastPurchases();
    if (response.error != null && response.pastPurchases.isEmpty) {
      throw AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: response.error!.message,
      );
    }
    final result = <StorePurchase>[];
    for (final details in response.pastPurchases) {
      if (details.billingClientPurchase.purchaseState !=
          PurchaseStateWrapper.purchased)
        continue;
      final mapped = await _map(details);
      result.add(
        StorePurchase(
          id: mapped.id,
          productId: mapped.productId,
          store: mapped.store,
          status: StorePurchaseStatus.restored,
          purchaseToken: mapped.purchaseToken,
          kind: mapped.kind,
          needsCompletion: mapped.needsCompletion,
          needsAcknowledgement: mapped.needsAcknowledgement,
          accountToken: mapped.accountToken,
          orderId: mapped.orderId,
          purchasedAt: mapped.purchasedAt,
          details: details,
          complete: mapped.complete,
          acknowledge: mapped.acknowledge,
        ),
      );
    }
    return result;
  }

  /// Subscription vs one-time, from the store's product details (cached).
  Future<StoreProductKind> _googleKind(String productId) async {
    var raw = _storage?.productKinds[productId];
    if (raw == null) {
      try {
        final response = await _iap.queryProductDetails({productId});
        for (final p in response.productDetails) {
          if (p is GooglePlayProductDetails && p.id == productId) {
            raw = p.productDetails.productType == ProductType.subs
                ? 'subs'
                : 'inapp';
            _storage?.setProductKind(productId, raw);
            break;
          }
        }
      } catch (e) {
        _logger.warn(
          'Billing: could not look up product type of $productId: $e',
        );
      }
    }
    if (raw == 'inapp') {
      return _consumableProductIds.contains(productId)
          ? StoreProductKind.consumable
          : StoreProductKind.nonConsumable;
    }
    if (raw == null && _consumableProductIds.contains(productId)) {
      return StoreProductKind.consumable;
    }
    return StoreProductKind.autoRenewable;
  }
}

/// Products in the requested order (stable: Google returns one entry per
/// subscription offer, kept in store order).
List<T> sortProducts<T extends ProductDetails>(
  List<T> products,
  List<String> productIds,
) {
  final order = {
    for (var i = productIds.length - 1; i >= 0; i--) productIds[i]: i,
  };
  final indexed = [for (var i = 0; i < products.length; i++) (i, products[i])];
  indexed.sort((a, b) {
    final byId = (order[a.$2.id] ?? productIds.length).compareTo(
      order[b.$2.id] ?? productIds.length,
    );
    return byId != 0 ? byId : a.$1.compareTo(b.$1);
  });
  return [for (final e in indexed) e.$2];
}

/// The fields billing needs from a StoreKit 2 `Transaction.jsonRepresentation`.
class AppleTransactionJson {
  final String? productId;
  final String? originalTransactionId;
  final StoreProductKind kind;
  final DateTime? expiresDate;
  final DateTime? revocationDate;
  final bool isUpgraded;
  final BillingPeriodType periodType;
  final String? appAccountToken;
  final DateTime? purchaseDate;

  const AppleTransactionJson({
    this.productId,
    this.originalTransactionId,
    required this.kind,
    this.expiresDate,
    this.revocationDate,
    this.isUpgraded = false,
    this.periodType = BillingPeriodType.normal,
    this.appAccountToken,
    this.purchaseDate,
  });

  static AppleTransactionJson? parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final kind = switch (json['type']) {
        'Auto-Renewable Subscription' => StoreProductKind.autoRenewable,
        'Non-Renewing Subscription' => StoreProductKind.nonRenewable,
        'Consumable' => StoreProductKind.consumable,
        'Non-Consumable' => StoreProductKind.nonConsumable,
        _ => null,
      };
      if (kind == null) return null;
      final offerType = json['offerType'];
      final periodType = switch (offerType) {
        1 =>
          json['offerDiscountType'] == 'FREE_TRIAL'
              ? BillingPeriodType.trial
              : BillingPeriodType.intro,
        2 || 3 || 4 => BillingPeriodType.promotional,
        _ => BillingPeriodType.normal,
      };
      return AppleTransactionJson(
        productId: json['productId'] as String?,
        originalTransactionId: json['originalTransactionId']?.toString(),
        kind: kind,
        expiresDate: _date(json['expiresDate']),
        revocationDate: _date(json['revocationDate']),
        isUpgraded: json['isUpgraded'] == true,
        periodType: periodType,
        appAccountToken:
            json['appAccountToken'] is String &&
                (json['appAccountToken'] as String).isNotEmpty
            ? json['appAccountToken'] as String
            : null,
        purchaseDate: _date(json['purchaseDate']),
      );
    } catch (_) {
      return null;
    }
  }

  StoreEntitlement toEntitlement({
    required String fallbackProductId,
    required String fallbackOriginalId,
    String? transactionId,
    String? fallbackAccountToken,
  }) => StoreEntitlement(
    productId: productId ?? fallbackProductId,
    originalId: originalTransactionId ?? fallbackOriginalId,
    kind: kind,
    store: BillingStore.appStore,
    expirationDate: expiresDate,
    revocationDate: revocationDate,
    isUpgraded: isUpgraded,
    periodType: periodType,
    transactionId: transactionId,
    accountToken: appAccountToken ?? fallbackAccountToken,
  );

  static DateTime? _date(Object? ms) =>
      ms is num ? DateTime.fromMillisecondsSinceEpoch(ms.round()) : null;
}
