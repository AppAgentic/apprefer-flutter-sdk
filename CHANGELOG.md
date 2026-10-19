## 0.13.0 (unreleased)

- Support photo/video testimonials: `AppReferSDK.support.testimonials` (`pending()`, `request()`, `present(context, requestId)`, `rewardStatus()`, `withdrawPublication()`, `cameraAvailable()`, `onRewardUpdate`) and `AppReferTestimonialScreen`; the chat draws request cards. Native picking/normalising through the support channel (`testimonialPick`, `testimonialCameraAvailable`, `testimonialDiscard`) with the shared `TestimonialMedia` sources; uploads stream the file with progress. A request is made only by something the app trusts (its backend or coach tool with a private key, a person in Support, the AI within the app's policy, automation); the SDK answers it for the account its support session is verified for, shows the campaign's reward and exact public-use permission text, uploads to a presigned URL (`POST /api/support/v1/testimonials/{id}/uploads`, then `…/submit` with `{ uploadId, clientSubmissionId, publication, permissionVersion }`), and reports the reward state the app's backend confirms. Retries reuse the same upload and client id; a reset or account switch cancels a capture in progress. Requests announce `testimonials` in `X-AppRefer-Support-Features`. 23 new `support.testimonial.*` strings in all 35 languages (161-key table). No new dependency.
- Version 0.13.0 (prerelease source; not tagged or released).

## 0.12.0 (unreleased)

- Support option cards copy (reviewed with @copy): neutral wording for ordinary full-price plans, credit packs and one-off purchases ("Options for you", "See options", "These options are no longer available", "Update the app to open this"); each price shows the store's own billing period ("£29.99/year") from Google Play's recurring pricing phase `billingPeriod` / StoreKit's subscription period, never a free-trial or introductory phase; one-time purchases and periods outside week/4 weeks/month/2, 3, 6 months/year show the bare store price; an owned one-off is tagged "Purchased" ("Current plan" stays for subscriptions). 8 new strings in all 35 languages (138-key table).
- Support review cards: an optional "Write a review" card the team can attach to a reply. It opens the App Store write-review page on iOS or the Google Play listing on Android through the existing `openUrl` support channel (no native bridge change), after the same ≤ 3 s `opened` receipt check as offer cards. Only those exact URL shapes are opened; no stars, never claims a review was written. `AppReferSupportReviewCard` is exported. Requests announce `reviews` in `X-AppRefer-Support-Features`. Neutral copy in 35 languages (8 new `support.review.*` keys, 130-key table). No new dependency.
- Support offer cards: a team member or the AI assistant can attach one of the app's AppRefer Billing offerings to a reply. The chat draws a card (title, packages with the store's own formatted prices when AppRefer Billing is configured, "Current plan" tag, "View offer") in the Concierge style, light and dark, and calls the new `onOffer` callback with `{ cardId, conversationId, offeringId, packageId }` so the app opens its own paywall (`closesChatOnOffer`, default true, closes the chat first). No paywall, purchase, price, discount or deadline of the SDK's own; a tap is an `opened` receipt, never a purchase. Disabled states: owned, no longer available, and "can't be opened in this version" when the app sets no `onOffer`. Requests send `X-AppRefer-Support-Features: offers[, offer-handler]` and the thread asks for `?platform=`; cards refresh on open, every 30 s, after Billing changes and on foreground (`GET …/conversations/{id}/offers`). `shown`/`opened` receipts (`POST …/offers/{cardId}/events`) are queued on the device (7 days, 8 attempts, same id on every retry) and dropped by `reset()`/`clearIdentity()`; an `opened` tap waits at most 3 s for the server and redraws a withdrawn card instead of opening the paywall. 15 new `support.offer.*` strings in all 35 languages (122-key table).
- Support: `verifyIdentity(identityToken)` confirms who the customer is with a short-lived, single-use token your backend gets from AppRefer (`POST /api/v1/apps/{appId}/support/identity-tokens`, private key, never in the app). It verifies the current Support session (`POST /api/support/v1/session/identity`), so existing conversations on it count; returns `{ verified, reason, appUserId }`. Network and server failures are retried with the same token (the server acknowledges a retry from the same session), then thrown. A reset, `clearIdentity()` or a different user id while it runs answers `account_changed`; the token is never stored or logged. After `clearIdentity()` nothing is sent (`identity_cleared`). `identify(name, email)` is unchanged.
- Version 0.12.0 (prerelease source for the actionable Support roadmap; not tagged or released).

