// Offer cards in the help chat (server: lib/support/offers.ts). A team member or the app's AI
// assistant attaches one of the app's AppRefer Billing offerings to a reply; the chat draws it as
// a card with the store's own prices and, when tapped, hands it to the app's own paywall through
// `AppReferSDK.support.onOffer`. The SDK never shows a paywall, never starts a purchase and never
// shows a price, discount or deadline of its own. A purchase is confirmed by Billing as usual.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart' show ProductDetails;
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart'
    show AppStoreProduct2Details, AppStoreProductDetails;
import 'package:in_app_purchase_storekit/store_kit_2_wrappers.dart'
    show SK2SubscriptionPeriodUnit;
import 'package:in_app_purchase_storekit/store_kit_wrappers.dart'
    show SKSubscriptionPeriodUnit;

import '../billing/apprefer_billing.dart';
import 'support_api.dart';
import 'support_strings.dart';

/// What `AppReferSDK.support.onOffer` receives when the customer taps an
/// offer card: open your own paywall for [offeringId] (e.g.
/// `(await AppReferBilling.offerings()).all[offer.offeringId]`), with
/// [packageId] preselected when set. Opening it is not a purchase.
@immutable
class AppReferSupportOffer {
  const AppReferSupportOffer({
    required this.cardId,
    required this.conversationId,
    required this.offeringId,
    this.packageId,
  });

  /// Stable id of the card (`ofc_…`), the same on every device and in your
  /// team inbox.
  final String cardId;
  final String conversationId;

  /// One of your app's AppRefer Billing offerings.
  final String offeringId;

  /// The package the team pointed at, or null for the whole offering.
  final String? packageId;

  @override
  bool operator ==(Object other) =>
      other is AppReferSupportOffer &&
      other.cardId == cardId &&
      other.conversationId == conversationId &&
      other.offeringId == offeringId &&
      other.packageId == packageId;

  @override
  int get hashCode =>
      Object.hash(cardId, conversationId, offeringId, packageId);
}

/// One package on an offer card. Prices are never part of it.
@immutable
class AppReferSupportOfferPackage {
  const AppReferSupportOfferPackage({
    required this.id,
    required this.packageType,
    required this.productId,
    this.displayName,
    this.current = false,
  });

  final String id;

  /// weekly, monthly, two_month, three_month, six_month, annual, lifetime or custom.
  final String packageType;

  /// The name the app gave the package in AppRefer, if any.
  final String? displayName;

  /// The store product on this platform.
  final String productId;

  /// The customer's current plan or an owned purchase (only checked for
  /// verified customers).
  final bool current;

  @override
  bool operator ==(Object other) =>
      other is AppReferSupportOfferPackage &&
      other.id == id &&
      other.packageType == packageType &&
      other.displayName == displayName &&
      other.productId == productId &&
      other.current == current;

  @override
  int get hashCode =>
      Object.hash(id, packageType, displayName, productId, current);
}

/// An offer card as the server sends it, with its state now.
@immutable
class AppReferSupportOfferCard {
  const AppReferSupportOfferCard({
    required this.cardId,
    required this.offeringId,
    required this.status,
    required this.packages,
    this.packageId,
    this.reason,
  });

  final String cardId, offeringId;
  final String? packageId;

  /// available, owned or unavailable.
  final String status;

  /// Why it can't be opened: owned, revoked, expired, offering_unavailable,
  /// not_on_platform, account_changed.
  final String? reason;
  final List<AppReferSupportOfferPackage> packages;

  bool get isAvailable => status == 'available';

  /// The packages the card points at (one when the team picked a package).
  List<AppReferSupportOfferPackage> get shownPackages {
    if (packageId == null) return packages;
    final picked = packages.where((p) => p.id == packageId).toList();
    return picked.isEmpty ? packages : picked;
  }

