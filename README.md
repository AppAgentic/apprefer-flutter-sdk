# AppRefer Flutter SDK

## 0.11.0 (unreleased): lifecycle notifications (engagement)

**Not generally available.** AppRefer turns lifecycle engagement on per app; until then every engagement call answers "disabled" quietly and nothing is stored. The server side is dry-run only in this release: no notification is sent to anyone yet. This version is the client contract (wire schema 1) the live sender will use.

Rules the SDK follows: nothing is registered until your app calls `start`; nothing asks for notification permission or tracking consent; the install secret lives only in secure storage (iOS Keychain / Android Keystore); an account is bound only with an assertion your backend gets from AppRefer (`POST /api/v1/apps/{appId}/engagement/assertions`, `engagement:identity` key), never a plain user id; Support sessions, tokens and `support_reply` pushes never enroll anyone, and Support's handlers ignore engagement pushes; a notification for another install or account, an expired one, or one that fails validation never navigates; each outcome (received, opened, button, snoozed, dismissed) is delivered once, and navigation waits for `setNavigationReady(true)`; a snooze is never a completion; receipts carry the message's own proof and are dropped after any account change; an account change also removes AppRefer's own snoozes and posted notifications for the previous account (on iOS a remote notification already on screen can't be withdrawn, but it never navigates or reports for the next account); queued events and identity changes carry the account epoch they were made under, so the server refuses one made for an account the install has left; destinations are in-app paths your app maps to screens, never URLs the SDK opens.

```dart
await AppReferSDK.engagement.start(options: const AppReferEngagementOptions(
  trackedEvents: {'setup_started', 'setup_completed'},
  allowedImageHosts: {'assets.example.com'},          // Android rendering
  androidSmallIcon: 'ic_stat_notify',
  appGroup: 'group.com.example.app',                    // iOS extension (optional)
  notificationServiceExtension: true));
await AppReferSDK.engagement.setPushToken(token);       // FCM token on Android, APNs hex on iOS
// FCM handlers (foreground onMessage and the background handler):
if (await AppReferSDK.engagement.handleMessage(message.data)) return;
AppReferSDK.engagement.onNotificationEvent = (e) { if (e.isNavigation) router.go(e.destination ?? '/'); };
AppReferSDK.engagement.setNavigationReady(true);
await AppReferSDK.engagement.identify(assertionFromYourBackend);
```