## 0.11.2 (unreleased)

- Support: `.plain` header style now also draws the avatar on the home's Continue card (the chat icon, or the first team member's initial) in the header's neutral greys (`#6B6B6B` to `#3A3A3A`, white glyph ≥ 5:1) instead of the accent's neighbours, which were pale mint for a white accent. The AI persona's portrait still covers it. No new API; the default accent style is unchanged, and the help tiles, conversation list and chat are untouched.
- Version 0.11.2. No other change.

## 0.11.1 (unreleased)

- Support: `AppReferSDK.support.headerStyle` (`AppReferSupportHeaderStyle.accent` default, `.plain`, exported from `package:apprefer/apprefer.dart`). Pure Dart UI, so iOS and Android get it with no native change. `.plain` draws the help home's header as one flat neutral grey (dark `#1C1C1C`, light `#EBEBEB`) with white / near-black text and matching status bar style: no accent fill, no radial glows, neutral presence pill, close button, initials tile and presence avatars (the AI portrait still shows). For apps whose design has no colour accents, where even a white `accentColor` gave the hero tinted glows. `.accent` is unchanged; bubbles, buttons and the rest of the chat keep `accentColor` in both.
- Version 0.11.1. No other change: lifecycle engagement stays off / dry run, Billing and attribution are untouched.

## 0.11.0 (unreleased)

- Lifecycle engagement: `AppReferSDK.engagement` (`start`, `setPushToken`, `refreshDeviceState`, `notificationPermission`, `channelEnabled`, `preferences`/`setPreferences`, `identify`, `logout`, `deleteInstall`, `handleMessage` for your FCM handlers, `onNotificationEvent`, `setNavigationReady`, `drain`). Off unless the app starts it and AppRefer enabled it for the app (dry run on the server in this release).
- Native: iOS plugin registers AppRefer's button categories (merged), handles responses through Flutter's notification forwarding (or `AppReferPlugin.handleEngagementResponse` from your own delegate), snoozes locally, keeps the credential in the Keychain; Android plugin renders notifications with the same renderer as the Android SDK (channels, image, buttons, snooze, nonce-checked taps) and keeps the credential encrypted with a Keystore key. Outcomes wait in a small native outbox until Dart drains them, each once.
- Product events carry `X-AppRefer-Install` only for chosen events while the identity is current; `reset()` logs engagement out.
- Review fixes (before release): queued events carry the account epoch they were queued under (in their stamp, and as `X-AppRefer-Install-Epoch` with the credential), and the last confirmed epoch is persisted per install, so an event queued under one account never goes out for another after a cold restart, a backend bind or a logout; preference changes, sign-in and logout send the epoch they were made for (`expectedEpoch`, required by the server) and a stale one is refused (`identityChanged`; a stale saved logout is settled, never applied to the next account); reading preferences learns their epoch; an expired notification never navigates, even when its tap waited for `setNavigationReady`; sources shared by copy with the other SDKs are hash-checked by this repo's tests (`shared-sources.json`).
- Android: the shared renderer's posting and expiry fixes (see the Android SDK). iOS: the plugin removes AppRefer's pending and delivered local snoozes on any identity change and fences late adds (`EngagementSnoozeGuard`, native tests run by `flutter test` on macOS); native events carry `expiresAt`.
- New strings `engagement.*` in 35 languages. Version 0.11.0.

## 0.10.1 (unreleased)

- Support push on iOS: `registerPushToken` without `environment` no longer defaults to production. The plugin reads the APNs environment from the app's signing (embedded profile's `aps-environment`: `development` = sandbox, `production` = production; no profile, as on App Store and TestFlight, or an unreadable one = production; Simulator = sandbox), so a development-signed Release build registers sandbox tokens. Android stays production. A failed native read falls back to production and is retried on the next call.
- New `AppReferSDK.support.pushEnvironment` ('production' | 'sandbox' | null) to force it; `registerPushToken(token, environment: …)` still wins for that token.
- `status().pushReady` on iOS checks the same effective environment (new `AppReferSupportStatus.pushEnvironment`); unknown still fails closed when either environment was rejected.
- A reset, clearIdentity or account switch while the environment is being read throws a Support reset error and posts nothing.
- Version 0.10.1.

## 0.10.0 (unreleased)

