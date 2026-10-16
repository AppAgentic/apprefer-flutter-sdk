## 0.9.0 — 2026-10-16

## 0.9.1

- Product events capture `app_user_id` at track time and persist it with the queued payload, preserving identity across retries, restarts, and account switches. Internal `_` events are unchanged.
- Add persistent `setCollectionEnabled` control. Disabling cancels attribution, consent, conversion-value and event requests and clears queued events; Support and Billing remain available. Enable, then call configure to resume.

- Add async reset for account switching: cancel old work, revoke Support sessions and push registrations, clear account/profile/UI state and pending product events, retain install attribution and device id. Billing logout stays explicit.
- Add Support-only configuration with no attribution initialization or analytics.
- Persist a bounded 1,000-event / seven-day product queue with stable eventId, network/5xx backoff and launch/foreground retries; remove successful and terminal rejected events. Delivery is at least once.
- Add trackEventResult acknowledgements and clearPendingEvents; retain the existing tracking signature and respect the existing SDK kill switch.
- Add typed configureResult distinguishing attributed, confirmed organic and failure, while preserving configure.
- Add account isolation, persistence, expiry, retry, terminal rejection, cancellation and attribution-status regressions.

## 0.7.0 - 2026-10-16

## 0.8.0 — 2026-10-16

- Add RevenueCat-style Offerings, packages, placements, metadata and experiment context, with native store product resolution.
- Add five-minute memory/disk caching, shared in-flight requests, foreground refresh, identity invalidation and offline catalogue fallback.
- Add package purchases with durable offering attribution and a stable anonymous install bucket.
- Include the 0.7.1 offline fallback fix: explicitly empty entitlement mappings unlock nothing; only unmapped products use the default.
- Add paywall examples and Offerings regression tests.

- SKAdNetwork and AdAttributionKit conversion values: the SDK registers each install on first launch and raises its conversion value from AppRefer's first-party data (trial started = 10, paid = 20 + whole dollars, capped at 63; coarse low/medium/high), on launch, activation, trial/revenue events and AppReferBilling purchases, for 35 days. Works for every install whatever its ATT status.
- New `AppReferSDK.updateConversionValue()` to refresh right after a purchase made outside AppReferBilling.
- Checks after a purchase made elsewhere once more 90 seconds later (webhooks arrive a moment after the purchase); sends the first-run date so a reinstall starts fresh; iOS 15.0–15.3 use SKAdNetwork 3.
- README: Info.plist keys to receive postback copies in AppRefer (`NSAdvertisingAttributionReportEndpoint`, `AdAttributionKit.AttributionCopyEndpoint`).

## 0.6.0

- Split tracking and first-party requests by current consent, including billing; known consent never falls back across hosts. Support remains on apprefer.com.
- Add public setTrackingConsent and trackingConsentDidChange, persisted Android choices, automatic activation checks and retryable consent configure reports after first-open matching.
- Read iOS ATT without prompting; gate IDFA/GAID and drop advanced matching locally without consent.
- iOS apps declare only trk.apprefer.com in NSPrivacyTrackingDomains and call trackingConsentDidChange() after their own ATT prompt. Android apps use setTrackingConsent(true/false), or null for legacy routing.

## 0.5.0

- AI personas: approved name and portrait, explicit AI tag, and a hand-over pill when a person is needed.
- AppRefer Support: embeddable help chat, conversations, screenshot uploads, secure sessions, unread counts and push routing.
- Support chat "Concierge" design, matching the iOS SDK: hero home with presence pill, continue card, quick-help topic tiles and a floating composer; conversation with a floating header, grouped tailed bubbles, quick replies and a full-screen image viewer; light and dark.
  - Removed `replyTimeText`; added `replyTime` ("under an hour"), `teamNames`, `topics` (`AppReferSupportTopic`, optional `action`) and `appIcon` (defaults to the launcher icon).
  - `compose(text)` opens the home with the field pre-filled and focused; the separate new-message screen is gone. A picked topic becomes the conversation `subject`.

### Billing and attribution

- Add AppRefer Billing (`AppReferBilling`), an App Store / Google Play purchases and entitlements module that replaces RevenueCat, built on the official `in_app_purchase` plugins (StoreKit 2 on iOS 15+, Play Billing on Android):
  - `configure(apiKey:, appUserId:, entitlementsByProduct:, defaultEntitlement:, consumableProductIds:)` with an anonymous `$ARAnon:<UUID>` id, and the store purchase listener started at configure
  - `products()`, `purchase()` (sets Apple `appAccountToken` / Google `obfuscatedAccountId` to the AppRefer account token; promotional, win-back and Google subscription-change options), `restorePurchases()`
  - Sends the StoreKit 2 signed transaction (iOS) or the purchase token (Android) to AppRefer and only then completes the purchase; Google consumables are consumed after AppRefer accepts them
  - `customerInfo(fetchPolicy:)`, `customerInfoStream`, `addCustomerInfoUpdateListener`; `entitlements['premium']?.isActive`; `CustomerInfo.source` (server / cache / localFallback)
  - `logIn()` (merges anonymous purchases via `/identify`), `logOut()`, `setAttributes()`, `setEmail` / `setDisplayName` / `setPhoneNumber`
  - Outage safety: falls back to every verified store purchase on the device merged with the same user's cached server answer; server answers also include the customer's own verified store purchases (no account token, their token, or still queued); purchases AppRefer can't accept are queued on disk and resent later (50 attempts / 90 days; 401/403/404/409/429 back off without using attempts and honour `Retry-After`); Google purchases are acknowledged on device at once and consumables consumed only after AppRefer records them; failed acknowledge/consume retried on foreground
  - Only `restorePurchases()` sends `restore: true` (kept on queued retries); purchases are recorded for the user who started them, saved on disk before the purchase sheet opens (the sheet doesn't open if it can't be saved), so Ask to Buy and slow payments completing after a restart, logout or user switch still go to them
  - Rejected-purchase archive: purchases AppRefer refuses for good (400/413/422), without verifiable store data, or given up by the retry queue are saved with their store data before they are completed (consumables are never consumed then); `restorePurchases()` resends them and `rejectedPurchases()` lists them
  - Pending logins survive `logOut()` and are sent in order; unreadable billing storage never mints a new anonymous id
  - iOS restore fails instead of reporting an empty restore when the App Store's restored transactions don't arrive in time
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
