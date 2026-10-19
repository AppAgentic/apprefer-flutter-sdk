// Review cards in the help chat (server: lib/support/reviews.ts). A team member can attach an
// optional "Write a review" card to a reply; tapping it opens the app's own store page: the App
// Store write-review page on iOS, the Google Play listing on Android, as both stores recommend for
// a review button (their quota-limited in-app review prompts are never put behind a button). The
// SDK never shows stars, never asks whether the customer likes the app, and never says a review was
// written: opening the page is all it knows.
import 'package:flutter/foundation.dart';

/// A review card as the server sends it, with its state now.
@immutable
class AppReferSupportReviewCard {
  const AppReferSupportReviewCard({
    required this.cardId,
    required this.status,
    this.reason,
    this.store,
    this.url,
  });

  /// Stable id of the card (`rvc_…`).
  final String cardId;

  /// available or unavailable.
  final String status;

  /// Why it can't be opened: revoked, expired, account_changed, disabled,
  /// store_changed, not_on_platform.
  final String? reason;

  /// app_store or play_store (null when unavailable).
  final String? store;

  /// The store page to open; null unless available.
  final String? url;

  bool get isAvailable => status == 'available';

  /// Null when the value isn't a review card: no broken card is drawn.
  static AppReferSupportReviewCard? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final cardId = raw['cardId'], status = raw['status'];
    if (cardId is! String || status is! String) return null;
    String? str(String k) => raw[k] is String ? raw[k] as String : null;
    return AppReferSupportReviewCard(
      cardId: cardId,
      status: status,
      reason: str('reason'),
      store: str('store'),
      url: str('url'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppReferSupportReviewCard &&
      other.cardId == cardId &&
      other.status == status &&
      other.reason == reason &&
      other.store == store &&
      other.url == url;

  @override
  int get hashCode => Object.hash(cardId, status, reason, store, url);
}

/// How the chat draws a review card.
sealed class SupportReviewLook {
  const SupportReviewLook();

  static SupportReviewLook of(
    AppReferSupportReviewCard card, {
    required bool ios,
  }) {
    if (!card.isAvailable) {
      return card.reason == 'not_on_platform'
          ? const SupportReviewUnsupported()
          : const SupportReviewUnavailable();
    }
    final url = SupportReviewLink.validated(card.url, ios: ios);
    return url == null
        ? const SupportReviewUnsupported()
        : SupportReviewOpen(url);
  }
}

class SupportReviewOpen extends SupportReviewLook {
  const SupportReviewOpen(this.url);
  final String url;
  @override
  bool operator ==(Object other) =>
      other is SupportReviewOpen && other.url == url;
  @override
  int get hashCode => url.hashCode;
}

class SupportReviewUnavailable extends SupportReviewLook {
  const SupportReviewUnavailable();
}

/// No store page for this device (or a link the SDK won't open).
class SupportReviewUnsupported extends SupportReviewLook {
  const SupportReviewUnsupported();
}

class SupportReviewLink {
  SupportReviewLink._();
  static final _appleId = RegExp(r'^/app/id[1-9][0-9]{4,11}$');
  static final _package = RegExp(
    r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
  );

  /// Only this platform's store page for one app: on iOS the App Store
  /// write-review page (`https://apps.apple.com/app/id<id>?action=write-review`),
  /// on Android the Google Play listing (`https://play.google.com/store/apps/details?id=<package>`).
  /// Anything else is never opened, whatever the server says.
  static String? validated(String? raw, {required bool ios}) {
    if (raw == null || raw.isEmpty) return null;
    final Uri u;
    try {
      u = Uri.parse(raw);
    } catch (_) {
      return null;
    }
    if (u.scheme != 'https' ||
        u.userInfo.isNotEmpty ||
        u.hasPort ||
        u.hasFragment)
      return null;
    if (ios) {
      if (u.host.toLowerCase() != 'apps.apple.com' ||
          !_appleId.hasMatch(u.path) ||
          u.query != 'action=write-review')
        return null;
      return 'https://apps.apple.com${u.path}?action=write-review';
    }
    if (u.host.toLowerCase() != 'play.google.com' ||
        u.path != '/store/apps/details' ||
        !u.query.startsWith('id=') ||
        u.query.contains('&'))
      return null;
    final pkg = u.query.substring(3);
    return _package.hasMatch(pkg)
        ? 'https://play.google.com/store/apps/details?id=$pkg'
        : null;
  }

  /// The string-table suffix for a store: each language words the store its own way.
  static String storeKey(String? store) =>
      store == 'play_store' ? 'googlePlay' : 'appStore';

  /// The id a review card's `shown` receipt always uses (once per card).
  static String shownId(String cardId) =>
      'shown_${cardId.replaceFirst('rvc_', 'r')}';
}