iOS: make the Flutter app delegate the notification delegate (`UNUserNotificationCenter.current().delegate = self` in `AppDelegate`) so the plugin receives taps, or call `AppReferPlugin.handleEngagementResponse(response)` / `engagementPresentationOptions(for:)` from your own delegate. Images need the Notification Service Extension from the iOS SDK README (add the `AppReferNotifications` Swift package product to that target; Dart doesn't run there). Android: declare and request `POST_NOTIFICATIONS` yourself; the plugin renders AppRefer's data messages natively. Dart code may not run when the app was killed: outcomes wait natively and are delivered when Dart drains them (start, resume, `drain()`).

## 0.10.0 (unreleased): help centre in the chat; the help chat speaks 35 languages

**Help centre.** When your app has published help articles in AppRefer, the help home
shows a "Help articles" card (search plus the top articles), with a help centre screen
(every article by category, search) and an article reader. "Still need help? Message
us" starts a conversation about the article. Nothing changes for apps without
articles. Read them in code too: `AppReferSDK.support.articles(query:)`,
`article(slug)`, and `AppReferSDK.support.status()` to decide whether to register
push tokens. See [Help centre and status](#help-centre-and-status-0100).

**AppRefer Support is localized.** Every label, placeholder, error and accessibility
label in the help chat ships in 35 languages and follows the locale your app is
running in, so the chat matches your screens. No `localizationsDelegates` needed.
Override any string or force a language; see
[Support chat → Languages](#languages-and-your-own-wording). Arabic and Hebrew lay
out right to left.

## 0.9.2: Billing follows the collection choice; Support clearIdentity

**Billing sends no device id while it must not.** AppReferBilling uses the same rule
Support has used since 0.9.1: the install device id (`appreferId`) and the device
signals among the customer attributes (`$idfa`, `$idfv`, `$fbAnonId`,
`$attConsentStatus`, `$deviceVersion`, `$ip`, `$gpsAdId`) are sent with
customers/purchases requests only after `configure`/`configureResult` in this
process, never while collection is off (including an "off" that could not be
saved, or one turned back on but not yet configured), and never after `reset()`
until configure runs again for the next user. A withheld device attribute is
dropped, not sent later. While the gate is closed Billing also uses `apprefer.com`,
never `trk.apprefer.com`. Purchases, restore, entitlements and offerings work
exactly as before without it. Purchases queued earlier keep their device id only
if linking is allowed when they are resent. A customer registered without the
device id is linked once on the next customer refresh after configure.
Billing-only apps never send it.

The device id also belongs to the account: after `reset()` Billing sends it only
for the Billing user set after that reset, so the user Billing served before it
(and purchases or queued entries owned by them, or by anyone other than the current
Billing user) is never linked to the install. Call `AppReferBilling.logIn(…)` (or
`logOut()`) for the next account after `reset()`. Since 0.9.3 this also holds after
the app is relaunched: `reset()` saves the Billing user it left behind, and until
`logIn`/`logOut` runs (or Billing moves to a different user) that user gets no device
id, no re-link and `link: false` on identify. A fresh anonymous user created by
`logOut()` in the same app session is never marked, so signing out with `logOut()`
before (or while) `reset()` runs keeps that new user linkable. `logIn` tells the server
(`link: false` with identify) not to copy the attribution link while the gate is
closed; the purchases still move to the signed-in user.

**Remove the account from Support without a full reset**, e.g. when the user
withdraws consent:

```dart
await AppReferSDK.support.clearIdentity();
```

This forgets the Support name, email and app user id, revokes the current Support
session (through the same durable revocation used by reset) and starts a new
anonymous session that carries no link to the old id: it sends neither the app user
id nor the install device id. A registered push token moves to the new session only
after the old session's revocation succeeded, so the two never hold it at the same
time (a token registered before 0.9.2 has no saved environment and is not moved; the
app's next `registerPushToken` registers it, and from 0.9.3 that registration also
waits for the old session's revocation when the old session still holds the token). An open help screen closes. **Conversations from the old
session are no longer visible in the app**; they stay in your team inbox. The app
user id is not sent to Support again until it changes (another account is stored
with `setUserId`/`configure(userId: …)`) or `reset()` runs; configuring with the
same user id on the next launch keeps Support anonymous. When a different user id is
stored later without `reset()`, that account gets a fresh Support session and the
anonymous one is revoked, so it never sees conversations from after the clear. Attribution, Billing and the
stored user id are not changed. Combine it with `setCollectionEnabled(false)` to stop
attribution as well.

## 0.9.1: account switching, independent Support and reliable events

Support can start independently of attribution. Its configuration does not configure
attribution, collect attribution device signals, initialize product analytics, or
create a device id. Full configuration still enables attribution and analytics as
before. Opening Support before either configuration reports the existing
not-configured error.

Await reset() before signing the next account in. Reset cancels outstanding
attribution, event and Support work, best-effort revokes the old Support session
and unregisters its push token, clears the session/profile and displayed
conversations/unread/drafts, removes the user id and transient matching data,
and drops queued product events. It is idempotent and safe before configuration.
The key remains configured so the next account can use Support; install device id,
attribution result, consent and conversion state are retained. Advanced-matching
hashes are never persisted by this SDK. Billing is separate: also call
AppReferBilling.logOut() when your app uses Billing, then identify its next user
through Billing's existing login API.
After reset, attribution sends nothing (no consent re-report, conversion value,
user id, advanced matching or event delivery; events tracked meanwhile are
dropped, never sent later) and Support sends no device id
until configure is called again, so the next account's Support session is never
linked to the previous account's install. Support also omits the device id while
collection is off.

Migration: after reset(), call configure again for the next user; until then events, attribution and consent reports are paused.

```dart
AppReferSDK.support.configure(apiKey: 'pk_...'); // Support only
await AppReferSDK.setUserId('account-A');
await AppReferSDK.support.identify(name: 'Alex', email: 'alex@example.com');
await AppReferSDK.reset();
await AppReferSDK.setUserId('account-B');

final result = await AppReferSDK.configureResult(const AppReferConfig(apiKey: 'pk_...'));
// result.status: AttributionStatus.attributed / organic / pending / failed
// result.attribution or result.error contains the corresponding detail.
final delivery = await AppReferSDK.trackEventResult('workout_finished', properties: {'sets': 4});
await AppReferSDK.clearPendingEvents();
// If Billing is configured, also: await AppReferBilling.logOut();
```

The existing configure return value and trackEvent API remain available.
The new configureResult reports attributed, organic, pending, or failed; organic requires
a successful server answer (or its confirmed install cache), never a network
failure or an unclassified empty response. Pending means the server is holding
the ATT decision; its cached copy remains pending until the server confirms a result.
A failed consent re-report preserves any previously confirmed attribution.

trackEventResult returns sent, queued or dropped (uppercase enum cases on
Android). Sent means HTTP 2xx acknowledgement; queued means saved for later
delivery; dropped covers a disabled/unconfigured SDK, a terminal rejection or
unpersistable input. Product events are persisted before sending, bounded to
1,000 events and seven days; expiry and overflow discard the oldest entries.
Each event keeps one stable eventId. Network failures, HTTP 408/429 and 5xx retry
with exponential backoff capped at one hour, or longer when Retry-After requires it.
A retryable failure pauses the drain. HTTP 2xx and other 4xx responses are terminal.
Awaited event calls wait only for their own single request, never the full backlog.
This is **at-least-once delivery**: BigQuery's short insert-id deduplication window
does not provide an exactly-once guarantee.

clearPendingEvents() cancels only product-event requests and erases the queue; call
it when withdrawing product-event consent. Reset calls it too. The existing SDK
kill switch also clears queued events and stops sends. ATT/advertising consent
continues to select the appropriate host; it is not a new product-analytics
consent switch. Discarded events are never replayed. Await reset/clear before
starting work for the next account or resuming event collection.


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
      ref: 0.9.3
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
  userId: null,           // optional — your app's user id (the one you pass to AppReferBilling.logIn)
  debug: false,           // optional — enable verbose logging
  logLevel: 1,            // optional — 0=none, 1=errors, 2=warnings, 3=verbose
));
```

### Link your user ID

Tell AppRefer who is signed in, so Support conversations and product events carry the account.
AppRefer Billing links purchases to the ad click on its own (the install device id is sent
automatically), so this isn't needed for purchase attribution.

```dart
await AppReferSDK.setUserId(currentUser.id);
await AppReferBilling.logIn(currentUser.id); // if you use AppRefer Billing
```

### Track Events

Track non-purchase events. Purchases made with AppRefer Billing are recorded and sent to your ad networks automatically.

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
final deviceId = await AppReferSDK.getDeviceId();     // e.g. for your support tools or backend
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

The AppRefer attribution device id is sent automatically as `appreferId`, so purchases are matched to the ad click without `setUserId` (only after `AppReferSDK.configure`, and not while collection is off or after `reset()` until configure runs again; see 0.9.2). The anonymous id is kept in the app's preferences, so it is reset by a reinstall (the iOS SDK keeps it in the Keychain); store restores still find the purchases.

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
- **Set the user ID when someone signs in** — call `AppReferSDK.setUserId()` and `AppReferBilling.logIn()` with the same id, so Support, product events and purchases all belong to that account.
- **Call `setAdvancedMatching()` after login/signup** — this sends hashed PII to improve Meta CAPI match rates. Only needs to be called once per user session.
- **Don't track purchases with `trackEvent()`** — AppRefer Billing records purchases, renewals and refunds and forwards them for you. Use `trackEvent()` only for non-purchase milestones like `signup`, `tutorial_complete`, or `onboarding_finish`.
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
final check = await AppReferSDK.support.verifyIdentity(tokenFromYourBackend); // 0.12.0: confirms the account (see "Verified identity" below)
AppReferSDK.support.accentColor = Colors.deepPurple; // hero, bubbles, send button
AppReferSDK.support.headerStyle = AppReferSupportHeaderStyle.plain; // 0.11.1: flat neutral grey header (default .accent); 0.11.2: Continue card avatar too
AppReferSDK.support.title = 'My app support'; // defaults to "<App name> support", translated
AppReferSDK.support.replyTime = 'a few hours'; // "We usually reply in …"; defaults to "under an hour", translated
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
// Register only once AppRefer has verified your APNs key / FCM service account:
final status = await AppReferSDK.support.status();
if (status.pushReady) await AppReferSDK.support.registerPushToken(fcmToken);
// iOS: the APNs environment is read from the app's signing (development-signed builds,
// Debug or Release, and the Simulator: sandbox; App Store, TestFlight, Ad Hoc,
// Enterprise: production). To force one: AppReferSDK.support.pushEnvironment = 'sandbox'
// (or registerPushToken(token, environment: 'sandbox')).
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
an idea (`AppReferSupportTopic.billing`, `.restore`, `.bug`, `.idea`; their `id`s are
`billing`, `restore`, `bug`, `idea`), in the chat's language. Picking a tile sets the
message field's hint to the topic's `prompt` and sends its `title` as the conversation
subject. `replyTimeText` was removed: use
`replyTime`. The home's colours (hero glows, bubbles, avatars) are derived from
`accentColor`; on a bright accent such as yellow, text on it turns dark. With
`headerStyle = AppReferSupportHeaderStyle.plain` (0.11.1) the home's header is a
flat neutral grey with white / near-black text: no accent, glow or coloured
presence avatar; from 0.11.2 the Continue card's avatar is neutral grey too.
Bubbles and buttons keep `accentColor`.

Customers can attach up to four screenshots per message. Native system photo
pickers need no photo-library permission. Images are reduced to at most 1600 px
and JPEG-compressed below 700 KB before direct upload. The only dependency Support
adds is `intl` (0.10.0, for dates and times in the chat's language), with a wide
version range so it fits whatever `flutter_localizations` pins in your app.
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

### Verified identity (0.12.0)

The app user id the SDK sends with Support is only a claim from the device. To let your team and
the AI assistant use the account's private details (plan, purchases, orders, credits your backend
shares), confirm it:

1. Your backend, after signing the user in, calls
   `POST https://apprefer.com/api/v1/apps/{appId}/support/identity-tokens` with your **private**
   organisation key (`support:context` scope) and `{ "appUserId": "<the signed-in user>" }`. It
   returns a single-use `identityToken` valid for up to 10 minutes. Never put the private key in
   the app.
2. The app passes that token to ``await AppReferSDK.support.verifyIdentity(token)`` after `setUserId` with the same user.

It verifies the current Support session, so conversations already started on it count too; no new
conversation is needed. Network and server failures are retried with the same token and then
thrown (sending the same token again is safe: the server acknowledges a retry from the same session).
A refusal comes back as `verified: false` with a `reason` (`expired`, `already_used`,
`user_mismatch`, `session_replaced`… get a new token), or `account_changed` when a reset,
`clearIdentity()` or another user id happened while it ran. The token is never stored or logged.
`reset()`, `clearIdentity()` and another account signing in end the verification. Until an app
verifies, the AI assistant gets no account data at all, and your team sees the claimed account
marked "Not verified". `identify` is unchanged.

### Offer cards (0.12.0)

Your team or AI assistant can attach one of your AppRefer Billing offerings to a reply. Tapping
**View offer** on the card calls your code with the offering, so you open **your own** paywall:

```dart
AppReferSDK.support.onOffer = (offer) {
  // offer.offeringId, offer.packageId (nullable), offer.cardId, offer.conversationId
  navigatorKey.currentState?.push(PaywallRoute(offer.offeringId, offer.packageId));
};
```

The card lists the offering's packages with the store's own formatted prices (the store's price via `AppReferBilling.offerings()` (Google Play's regular recurring price, never a trial phase), when Billing is configured; otherwise no prices) and
tags the customer's current plan; switching plans is never blocked. The SDK never shows a paywall,
never starts a purchase and never shows a price, discount or deadline of its own: your paywall does
the buying and AppRefer Billing confirms it from the store as usual. A tap is reported as an
`opened` receipt (never a purchase); receipts made offline are kept on the device for up to 7 days
and sent again with the same id. Before calling you, the SDK asks AppRefer for up to 3 seconds
whether the card can still be opened: a withdrawn, expired or changed card redraws instead, and no
answer calls you anyway (the store is the real gate).

- `closesChatOnOffer` (default `true`) closes the chat route opened with `open()`/`compose()` before `onOffer` runs.
- Without `onOffer`, cards say "This offer can't be opened in this version of the app".
- Cards refresh when the chat opens, every 30 seconds while it is open, after a purchase, restore or
  sign-in reported by AppRefer Billing, and when the app comes back to the foreground.
- Your team sends cards from the inbox (＋ Offer); the AI assistant can attach one only for a
  verified customer. Offerings that aren't public in your catalogue (current, placement, targeting
  rule, running experiment) also need the customer verified (see Verified identity).