  /// Null when the value isn't a card (an older or unexpected payload): no
  /// broken card is drawn.
  static AppReferSupportOfferCard? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final cardId = raw['cardId'],
        offeringId = raw['offeringId'],
        status = raw['status'];
    if (cardId is! String || offeringId is! String || status is! String)
      return null;
    final packages = <AppReferSupportOfferPackage>[];
    for (final p
        in (raw['packages'] is List ? raw['packages'] as List : const [])) {
      if (p is! Map || p['id'] is! String || p['productId'] is! String)
        continue;
      final name = p['displayName'];
      packages.add(
        AppReferSupportOfferPackage(
          id: p['id'] as String,
          packageType: p['packageType'] is String
              ? p['packageType'] as String
              : 'custom',
          productId: p['productId'] as String,
          displayName: name is String && name.trim().isNotEmpty ? name : null,
          current: p['current'] == true,
        ),
      );
    }
    return AppReferSupportOfferCard(
      cardId: cardId,
      offeringId: offeringId,
      status: status,
      packageId: raw['packageId'] is String ? raw['packageId'] as String : null,
      reason: raw['reason'] is String ? raw['reason'] as String : null,
      packages: packages,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppReferSupportOfferCard &&
      other.cardId == cardId &&
      other.offeringId == offeringId &&
      other.packageId == packageId &&
      other.status == status &&
      other.reason == reason &&
      listEquals(other.packages, packages);

  @override
  int get hashCode => Object.hash(
    cardId,
    offeringId,
    packageId,
    status,
    reason,
    Object.hashAll(packages),
  );
}

/// How the chat draws a card: from the server's state and whether the app
/// connected its paywall.
enum SupportOfferLook {
  open,
  owned,
  unavailable,

  /// Available, but the app set no `onOffer`: honest text, no button.
  unsupported;

  static SupportOfferLook of(AppReferSupportOfferCard card, bool hasHandler) =>
      switch (card.status) {
        'available' => hasHandler ? open : unsupported,
        'owned' => owned,
        _ => unavailable,
      };

  String? get notice => switch (this) {
    open => null,
    owned => SupportStrings.text('support.offer.owned'),
    unavailable => SupportStrings.text('support.offer.unavailable'),
    unsupported => SupportStrings.text('support.offer.unsupported'),
  };
}

const _typeKeys = {
  'weekly': 'weekly',
  'monthly': 'monthly',
  'two_month': 'twoMonth',
  'three_month': 'threeMonth',
  'six_month': 'sixMonth',
  'annual': 'annual',
  'lifetime': 'lifetime',
};

/// The app's own name for the package, else its length in the chat's
/// language, else the store's product name, else "Option".
String supportOfferLabel(AppReferSupportOfferPackage p, String? storeName) {
  final name = p.displayName?.trim();
  if (name != null && name.isNotEmpty) return name;
  final key = _typeKeys[p.packageType];
  if (key != null) return SupportStrings.text('support.offer.package.$key');
  if (storeName != null && storeName.trim().isNotEmpty) return storeName;
  return SupportStrings.text('support.offer.package.custom');
}

/// The `support.offer.price.*` key for a store billing period (ISO 8601,
/// e.g. `P1Y`), or null for one-time purchases and periods the table doesn't
/// word (the bare store price is shown).
String? supportOfferPeriodKey(String? iso) {
  final m = RegExp(r'^P(\d+)([DWMY])$').firstMatch(iso?.toUpperCase() ?? '');
  final n = int.tryParse(m?.group(1) ?? '');
  if (m == null || n == null) return null;
  return switch ((m.group(2), n)) {
    ('D', 7) || ('W', 1) => 'week',
    ('D', 28) || ('W', 4) => 'fourWeeks',
    ('M', 1) => 'month',
    ('M', 2) => 'twoMonths',
    ('M', 3) => 'threeMonths',
    ('M', 6) => 'sixMonths',
    ('M', 12) || ('Y', 1) => 'year',
    _ => null,
  };
}

/// The store's own regular price with the store's own billing period, e.g.
/// "£29.99/year".
String supportOfferPriceText(SupportOfferPrice p) {
  final key = supportOfferPeriodKey(p.period);
  return key == null
      ? p.price
      : SupportStrings.text('support.offer.price.$key', {'price': p.price});
}

/// The tag on a row the customer already has: "Purchased" for a one-off,
/// "Current plan" for a subscription.
String? supportOfferOwnedTag(
  AppReferSupportOfferPackage p,
  SupportOfferPrice? price,
) {
  if (!p.current) return null;
  final oneOff = price?.oneTime ?? p.packageType == 'lifetime';
  return SupportStrings.text(
    oneOff ? 'support.offer.purchased' : 'support.offer.current',
  );
}

/// A store price and product name for one package, from AppRefer Billing:
/// the regular price (never a trial or introductory phase) with the store's
/// billing period (ISO 8601; null for one-time purchases).
@immutable
class SupportOfferPrice {
  const SupportOfferPrice(this.price, this.name, {this.period, this.oneTime});
  final String price;
  final String? name;
  final String? period;