- Help centre in the Support chat. With published articles, the help home shows a "Help articles" card (search entry, top three, "See all"); a help centre screen lists every article by category with search (instant local filter, then the server's search 300 ms after the last keystroke); an article reader renders markdown with a small internal parser, no new package (`SupportMarkdown`: headings, setext headings, ordered/unordered/nested/task lists, quotes, fenced code, rules, https images; inline bold, italic, code, strikethrough, links). HTML is stripped (script/style with their content) and links keep only http(s) and mailto. "Still need help? Message us" returns to the message field with the article's title as the subject. No articles: no section. The help screens live inside the chat view, so they share its theme, RTL and back handling. Concierge design, 35 languages.
- New `AppReferSDK.support.articles({query})`, `article(slug)` (throws `SupportException`, `status` 404 when missing) and `status()` (`AppReferSupportStatus`: `pushReady` for the current platform, `emailReplies`, `helpCentreArticles`, raw push/email fields). Help requests need only the SDK key (no support session); lists and articles are cached in memory for five minutes, with the last copy used offline; the status honours the server's Cache-Control (5 min / 30 s). `SupportException`, `SupportErrorReason` and the help models are now exported.
- New `AppReferSDK.support.openArticle(slug)`, `openHelpCentre()` and `AppReferSupportView(opening: AppReferSupportDestination.helpCentre / .article(slug) / .conversation(id) / .home)`; Back always leads to the help home.
- The line under the customer's last message says how the reply will reach them: notification (push ready and registered), email (replies emailed and an email was given), or "the team's reply will appear here".
- Native bridges: new `openUrl` method (http(s)/mailto only, checked again natively) for article links; Android's `apprefer_support` notification channel is named in the chat's language (it was always English).
- 22 new strings (`support.help.*`, `support.status.*`) in all 35 languages; the shared table now has 100 keys.
- Version 0.10.0.
- Support chat localized into 35 languages (ar, ca, cs, da, de, el, en, es, es-MX, fi, fr, he, hi, hr, hu, id, it, ja, ko, ms, nb, nl, pl, pt-BR, pt-PT, ro, ru, sk, sv, th, tr, uk, vi, zh-Hans, zh-Hant): every title, button, placeholder, quick-help tile, status line, error and accessibility label. Strings ship as a Dart table (`lib/src/support/support_strings_table.g.dart`), generated by `tool/generate_support_strings.dart` from `Localization/support-strings.json`, the 78-key table shared with the iOS, Android and React Native SDKs. Plural labels follow CLDR rules per language. No `localizationsDelegates` needed in the host app.
- The chat follows the locale the host app is running in (the `Localizations` locale of the widget tree it opens in, resolved from the app's `supportedLocales`), then the device's languages, then English, so an app that ships fewer languages gets a chat that matches it. `AppReferSDK.support.language` forces one.
- New `AppReferSDK.support.strings` (`Map<String, String>`): your text for any key, used before the bundled translations in every language (`{placeholders}` filled by name; plural keys as `key#one` etc. or the bare key).
- `replyTime`, `title` and the built-in topics (`AppReferSupportTopic.billing`, `.restore`, `.bug`, `.idea`) default to the chat's language; values you set are shown as written. `replyTime` is still a `String` property. New `AppReferSupportTopic.id`: `billing`, `restore`, `bug`, `idea` for the built-in tiles, the title for your own.
- Errors in the chat are shown in the customer's language (offline, rate limit, message too long, upload failed, couldn't load, not sent, image unreadable, device locked) instead of the server's English message. The exception's `message` still carries the raw text for logs.
- Right-to-left: Arabic and Hebrew lay the chat out right to left, including the bubble tails, the back chevron and the screenshot remove buttons; dates and times use the chat's language (new dependency `intl`, `>=0.18.1 <1.0.0`).
- README: RevenueCat examples replaced with AppRefer Billing ones.

## 0.9.3

- Billing's account gate now survives a relaunch: reset() saves the Billing app user id that was current then (anonymous or not) as `apprefer_billing_reset_user`, next to Billing's own user id. While Billing still serves that user, customers/purchases requests carry no install device id or device attributes, there is no one-time re-link, and identify sends `link: false`. Any explicit `AppReferBilling.logIn(…)` (even with the same id) or `logOut()`, or a change to a different Billing user, clears it. Nothing is saved when Billing was never configured.
- registerPushToken with a token that a pending Support session revocation still holds (including tokens saved by 0.9.1 without an environment) no longer posts it at once: the revocation is flagged to move the token with the environment now known, and it is registered on the current session only after the old session is revoked.
- reset() never marks a user that logOut() just created: the fresh anonymous id minted by `AppReferBilling.logOut()` in this app session is not saved as the reset marker (an app that signs out with logOut() before reset(), or doesn't wait for reset()), and a marker write that finishes after a logIn/logOut is skipped. A user set by logIn is still marked by a later reset(). Only a logIn/logOut that succeeded (counted after the new user is stored), or a `configure(appUserId:)` with a different user, cancels a running reset()'s marker; a configure with the same id resumes the previous user, who is marked. The logOut exemption is used once: a second reset() while that anonymous user is still current marks it.
- The Support revocation pass already ran again when a revocation was queued during a pass; the "running" handle is now cleared in the same step that ends the loop, so a request at that moment is never left for the next foreground.
- The clearIdentity() flag is now kept in the Support secure store next to the session token (iOS Keychain, Android Keystore-encrypted storage), like the "minted while cleared" marker, so a reinstalled iOS app whose Keychain session survived still knows it was cleared. A copy saved in SharedPreferences by 0.9.2 is moved on first read; a secure store that can't be read counts as cleared, and while it can't be read no Support session is minted or adopted (a retryable error), so a session is never wrongly marked as cleared and later retired. Retiring a cleared session only deletes that session's token.
- configure(userId:) and setUserId never throw when the clearIdentity() flag can't be removed: the new user id is then not stored, Support stays anonymous, and configure and attribution go on.

## 0.9.2

- Billing sends no install device id (`appreferId`) or device attribute (`$idfa`, `$idfv`, `$fbAnonId`, `$attConsentStatus`, `$deviceVersion`, `$ip`, `$gpsAdId`) with customers/purchases requests while collection is off (saved, unsaved or turned back on but not yet configured), after reset() until configure/configureResult runs again, or in Billing-only apps. It reuses the Support device id gate (now shared, and Support also respects the "waiting for configure" pause); queued purchases are resent without it while the gate is closed, and Billing then uses apprefer.com rather than trk.apprefer.com. Purchases, restore, entitlements and offerings are unchanged. A customer registered without the device id is linked once after configure.
- Add `AppReferSDK.support.clearIdentity()`: forgets the Support name, email and app user id, revokes the current Support session through the durable revocation path and starts a new anonymous session (push token and its environment carried over). Conversations from the old session are no longer visible in the app; they stay in the team inbox. Support stays anonymous until the user id changes or reset() runs.
- Billing sends the device id only for the Billing user set after the last reset() (engine creation, `AppReferBilling.logIn` or `logOut`): after reset() the user Billing served before, purchases owned by anyone but the current Billing user and queued entries from a previous account get none, and nobody from before the reset is re-linked. Call `AppReferBilling.logIn`/`logOut` for the next account. Identify now sends `link` (false while the gate is closed, so the server merges purchases without copying the attribution link).
- clearIdentity(): the anonymous session sends no device id either. A different user id stored later without reset() gets a fresh Support session and the cleared one is revoked (it is never upgraded to the new account). The push token moves to the new session only after the old session's revocation succeeds; a token registered before 0.9.2 (no saved environment) is not moved and is re-registered by the app's next `registerPushToken`.
- An error in the Billing link gate (e.g. unreadable preferences) is read as "closed" instead of failing the request.

## 0.9.1

- Migration: after reset(), call configure again for the next user; until then events, attribution and consent reports are paused.
- Configuring again with the same config after reset() stores the user id again (and syncs it), so events and Support carry it. Support also omits the device id when saving "off" failed.
- Product events capture `app_user_id` at track time and persist it with the queued payload, preserving identity across retries, restarts, and account switches. Internal `_` events are unchanged.
- Add persistent `setCollectionEnabled` control. Disabling cancels attribution, consent, conversion-value and event requests and clears queued events; Support and Billing remain available. Enable, then call configure to resume.
- Support sends no device id after reset() or while collection is off. reset() also stops attribution (consent re-reports, conversion values, user id, advanced matching, event sends) until configure is called again; events tracked meanwhile are dropped, never queued or sent later.
- setCollectionEnabled(true) while collection is already on is a no-op: it no longer pauses collection or clears the saved event queue. Only a saved "off" or the server kill switch clears queued events.
- configure(userId:) stores the user id even while collection is off, so Support uses the new account.
- With collection off at launch, getDeviceId() and getAttribution() return the stored values after configure, like iOS and Android.
- setCollectionEnabled never throws; disabling stops and clears at once even if the choice can't be saved.

## 0.9.0 — 2026-10-16

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
