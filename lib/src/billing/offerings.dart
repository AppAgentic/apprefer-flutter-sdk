import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

enum PackageType {
  weekly,
  monthly,
  twoMonth,
  threeMonth,
  sixMonth,
  annual,
  lifetime,
  custom,
  unknown,
}

PackageType packageType(String id, String? raw) {
  final name = id.startsWith(r'$ar_') || id.startsWith(r'$rc_')
      ? id.substring(4)
      : raw;
  return switch (name) {
    'weekly' => PackageType.weekly,
    'monthly' => PackageType.monthly,
    'two_month' || 'twoMonth' => PackageType.twoMonth,
    'three_month' || 'threeMonth' => PackageType.threeMonth,
    'six_month' || 'sixMonth' => PackageType.sixMonth,
    'annual' => PackageType.annual,
    'lifetime' => PackageType.lifetime,
    _ => PackageType.custom,
  };
}

class OfferingContext {
  final String? targetingRuleId, experimentId, variantId;
  const OfferingContext({
    this.targetingRuleId,
    this.experimentId,
    this.variantId,
  });
  factory OfferingContext.fromJson(Map<String, dynamic> json) =>
      OfferingContext(
        targetingRuleId: json['targetingRuleId'] as String?,
        experimentId: json['experimentId'] as String?,
        variantId: json['variantId'] as String?,
      );
}

class PresentedOfferingContext extends OfferingContext {
  final String offeringId, packageId;
  final String? placementId;
  const PresentedOfferingContext({
    required this.offeringId,
    required this.packageId,
    this.placementId,
    super.targetingRuleId,
    super.experimentId,
    super.variantId,
  });
  Map<String, dynamic> toJson() => {
    'offeringId': offeringId,
    'packageId': packageId,
    if (placementId != null) 'placementId': placementId,
    if (targetingRuleId != null) 'targetingRuleId': targetingRuleId,
    if (experimentId != null) 'experimentId': experimentId,
    if (variantId != null) 'variantId': variantId,
  };
  factory PresentedOfferingContext.fromJson(Map<String, dynamic> json) =>
      PresentedOfferingContext(
        offeringId: json['offeringId'] as String,
        packageId: json['packageId'] as String,
        placementId: json['placementId'] as String?,
        targetingRuleId: json['targetingRuleId'] as String?,
        experimentId: json['experimentId'] as String?,
        variantId: json['variantId'] as String?,
      );
}

class AppReferPackage {
  final String identifier, offeringIdentifier;
  final PackageType packageType;
  final ProductDetails storeProduct;
  final PresentedOfferingContext presentedOfferingContext;
  final String? offerToken;
  const AppReferPackage(
    this.identifier,
    this.packageType,
    this.storeProduct,
    this.offeringIdentifier,
    this.presentedOfferingContext, {
    this.offerToken,
  });
  AppReferPackage forPlacement(String id) => AppReferPackage(
    identifier,
    packageType,
    storeProduct,
    offeringIdentifier,
    PresentedOfferingContext.fromJson({
      ...presentedOfferingContext.toJson(),
      'placementId': id,
    }),
    offerToken: offerToken,
  );
}

class AppReferOffering {
  final String identifier, displayName;
  final Map<String, dynamic> metadata;
  final List<AppReferPackage> availablePackages;
  const AppReferOffering(
    this.identifier,
    this.displayName,
    this.metadata,
    this.availablePackages,
  );
  AppReferPackage? package(String identifier) =>
      availablePackages.where((p) => p.identifier == identifier).firstOrNull;
  AppReferPackage? _type(PackageType type) =>
      availablePackages.where((p) => p.packageType == type).firstOrNull;
  AppReferPackage? get weekly => _type(PackageType.weekly);
  AppReferPackage? get monthly => _type(PackageType.monthly);
  AppReferPackage? get twoMonth => _type(PackageType.twoMonth);
  AppReferPackage? get threeMonth => _type(PackageType.threeMonth);
  AppReferPackage? get sixMonth => _type(PackageType.sixMonth);
  AppReferPackage? get annual => _type(PackageType.annual);
  AppReferPackage? get lifetime => _type(PackageType.lifetime);
  AppReferOffering forPlacement(String id) => AppReferOffering(
    identifier,
    displayName,
    metadata,
    availablePackages.map((p) => p.forPlacement(id)).toList(),
  );
}