  /// A one-time purchase (credit pack, lifetime unlock); null when the store
  /// didn't say.
  final bool? oneTime;

  @override
  bool operator ==(Object other) =>
      other is SupportOfferPrice &&
      other.price == price &&
      other.name == name &&
      other.period == period &&
      other.oneTime == oneTime;

  @override
  int get hashCode => Object.hash(price, name, period, oneTime);
}

/// Store prices for the offerings on screen, from AppRefer Billing (the
/// store's own formatted regular price). Empty when the app doesn't use
/// AppRefer Billing: cards then list packages without prices, never with
/// made-up ones.
Future<Map<String, Map<String, SupportOfferPrice>>> supportOfferPrices(
  Set<String> offeringIds,
) async {
  if (offeringIds.isEmpty || !AppReferBilling.isConfigured) return const {};
  try {
    final all = (await AppReferBilling.offerings()).all;
    return {
      for (final id in offeringIds)
        if (all[id] != null)
          id: {
            for (final p in all[id]!.availablePackages)
              p.identifier: SupportOfferPrice(
                supportStorePrice(p.storeProduct),
                p.storeProduct.title,
                period: supportStorePeriod(p.storeProduct),
                oneTime: supportStoreOneTime(p.storeProduct),
              ),
          },
    };
  } catch (_) {
    return const {};
  }
}

/// The regular price: on Google Play the last (recurring) pricing phase of
/// the offer, never a free-trial phase; elsewhere the store's price.
String supportStorePrice(ProductDetails product) {
  if (product is GooglePlayProductDetails) {
    final index = product.subscriptionIndex;
    final offers = product.productDetails.subscriptionOfferDetails;
    if (index != null &&
        offers != null &&
        index < offers.length &&
        offers[index].pricingPhases.isNotEmpty) {
      return offers[index].pricingPhases.last.formattedPrice;
    }
    return product.price;
  }
  return product.price;
}

/// The store's billing period of the price [supportStorePrice] shows (ISO
/// 8601): Google Play's recurring phase, StoreKit's subscription period.
String? supportStorePeriod(ProductDetails product) {
  if (product is GooglePlayProductDetails) {
    final index = product.subscriptionIndex;
    final offers = product.productDetails.subscriptionOfferDetails;
    if (index == null ||
        offers == null ||
        index >= offers.length ||
        offers[index].pricingPhases.isEmpty) {
      return null;
    }
    final period = offers[index].pricingPhases.last.billingPeriod;
    return period.isEmpty ? null : period;
  }
  if (product is AppStoreProduct2Details) {
    final period = product.sk2Product.subscription?.subscriptionPeriod;
    if (period == null) return null;
    final unit = switch (period.unit) {
      SK2SubscriptionPeriodUnit.day => 'D',
      SK2SubscriptionPeriodUnit.week => 'W',
      SK2SubscriptionPeriodUnit.month => 'M',
      SK2SubscriptionPeriodUnit.year => 'Y',
    };
    return 'P${period.value}$unit';
  }
  if (product is AppStoreProductDetails) {
    final period = product.skProduct.subscriptionPeriod;
    if (period == null || period.numberOfUnits <= 0) return null;
    final unit = switch (period.unit) {
      SKSubscriptionPeriodUnit.day => 'D',
      SKSubscriptionPeriodUnit.week => 'W',
      SKSubscriptionPeriodUnit.month => 'M',
      SKSubscriptionPeriodUnit.year => 'Y',
    };
    return 'P${period.numberOfUnits}$unit';
  }
  return null;
}

/// Whether the product is a one-time purchase; null when the store type
/// doesn't say.
bool? supportStoreOneTime(ProductDetails product) {
  if (product is GooglePlayProductDetails)
    return product.subscriptionIndex == null;
  if (product is AppStoreProduct2Details) {
    return product.sk2Product.subscription == null;
  }
  if (product is AppStoreProductDetails) {
    return product.skProduct.subscriptionPeriod == null;
  }
  return null;
}

/// A receipt the server hasn't confirmed yet. Same id on every retry, so
/// it's stored once.
@immutable
class SupportOfferReceipt {
  const SupportOfferReceipt({
    required this.conversationId,
    required this.cardId,
    required this.kind,
    required this.clientEventId,
    required this.occurredAt,
    this.attempts = 0,
  });