- `reset()` and `clearIdentity()` drop pending receipts with the old session.
- Older SDK versions show your text plus a line asking the customer to update the app.

### Review cards (0.12.0)

Your team can attach an optional **Write a review** card to a reply (inbox: ＋ Review link). The card
says "Share your experience" and opens the App Store write-review page on iOS and the Google Play listing on Android, through the SDK's existing `openUrl` channel (no new plugin). There is nothing to set up: AppRefer builds the link
from the App Store id or package name your app already has in AppRefer (Billing or the store URL in app settings).

- Neutral and optional: no stars, no "do you like the app?" question, no reward, never sent
  automatically and never only to happy customers. The AI assistant can only suggest one in a draft
  for a person to send.
- The SDK opens only `https://apps.apple.com/app/id<digits>?action=write-review` on iOS and `https://play.google.com/store/apps/details?id=<package>` on Android; anything else is shown as "no store page" and never opened.
- The SDK never calls the store's in-app review prompt from the card: that prompt is limited by the
  store and can silently show nothing, so both Apple and Google recommend a link for a button.
- A tap records an `opened` receipt (same queue as offer cards; dropped by `reset()`/`clearIdentity()`).
  It is never a review, a rating or a star count, and the chat never says a review was written.
- A withdrawn, expired or changed card (store page or settings changed) shows "This review link is no
  longer available"; a device with no store page for the app shows "There's no store page for this
  device". AppRefer sends at most one card per customer every 120 days (configurable, 30–365).