class AppReferOfferings {
  final AppReferOffering? current;
  final Map<String, AppReferOffering> all;
  final OfferingContext context;
  final Map<String, String?> _placements;
  const AppReferOfferings(
    this.current,
    this.all,
    this.context,
    this._placements,
  );
  AppReferOffering? currentOffering(String forPlacement) {
    if (_placements.containsKey(forPlacement)) {
      final id = _placements[forPlacement];
      return id == null ? null : all[id]?.forPlacement(forPlacement);
    }
    return current?.forPlacement(forPlacement);
  }
}

Future<AppReferOfferings> resolveOfferings(
  Map<String, dynamic> json,
  Future<List<ProductDetails>> Function(List<String>) products,
) async {
  final offerings = (json['offerings'] as List).cast<Map>();
  final ids = <String>{};
  for (final o in offerings) {
    for (final p in (o['packages'] as List? ?? [])) {
      if (p['productId'] is String)
        ids.add((p['productId'] as String).split(':').first);
    }
  }
  final loaded = await products(ids.toList());
  final context = OfferingContext.fromJson(
    Map<String, dynamic>.from(json['context'] as Map? ?? {}),
  );
  final all = <String, AppReferOffering>{};
  for (final o in offerings) {
    final id = o['id'] as String;
    final packages = <AppReferPackage>[];
    for (final p in (o['packages'] as List? ?? [])) {
      if (p['productId'] is! String) continue;
      final parts = (p['productId'] as String).split(':');
      final type = packageType(p['id'] as String, p['packageType'] as String?);
      final candidates = loaded.where((v) => v.id == parts.first).toList();
      ProductDetails? product;
      String? token;
      final period = {
        PackageType.weekly: 'P1W',
        PackageType.monthly: 'P1M',
        PackageType.twoMonth: 'P2M',
        PackageType.threeMonth: 'P3M',
        PackageType.sixMonth: 'P6M',
        PackageType.annual: 'P1Y',
      }[type];
      for (final candidate in candidates) {
        if (candidate is GooglePlayProductDetails &&
            candidate.subscriptionIndex != null) {
          final offer = candidate
              .productDetails
              .subscriptionOfferDetails![candidate.subscriptionIndex!];
          if (parts.length > 1 && offer.basePlanId != parts[1]) continue;
          product ??= candidate;
          token ??= offer.offerIdToken;
          if (offer.pricingPhases.last.billingPeriod == period &&
              offer.offerId == null) {
            product = candidate;
            token = offer.offerIdToken;
            break;
          }
        } else if (parts.length == 1) {
          product = candidate;
          break;
        }
      }
      if (product == null) continue;
      packages.add(
        AppReferPackage(
          p['id'] as String,
          type,
          product,
          id,
          PresentedOfferingContext(
            offeringId: id,
            packageId: p['id'] as String,
            targetingRuleId: context.targetingRuleId,
            experimentId: context.experimentId,
            variantId: context.variantId,
          ),
          offerToken: token,
        ),
      );
    }
    all[id] = AppReferOffering(
      id,
      o['displayName'] as String? ?? id,
      Map<String, dynamic>.from(o['metadata'] as Map? ?? {}),
      packages,
    );
  }
  return AppReferOfferings(
    all[json['currentOfferingId']],
    all,
    context,
    Map<String, String?>.from(json['placements'] as Map? ?? {}),
  );
}

typedef Offerings = AppReferOfferings;
typedef Offering = AppReferOffering;
typedef Package = AppReferPackage;