  final String conversationId, cardId, kind, clientEventId, occurredAt;
  final int attempts;

  Map<String, Object> toJson() => {
    'conversationId': conversationId,
    'cardId': cardId,
    'kind': kind,
    'clientEventId': clientEventId,
    'occurredAt': occurredAt,
    'attempts': attempts,
  };

  static SupportOfferReceipt? fromJson(Object? m) {
    if (m is! Map) return null;
    final c = m['conversationId'],
        card = m['cardId'],
        kind = m['kind'],
        id = m['clientEventId'],
        at = m['occurredAt'];
    if (c is! String ||
        card is! String ||
        kind is! String ||
        id is! String ||
        at is! String)
      return null;
    return SupportOfferReceipt(
      conversationId: c,
      cardId: card,
      kind: kind,
      clientEventId: id,
      occurredAt: at,
      attempts: m['attempts'] is int ? m['attempts'] as int : 0,
    );
  }

  SupportOfferReceipt retried() => SupportOfferReceipt(
    conversationId: conversationId,
    cardId: cardId,
    kind: kind,
    clientEventId: clientEventId,
    occurredAt: occurredAt,
    attempts: attempts + 1,
  );

  bool same(SupportOfferReceipt o) =>
      o.cardId == cardId && o.clientEventId == clientEventId;

  @override
  bool operator ==(Object other) =>
      other is SupportOfferReceipt &&
      same(other) &&
      other.kind == kind &&
      other.occurredAt == occurredAt &&
      other.attempts == attempts;

  @override
  int get hashCode =>
      Object.hash(cardId, clientEventId, kind, occurredAt, attempts);

  static String iso(DateTime t) => t.toUtc().toIso8601String();

  /// A receipt id from a prefix and a random part (`[A-Za-z0-9_-]{8,64}`).
  static String eventId(String prefix) {
    final r = Random.secure();
    return '${prefix}_${List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join()}';
  }

