## Unreleased

- Add AppRefer Billing (`AppReferBilling`), an App Store / Google Play purchases and entitlements module that replaces RevenueCat, built on the official `in_app_purchase` plugins (StoreKit 2 on iOS 15+, Play Billing on Android):
  - `configure(apiKey:, appUserId:, entitlementsByProduct:, defaultEntitlement:, consumableProductIds:)` with an anonymous `$ARAnon:<UUID>` id, and the store purchase listener started at configure
  - `products()`, `purchase()` (sets Apple `appAccountToken` / Google `obfuscatedAccountId` to the AppRefer account token; promotional, win-back and Google subscription-change options), `restorePurchases()`
  - Sends the StoreKit 2 signed transaction (iOS) or the purchase token (Android) to AppRefer and only then completes the purchase; Google consumables are consumed after AppRefer accepts them
  - `customerInfo(fetchPolicy:)`, `customerInfoStream`, `addCustomerInfoUpdateListener`; `entitlements['premium']?.isActive`; `CustomerInfo.source` (server / cache / localFallback)
  - `logIn()` (merges anonymous purchases via `/identify`), `logOut()`, `setAttributes()`, `setEmail` / `setDisplayName` / `setPhoneNumber`
  - Outage safety: falls back to the store's own active purchases merged with the same user's cached server answer; purchases AppRefer can't accept are queued on disk, completed, and resent later (50 attempts / 90 days)
  - Sends the AppRefer attribution device id as `appreferId` automatically
  - Uses the attribution SDK key and the `trk.apprefer.com` → `apprefer.com` fallback
- Requires Flutter 3.41 / Dart 3.11 (minimum of `in_app_purchase_storekit` 0.4.13+1)

## 0.3.5

- Use `trk.apprefer.com` as primary tracking endpoint for lower latency
- Add automatic fallback to `apprefer.com` if tracking endpoint is unreachable
- Tracking endpoints affected: `/api/track/configure`, `/api/track/event`

## 0.3.0

- Harden SDK to never crash host app
- Remove throws from all public API methods — silently no-op if called before configure()
- Fix DateTime.parse crash on malformed server timestamps

## 0.2.1

- Fix kill switch response key (`sdk_enabled` → `sdkEnabled`)

## 0.2.0

- Use SDK key as sole credential — `configure(apiKey:)` replaces `configure(appId:)`
- Add Google Play Install Referrer for deterministic Android attribution
- Centralize version string via `appReferVersion` constant
- Remove backendUrl from public API

## 0.1.0

- Initial release