- Older SDK versions show your text plus a line asking the customer to update the app.

0.12.0 is unreleased source (not tagged). Once tagged, install it from Git only: a pubspec `git:` dependency on `https://github.com/AppAgentic/apprefer-flutter-sdk.git` with `ref: 0.12.0` (not published to pub.dev).

### Languages and your own wording

The chat ships in 35 languages: ar, ca, cs, da, de, el, en, es, es-MX, fi, fr, he, hi, hr, hu, id, it, ja, ko, ms, nb, nl, pl, pt-BR, pt-PT, ro, ru, sk, sv, th, tr, uk, vi, zh-Hans, zh-Hant. Nothing to set up, and no `localizationsDelegates` are needed.

- **Which language:** the locale your app is running in (the `Localizations` locale of the widget tree the chat opens in, which Flutter resolves from your `MaterialApp`'s `supportedLocales`), so an app that ships fewer languages than the SDK gets a chat that matches its own screens (an English-only app on a German phone shows an English chat). If the SDK has no table for it, the device's preferred languages are tried, then English. Regional variants map sensibly: Latin American Spanish → es-MX, Portuguese outside Brazil → pt-PT, Chinese by script and region, Norwegian → nb.
- **Force a language:** `AppReferSDK.support.language = 'de'` (any shipped code; `null` follows the app again). `AppReferSupport.supportedLanguages` lists them.
- **Right to left:** in Arabic and Hebrew the chat lays out right to left, bubble tails, back chevron and screenshot buttons included.
- **Dates and times** use the chat's language ("Heute, 14:05") and the device's 24-hour setting.
- **Your own wording:** set any key; your text wins over the SDK's translation in every language. Placeholders are written `{name}` and filled in by name, so you can reorder them.

```dart
AppReferSDK.support.strings = {
  'support.home.subtitle': 'What can we fix for you?',
  'support.presence.team': 'Real humans · usually {time}',
  'support.a11y.unread#one': 'One new reply', // plural keys: "#one", "#few", … or the bare key for every count
};
// For your own app languages, set the values for the locale you're showing:
if (Localizations.localeOf(context).languageCode == 'de') {
  AppReferSDK.support.strings = {'support.home.subtitle': 'Wie können wir helfen?'};
}
```

`title`, `replyTime` and topic texts you set are shown as written. The defaults are translated, and `replyTime` is inserted into a translated sentence: in most languages that sentence already carries its own "in", so give the whole phrase (German `'innerhalb weniger Stunden'`, French `'en quelques heures'`). The built-in tiles translate themselves; their title becomes the conversation subject in the customer's language. Errors (offline, rate limit, message too long, upload failed, couldn't load, not sent, image unreadable, device locked) are shown in the customer's language, never as the server's English message.