  /// The id a card's `shown` receipt always uses, so it is stored once per card.
  static String shownId(String cardId) =>
      'shown_${cardId.replaceFirst('ofc_', '')}';
}

/// Receipts waiting to be sent, kept on the device so a tap made offline
/// still counts later. Cleared with the Support session (reset,
/// clearIdentity): they belong to that session only.
class SupportOfferReceipts {
  SupportOfferReceipts({
    required this.read,
    required this.write,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const storageKey = 'apprefer_support_offer_receipts';
  static const maxItems = 50, maxAttempts = 8;
  static const maxAge = Duration(days: 7);
  final Future<String?> Function(String) read;
  final Future<void> Function(String, String?) write;
  final DateTime Function() _now;
  Future<void> _lock = Future.value();

  Future<T> _locked<T>(Future<T> Function() body) {
    final run = _lock.then((_) => body());
    _lock = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<List<SupportOfferReceipt>> get pending => _locked(_load);

  Future<void> enqueue(SupportOfferReceipt r) => _locked(
    () async => _save([...(await _load()).where((x) => !x.same(r)), r]),
  );

  Future<void> remove(SupportOfferReceipt r) => _locked(
    () async => _save((await _load()).where((x) => !x.same(r)).toList()),
  );

  /// A transient failure: kept for later, up to [maxAttempts].
  Future<void> failed(SupportOfferReceipt r) => _locked(() async {
    final next = <SupportOfferReceipt>[];
    for (final x in await _load()) {
      if (!x.same(r)) {
        next.add(x);
      } else if (x.attempts + 1 < maxAttempts) {
        next.add(x.retried());
      }
    }
    await _save(next);
  });

  Future<void> clear() => _locked(() => write(storageKey, null));

  Future<List<SupportOfferReceipt>> _load() async {
    final raw = await read(storageKey);
    if (raw == null) return [];
    try {
      final oldest = _now().subtract(maxAge);
      return [
        for (final item in (jsonDecode(raw) as Map)['items'] as List)
          if (SupportOfferReceipt.fromJson(item) case final r?)
            if (DateTime.tryParse(r.occurredAt)?.isAfter(oldest) ?? false) r,
      ];
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<SupportOfferReceipt> items) async {
    final kept = items.length > maxItems
        ? items.sublist(items.length - maxItems)
        : items;
    await write(
      storageKey,
      kept.isEmpty
          ? null
          : jsonEncode({
              'items': [for (final r in kept) r.toJson()],
            }),
    );
  }
}

/// The outcome of asking the server to record an `opened` receipt before the
/// paywall opens.
sealed class SupportOfferOpenCheck {
  const SupportOfferOpenCheck();
}

/// Recorded (or a duplicate): open the paywall.
class SupportOfferRecorded extends SupportOfferOpenCheck {
  const SupportOfferRecorded(this.card);
  final AppReferSupportOfferCard? card;
}

/// The server says the card can't be opened now (withdrawn, changed…):
/// redraw, don't open.
class SupportOfferRefused extends SupportOfferOpenCheck {
  const SupportOfferRefused();
}

/// No answer in time: open anyway (the store and the paywall are the real
/// gate); the receipt stays queued and goes out later with the same id.
class SupportOfferOffline extends SupportOfferOpenCheck {
  const SupportOfferOffline();
}

/// Opening a card: record the `opened` receipt (asking the server whether
/// the card can still be opened, for up to [timeout]), then hand it to the
/// app. A refusal redraws the card instead.
class SupportOfferOpener {
  SupportOfferOpener({
    required this.queue,
    required this.send,
    this.timeout = const Duration(seconds: 3),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final SupportOfferReceipts queue;
  Future<AppReferSupportOfferCard?> Function(SupportOfferReceipt) send;
  Duration timeout;
  final DateTime Function() _now;

  SupportOfferReceipt receipt(
    AppReferSupportOfferCard card,
    String conversationId,
  ) => receiptFor(card.cardId, conversationId);

  SupportOfferReceipt receiptFor(String cardId, String conversationId) =>
      SupportOfferReceipt(
        conversationId: conversationId,
        cardId: cardId,
        kind: 'opened',
        clientEventId: SupportOfferReceipt.eventId('open'),
        occurredAt: SupportOfferReceipt.iso(_now()),
      );

  Future<SupportOfferOpenCheck> check(SupportOfferReceipt r) async {
    // Kept on the device first so an offline tap still counts; a store that can't be written
    // never stops the paywall from opening.
    await queue.enqueue(r).catchError((_) {});
    SupportOfferOpenCheck outcome;
    try {
      outcome = SupportOfferRecorded(await send(r).timeout(timeout));
    } on SupportException catch (e) {
      outcome = e.status == 404 || e.status == 409
          ? const SupportOfferRefused()
          : const SupportOfferOffline();
    } catch (_) {
      outcome = const SupportOfferOffline();
    }
    if (outcome is! SupportOfferOffline)
      await queue.remove(r).catchError((_) {});
    return outcome;
  }
}

/// Whether the app set `onOffer`, and Billing changes to refresh cards on.
class SupportOffers {
  SupportOffers._();
  static bool hasHandler = false;

  /// `offers` (this SDK draws cards), `offer-handler` (the app opens its
  /// paywall from them) and `reviews` (this SDK draws review cards and opens
  /// the store page itself).
  static String get featuresHeader => hasHandler
      ? 'offers, offer-handler, reviews, testimonials'
      : 'offers, reviews, testimonials';
}
