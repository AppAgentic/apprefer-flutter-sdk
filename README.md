# AppRefer Flutter SDK

First-party mobile attribution for Flutter apps. Captures click IDs, resolves attribution, and forwards conversions to ad networks — without third-party SDKs.

[![Flutter 3.41+](https://img.shields.io/badge/Flutter-3.41+-blue.svg)](https://flutter.dev)
[![Dart 3.11+](https://img.shields.io/badge/Dart-3.11+-blue.svg)](https://dart.dev)
[![iOS & Android](https://img.shields.io/badge/Platforms-iOS%20%26%20Android-lightgrey.svg)]()

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  apprefer:
    git:
      url: https://github.com/AppAgentic/apprefer-flutter-sdk.git
```

Then run `flutter pub get`.

### Android Setup

Add the Install Referrer library to `android/app/build.gradle`:

```gradle
dependencies {
    implementation 'com.android.installreferrer:installreferrer:2.2'
}
```

iOS requires no additional setup — the SDK automatically uses Apple's AdServices framework.

## Quick Start

Get your **API Keys** from the [AppRefer dashboard](https://apprefer.com) → Settings.

```dart
import 'package:apprefer/apprefer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final attribution = await AppReferSDK.configure(AppReferConfig(
    apiKey: 'pk_live_...',  // use pk_test_ during development
  ));

  if (attribution != null) {
    print('Attributed to: ${attribution.network} via ${attribution.matchType}');
  }

  runApp(MyApp());
}
```

## API Keys

Each app has two SDK keys:

| Key | Prefix | Purpose |
|-----|--------|---------|
| **Live** | `pk_live_` | Production — real attribution, events forwarded to ad networks |
| **Test** | `pk_test_` | Development — sandbox attribution, no ad network forwarding |

Use the test key during development and the live key in production builds. The server determines the environment from the key — no configuration flag needed.

## API

### Configure

Call once at app launch. Resolves attribution on first install, returns cached result on subsequent launches.

```dart
final attribution = await AppReferSDK.configure(AppReferConfig(
  apiKey: 'pk_live_...',  // or pk_test_ for development
  userId: null,           // optional — link RevenueCat user ID at init
  debug: false,           // optional — enable verbose logging
  logLevel: 1,            // optional — 0=none, 1=errors, 2=warnings, 3=verbose
));
```

### Link RevenueCat User ID

Connect the device to RevenueCat so purchase webhooks can be attributed.

```dart
await AppReferSDK.setUserId(Purchases.appUserID);
```

### Track Events

Track non-purchase events. Purchases are handled automatically via RevenueCat webhooks.

```dart
await AppReferSDK.trackEvent('signup');
await AppReferSDK.trackEvent('tutorial_complete', properties: {'step': 'final'});
```

### Advanced Matching

Improve ad network match rates by sending hashed PII. All data is SHA256-hashed on-device before transmission.

```dart
await AppReferSDK.setAdvancedMatching(
  email: 'user@example.com',
  phoneNumber: '+1234567890',
  firstName: 'Jane',
  lastName: 'Doe',
);
```

### Get Attribution & Device ID

```dart
final cached = await AppReferSDK.getAttribution();   // no network call
final deviceId = await AppReferSDK.getDeviceId();     // for RC subscriber attributes
```

## Attribution Model

```dart
attribution.network       // "meta", "google", "tiktok", "apple_search_ads", "organic"
attribution.matchType     // "click_id", "adservices", "referrer", "organic"
attribution.campaignName  // campaign name from tracking link
attribution.fbclid        // Meta click ID (if present)
attribution.gclid         // Google click ID (if present)
attribution.ttclid        // TikTok click ID (if present)
```

## Subscriptions (AppRefer Billing)

AppRefer Billing replaces RevenueCat for App Store and Google Play subscriptions and one-time purchases. The official `in_app_purchase` plugins handle the purchase (StoreKit 2 on iOS, Play Billing on Android), AppRefer verifies it with Apple or Google, keeps the entitlements and sends the conversion to your ad networks from the same attribution data. Google purchases are acknowledged by AppRefer's server.

Billing must be enabled for the app in AppRefer (`billing.mode` `shadow` or `primary`, with the bundle id / package name and products configured). On iOS it needs iOS 15+ (StoreKit 2).

### Set up

```dart
import 'package:apprefer/apprefer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppReferSDK.configure(AppReferConfig(apiKey: 'pk_live_...'));
  // Uses the same SDK key. Starts the store purchase listener right away.
  await AppReferBilling.configure(
    appUserId: null, // null = anonymous "$ARAnon:<UUID>"
    entitlementsByProduct: {
      'pro_monthly': ['premium'],
      'pro_yearly': ['premium'],
    },
    consumableProductIds: {'coins_100'}, // Google Play consumables (iOS reads the type from StoreKit)
  );
  runApp(MyApp());
}
```

`entitlementsByProduct` is only used when AppRefer can't be reached (see Outage safety). Unlisted products fall back to the mapping the server last returned, then `defaultEntitlement` (default `premium`, the same as the server).

Don't call `completePurchase` yourself, and don't call `InAppPurchase.instance.restorePurchases()` directly: AppRefer Billing completes each purchase once AppRefer has recorded it. Listening to `InAppPurchase.instance.purchaseStream` for UI is fine.

### Products, purchase, restore

```dart
final products = await AppReferBilling.products(['pro_monthly', 'pro_yearly']); // ProductDetails, in this order

final result = await AppReferBilling.purchase(products[1]);
switch (result.outcome) {
  case PurchaseOutcome.purchased:     unlock(result.customerInfo);
  case PurchaseOutcome.userCancelled: break;
  case PurchaseOutcome.pending:       showPendingNote(); // arrives later via customerInfoStream
}

final info = await AppReferBilling.restorePurchases(); // AppStore.sync() on iOS + sends every owned purchase
```

Only `restorePurchases()` sends a purchase as a restore, which lets AppRefer move a purchase owned by another app user to the one signed in. Purchases, renewals and other store updates never move ownership: each is recorded for the user who started it (or whose account token it carries). On iOS, if the App Store's restored transactions don't arrive in time while the device has active ones, `restorePurchases()` throws instead of reporting an empty restore.

`purchase` sets the store account identifier to the customer's AppRefer account token (Apple `appAccountToken`, Google `obfuscatedAccountId`), sends the purchase to AppRefer (the StoreKit 2 signed transaction on iOS, the purchase token on Android) and only then completes it with the store; Google consumables are consumed at that point. On Google Play a subscription returns one `ProductDetails` per base plan / offer. Offers: `purchase(product, promotionalOffer: SK2PromotionalOffer(...))` or `winBackOfferId:` on iOS, `changeSubscriptionParam: ChangeSubscriptionParam(...)` for Google upgrades and downgrades.

### Entitlements

```dart
final info = await AppReferBilling.customerInfo(); // cached for 5 minutes, then fetched
final fresh = await AppReferBilling.customerInfo(fetchPolicy: FetchPolicy.fetchCurrent);
if (info.entitlements['premium']?.isActive == true) { /* unlocked */ }

AppReferBilling.customerInfoStream.listen(update);       // replays the latest value
AppReferBilling.addCustomerInfoUpdateListener(update);   // or a RevenueCat-style listener
```

`customerInfo` never throws. `info.source` tells you where the answer came from: `CustomerInfoSource.server`, `.cache` or `.localFallback`.

### Users

```dart
await AppReferBilling.logIn('user_123');  // moves purchases made while anonymous to this user
await AppReferBilling.logOut();           // new anonymous id; a login not yet sent to AppRefer is kept and sent later
await AppReferBilling.setAttributes({r'$email': 'a@b.com', r'$displayName': 'Alex'}); // sent with the next call
await AppReferBilling.setEmail('a@b.com'); // also setDisplayName / setPhoneNumber
```

The AppRefer attribution device id is sent automatically as `appreferId`, so purchases are matched to the ad click without `setUserId`. The anonymous id is kept in the app's preferences, so it is reset by a reinstall (the iOS SDK keeps it in the Keychain); store restores still find the purchases.

### Outage safety

A paying user is never locked out because AppRefer is down:

- If AppRefer can't be reached or returns an error, entitlements come from every verified store purchase on the device (iOS: StoreKit 2's verified transactions, not revoked, not expired, not upgraded away; Android: the purchases Play reports as owned), mapped through `entitlementsByProduct`, merged with the last server answer for the same user.
- When AppRefer answers, the device's verified purchases that belong to the customer are still merged in: those with no account token, with the customer's token, or still queued for them. One tagged with another user's token is left out.
- A purchase AppRefer can't accept right now is saved to a retry queue on disk. Google purchases are then acknowledged on the device straight away (never consumed until AppRefer has recorded them), so Google can't refund them even if the app isn't opened again. App Store purchases are finished once the queue entry is saved. The queue is resent on the next launch, on foreground and after the next successful call (up to 50 attempts or 90 days). A 401, 403, 404, 409 or 429 pauses it (30 s doubling to 1 h, or the server's `Retry-After`) without using up attempts; 400, 413 and 422 are final. App Store Server Notifications and Google RTDN also reach AppRefer on their own.
- A store acknowledge or consume that fails is retried on the next foreground.
- If billing state on the device can't be read, nothing is sent and no new anonymous id is created; entitlements come from the store until it can be read.
- A purchase AppRefer refuses for good (400, 413, 422), one with nothing AppRefer can verify, and one the retry queue gives up on are first saved on the device with their full store data, and only then completed with the store; if that save fails the purchase stays open and the store delivers it again. Consumables are never consumed in that case (Google: acknowledged only; App Store: left unfinished). `restorePurchases()` sends them again, and `AppReferBilling.rejectedPurchases()` lists them for support. The list has no size cap: an entry leaves only once AppRefer records the purchase.
- Who started a purchase (app user, product, account token) is saved on the device before the purchase sheet opens; if it can't be saved, `purchase()` throws a `storage` error and the sheet doesn't open. A purchase that completes later (Ask to Buy, slow payment, after a restart, logout or user switch) goes to the user its account token or saved intent names, never just to whoever is signed in; if the saved intents can't be read, it stays open with the store until they can. Renewals settle an open purchase sheet but never match or use up a saved intent, on any path (App Store: original transaction id differs from the transaction id; Google: order id ends in `..N`). An untagged new purchase takes the saved intent for the same product with the earliest start time. An intent is removed only when its purchase is recorded, queued, archived, cancelled or ended by a definitive store error (product unavailable, not allowed, already owned, billing unavailable, developer error), never for its age, a network or service error, or a newer purchase. If some saved intents can't be parsed, the parseable ones are kept, the original is quarantined and an "intents lost" marker is saved; meanwhile an untagged new purchase with no intent stays open with the store (retried on foreground) for up to 48 hours from when it was made or when the intents were lost, whichever is earlier, then goes to the current user with a support note in the log and on any rejected-purchase entry. The marker clears once nothing is held and it is 48 hours old.

### Migrating from RevenueCat

**No RevenueCat data export is needed.** On first billing configure for each install and user, AppRefer imports the store's active purchases in the background, including already-acknowledged Google Play purchases. Logging in as a new user runs the import for that user. Each purchase is sent without `restore: true`, so it fills unowned purchases and records state without transferring purchases already owned by another user. The completion flag is saved only after every purchase is accepted or durably queued for retry. Migration never finishes, acknowledges or consumes a purchase on device; retry uploads use the same rule. Purchases older than 24 hours update state without an ad conversion. Keep the same app user IDs and configure store notifications for renewals.

| RevenueCat (`purchases_flutter`) | AppRefer Billing |
|---|---|
| `Purchases.configure(PurchasesConfiguration(key)..appUserID = id)` | `AppReferBilling.configure(appUserId: id, entitlementsByProduct: {...})` (after `AppReferSDK.configure`) |
| `Purchases.getOfferings()` / `StoreProduct` | `AppReferBilling.products(['id', ...])` → `ProductDetails` |
| `Purchases.purchaseStoreProduct(product)` / `purchasePackage` → `CustomerInfo` | `AppReferBilling.purchase(product)` → `PurchaseResult` (`.customerInfo`, `.purchaseDetails`, `.userCancelled`, `.outcome`) |
| `PurchasesErrorCode.purchaseCancelledError` (thrown) | `result.userCancelled` (not thrown) |
| `purchaseDiscountedProduct(product, promotionalOffer)` | `purchase(product, promotionalOffer: SK2PromotionalOffer(...))` |
| `GoogleProductChangeInfo` | `purchase(product, changeSubscriptionParam: ChangeSubscriptionParam(...))` |
| `Purchases.restorePurchases()` | `AppReferBilling.restorePurchases()` |
| `Purchases.getCustomerInfo()` | `AppReferBilling.customerInfo(fetchPolicy: FetchPolicy.cachedOrFetched / .fetchCurrent)` |
| `customerInfo.entitlements.all['premium']?.isActive` | `customerInfo.entitlements['premium']?.isActive` (`.all` also works) |
| `customerInfo.entitlements.active` / `.activeSubscriptions` | same |
| `EntitlementInfo.expirationDate / willRenew / periodType / productIdentifier` | same names (`expirationDate` is a `DateTime?`) |
| `Purchases.addCustomerInfoUpdateListener(fn)` | `AppReferBilling.addCustomerInfoUpdateListener(fn)` or `customerInfoStream` |
| `Purchases.logIn(id)` / `logOut()` | `AppReferBilling.logIn(id)` / `logOut()` |
| `Purchases.appUserID` / `isAnonymous` | `await AppReferBilling.appUserId` / `isAnonymous` |
| `$RCAnonymousID:<hex>` | `$ARAnon:<UUID>` |
| `Purchases.setEmail` / `setDisplayName` / `setPhoneNumber` / `setAttributes` | `AppReferBilling.setEmail` / `setDisplayName` / `setPhoneNumber` / `setAttributes` |
| `AppReferSDK.setUserId(rcUserId)` | not needed: the device id is linked automatically |

If a file imports both packages during the switch, hide the clashing names (`import 'package:purchases_flutter/purchases_flutter.dart' hide CustomerInfo, EntitlementInfo;`) or use `AppReferCustomerInfo` / `AppReferEntitlementInfo`.

Testing: use a sandbox Apple ID or a Play license tester. Transactions from an Xcode StoreKit configuration file are signed with a local certificate that AppRefer's server rejects; the SDK still unlocks them through the local fallback.

## Best Practices

- **Call `configure()` once** — ideally in `main()` before `runApp()`. The SDK deduplicates automatically; subsequent calls return the cached result with no network overhead.
- **Set the RevenueCat user ID early** — call `AppReferSDK.setUserId()` right after `Purchases.configure()` so purchase webhooks can be attributed to the correct device.
- **Call `setAdvancedMatching()` after login/signup** — this sends hashed PII to improve Meta CAPI match rates. Only needs to be called once per user session.
- **Don't track purchases with `trackEvent()`** — revenue events are handled automatically via RevenueCat webhooks. Use `trackEvent()` only for non-purchase milestones like `signup`, `tutorial_complete`, or `onboarding_finish`.
- **Use the test key during development** — `pk_test_` keys create sandbox events that are isolated from production data and never forwarded to ad networks. Switch to `pk_live_` for release builds.
- **Use the Debugger** — verify events are flowing correctly in the [AppRefer dashboard](https://apprefer.com) → Debugger before going to production. Toggle the Sandbox switch to see test events.
- **Android: add the Install Referrer dependency** — without it, Android attribution falls back to probabilistic matching instead of deterministic referrer-based matching.
- **No IDFA required** — on iOS, the SDK uses Apple's AdServices framework and does not require ATT permission.

## Requirements

- Flutter 3.41+
- Dart 3.11+
- iOS 15.0+ / Android API 21+ (the CocoaPods spec has required iOS 15 since before AppRefer Billing)

## License

Proprietary. All rights reserved.

## Support chat (AppRefer Support)

An in-app help chat your team answers from the AppRefer inbox: a help home
(greeting, who answers and how fast, the conversation to pick up again, quick-help
topics and a message field), conversation threads, screenshot attachments and reply
badges. Uses the SDK key and device/user IDs from `AppReferSDK.configure` / `setUserId`.

```dart
// After configuring AppReferSDK:
await AppReferSDK.support.open(context: context);
// Opens the home with the message field pre-filled and focused:
await AppReferSDK.support.compose('Problem with my subscription', context: context);
await AppReferSDK.support.identify(name: 'María', email: 'maria@example.com');
AppReferSDK.support.accentColor = Colors.deepPurple; // hero, bubbles, send button
AppReferSDK.support.title = 'My app support'; // defaults to <App name> support
AppReferSDK.support.replyTime = 'a few hours'; // "We usually reply in …"
AppReferSDK.support.teamNames = ['Jay']; // first names shown on the home
AppReferSDK.support.appIcon = const AssetImage('assets/icon.png'); // defaults to the launcher icon
AppReferSDK.support.topics = [
  AppReferSupportTopic.billing,
  AppReferSupportTopic(
    title: 'Restore purchase',
    subtitle: 'Get your plan back',
    icon: Icons.refresh_rounded,
    tint: Colors.blue,
    prompt: 'Which plan did you buy?',
    action: () => AppReferBilling.restorePurchases(), // runs instead of starting a message
  ),
  AppReferSupportTopic.bug,
]; // [] hides the tiles
final unread = await AppReferSDK.support.unreadCount();

// For context-free notification handling, assign your MaterialApp navigatorKey:
AppReferSDK.support.navigatorKey = navigatorKey;
await AppReferSDK.support.registerPushToken(fcmToken);
// From a notification tap (not every foreground notification):
if (AppReferSDK.support.handleNotification(message.data)) return;
// On sign-out / token removal:
await AppReferSDK.support.removePushToken(fcmToken);

// Or embed in your own route:
const AppReferSupportView();
const AppReferSupportView(conversationId: 'conversation-id');
const AppReferSupportView(composing: 'Report a problem');
```

`topics` defaults to Billing & refunds, Restore purchase, Report a bug and Suggest
an idea. Picking a tile sets the message field's hint to the topic's `prompt` and
sends its `title` as the conversation subject. `replyTimeText` was removed: use
`replyTime`. The home's colours (hero glows, bubbles, avatars) are derived from
`accentColor`; on a bright accent such as yellow, text on it turns dark.

Customers can attach up to four screenshots per message. Native system photo
pickers need no photo-library permission. Images are reduced to at most 1600 px
and JPEG-compressed below 700 KB before direct upload. No new dependencies.
Session tokens use iOS Keychain and Android Keystore-backed AES-GCM storage
(including RSA-wrapped AES on Android 5).

The home refreshes every 15 seconds and visible conversations every 4 seconds;
backgrounding or closing stops polling. Failed messages remain available to retry
while the view is open. The chat is dark when the device is in dark mode or the
host theme is dark; keyboard insets and system text scaling are respected.

Push transport stays in the host app: forward APNs/FCM registration and notification
taps to these APIs. On Android registration creates `apprefer_support`; configure
FCM to use that channel for support replies. iOS payloads use `apprefer: {type:
support_reply, conversationId: ...}`; Android uses those fields directly in data.