Every key, its English text, a note for translators and all translations are in [`Localization/support-strings.json`](Localization/support-strings.json), the table all four AppRefer SDKs share; `dart run tool/generate_support_strings.dart` compiles it into `lib/src/support/support_strings_table.g.dart`. Messages your team writes and the AI assistant's answers and hand-over line come from AppRefer, not from this table.

### Help centre and status (0.10.0)

Publish help articles in AppRefer (dashboard, API or MCP) and they appear in the chat with no code: a "Help articles" card on the help home (search and the first three; "See all" with more), a help centre screen (articles by category, search that filters as you type and then asks the server, which also searches article bodies) and a reader. The reader renders markdown (headings, lists, bold and italic, code, quotes, links and https images) with a small built-in parser: no new package. HTML is never run and only http(s) and mailto links are kept; they open outside the app through the SDK's own platform channel. "Still need help? Message us" goes back to the message field with the article's title as the conversation subject. Apps without published articles see no help section at all. Articles come in the chat's language (the best translation the server has); lists are kept in memory for five minutes, and offline the chat shows what it had, never an error screen. Test keys (`pk_test_`) also show drafts, marked "Draft". Back (and the system back gesture) returns from an article to the help centre, then to the home.

```dart
// Open straight on the help centre or one article (any translation's slug works)
await AppReferSDK.support.openHelpCentre(context: context);
await AppReferSDK.support.openArticle('restore-purchases', context: context);
const AppReferSupportView(opening: AppReferSupportDestination.helpCentre);
const AppReferSupportView(opening: AppReferSupportDestination.article('restore-purchases'));

// Your own help screens
final articles = await AppReferSDK.support.articles(); // List<AppReferHelpArticle>: slug, title, summary, category, url, updatedAt, isDraft
final results = await AppReferSDK.support.articles(query: 'refund'); // server search (titles, summaries, bodies), up to 20
try {
  final article = await AppReferSDK.support.article('refunds'); // AppReferHelpArticleDetail: + body (markdown)
} on SupportException catch (e) {
  if (e.status == 404) {/* removed or unpublished */}
}

// Is Support ready?
final status = await AppReferSDK.support.status();
status.pushReady; // this platform's push configured and accepted by Apple / Google
status.emailReplies; // customers can answer reply emails
status.helpCentreArticles; // published articles
```

`status()` follows the server's caching (5 minutes once every configured channel is verified, else 30 seconds), so calling it on every launch is cheap. Register push tokens only when `pushReady` is true. The line under a customer's last message follows the same status: "we'll notify you" when push is ready and the app registered, "we'll email you" when replies are emailed and the customer gave an email in `identify`, otherwise "the team's reply will appear here". On Android the `apprefer_support` notification channel is now named in the chat's language.

## Tracking consent (0.6.0)

The SDK never prompts for ATT. On iOS, it reads the current ATT status:
authorized → `granted`, denied/restricted → `denied`, and notDetermined →
`undetermined` (before iOS 14: `granted`). Call
`trackingConsentDidChange()` immediately after your app's own ATT prompt.
Configure and app activation also check for a changed decision, independently
of the first-open attribution flag. A failed report retries on the next trigger;
a successful report updates the cached attribution and saved reported consent.

On Android, call `setTrackingConsent(true)` or `setTrackingConsent(false)`
with your app's choice. The choice persists across launches. Until set (or after
passing `null`), requests omit `tracking_consent` and retain legacy routing.

```dart
// Android: persist the app's tracking choice (null restores legacy routing).
await AppReferSDK.setTrackingConsent(false);
// iOS: immediately after awaiting YOUR app's ATT prompt:
await AppReferSDK.trackingConsentDidChange();
```

Every attribution, event, user-linking and billing request selects its host from
the current consent: granted uses only `https://trk.apprefer.com`;
denied/undetermined use only `https://apprefer.com`, with no cross-host
fallback. Android legacy requests retain tracking-host primary and main-host
fallback. Support always uses `https://apprefer.com`. IDFA is sent only when
granted; GAID is sent only when granted or legacy. Advanced matching is dropped
locally unless tracking is granted or legacy. First-party analytics, billing and
support continue to work when tracking is denied.

For iOS apps (including Flutter and React Native), declare **only**
`trk.apprefer.com` in your app's `PrivacyInfo.xcprivacy` tracking-domain list:

```xml
<key>NSPrivacyTrackingDomains</key>
<array>
    <string>trk.apprefer.com</string>
</array>
```

Do not add `apprefer.com` to `NSPrivacyTrackingDomains`; it serves the
first-party path when ATT has not been granted.

## SKAdNetwork and AdAttributionKit (0.7.0+)

Apple's own ad attribution works for every iOS install, including users who don't allow tracking: the phone ties the install to the ad and Apple sends the ad network an anonymous postback with your app's conversion value. Only the app can set that value, and Apple sends no postback until the app sets it at least once.

AppRefer does this for you:

- On first launch it registers the install (value 0, coarse `low`), as Apple recommends.
- It then sets the value AppRefer computes from what it already knows: **10** (`medium`) once a free trial starts, **20 + whole dollars paid** (`high`, capped at 63) once the user pays, e.g. $9.99 → 30, $39.99 → 60. Values only go up and windows are never locked early.
- It checks on launch, when the app becomes active, after trial or revenue events and after AppReferBilling purchases, for the 35 days Apple's postbacks cover. If you take payments outside AppReferBilling, call `await AppReferSDK.updateConversionValue()` after a purchase to set it sooner.
- It updates both AdAttributionKit (iOS 17.4+) and SKAdNetwork (iOS 15.4+), as Apple asks when your ad networks may use either.

To receive copies of the winning postbacks in AppRefer, add to your app's Info.plist:

```xml
<key>NSAdvertisingAttributionReportEndpoint</key>
<string>https://apprefer.com</string>
<key>AdAttributionKit</key>
<dict>
    <key>AttributionCopyEndpoint</key>
    <string>https://apprefer.com</string>
</dict>
```

Also add the `SKAdNetworkItems` identifiers your ad networks publish.

On Android, the public conversion-value API is a no-op.

## Offerings (0.8.0)

Configure named offerings, packages, placements, targeting and experiments in AppRefer. Your paywall reads the store products without hard-coding product ids.

```dart
final offerings = await AppReferBilling.offerings();
final annual = offerings.currentOffering('onboarding')?.annual;
if (annual != null) {
  // Show annual.storeProduct.price in your paywall.
  final result = await AppReferBilling.purchasePackage(annual);
}
```

`current` is the resolved default, and `all` contains offerings by identifier. Each offering has JSON `metadata`, `availablePackages`, a package lookup, and `weekly`, `monthly`, `twoMonth`, `threeMonth`, `sixMonth`, `annual` and `lifetime` shortcuts. `$rc_*` package identifiers are accepted alongside `$ar_*`; unrecognized types become `custom`. Packages missing a product for this platform or unavailable in the store are omitted.

Unknown placements fall back to current; a configured null placement suppresses the paywall. Placement lookups return a copy carrying placement attribution. Purchase the package to send its offering/package, placement, targeting and experiment context, plus the persistent install bucket. Context survives pending purchases and retry-queue restarts.

Offerings use a five-minute memory and disk cache. Foreground refreshes stale data; login/logout invalidates it and refreshes an already-used catalogue. Network/server failures return the last cached response of any age after resolving store products again. No cache means the SDK billing error is thrown; catch it and use your existing paywall product ids. Offerings never gate configuration or purchases. Concurrent callers share one request.

Google Play `subscription:basePlan` selects that base plan; a bare subscription selects the period matching the package type, otherwise the first base plan. The package exposes the selected offer token. Storefront country uses ISO alpha-2 when available; no device locale is substituted. The install bucket stays stable after login/logout.

### Collection control (0.9.1)

```dart
await AppReferSDK.setCollectionEnabled(false);
```

Call this when collection consent is withdrawn. The choice persists across launches. Disabling cancels in-flight attribution, conversion-value, consent and product-event traffic, clears the durable event queue, and blocks activation/background retries. Configure returns cached attribution (or an unavailable/failed result if none exists) while disabled. Support and Billing continue independently. Call `setCollectionEnabled(true)` and then configure again to resume; enabling alone sends nothing. Calling it with `true` while collection is already on changes nothing (no pause, no queue clear). `configure` with a `userId` still stores it while collection is off, so Support uses that account, and `getDeviceId()`/`getAttribution()` keep returning the stored values. It never throws; if the choice can't be saved, collection still stops for this session. Reset does not change this choice.

Product events include `app_user_id` from the identity set via `setUserId` when tracked. The identity is saved in the queued payload, so retries and relaunches retain the original account even after a user switch. Without an identity the field is omitted. Internal events whose names start with `_` retain their existing payloads.
