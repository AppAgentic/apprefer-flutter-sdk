# Privacy packaging and conversion ownership

Source-only correction after0.13.3; no existing tag is replaced. Integrators may pin the reviewed immutable Git commit before a coordinated SDK release. No billing migration is required.

```dart
await AppReferSDK.configure(AppReferConfig(
  apiKey: appReferKey,
  automaticConversionValues: false,
));
```

Default is true, preserving existing apps. False gives ownership to the host's existing Apple conversion-value implementation: no AppRefer initial0/low registration, conversion-value HTTP polls or native value updates, including manual refresh, resume and delayed recheck. Changing configuration cancels the old owner permanently, including pending completions. This option is independent of ATT; it does not disable Apple AdServices, attribution configure, analytics, billing or consent reporting. It does not disable the host's Meta SDK or make its schema correct. GymLevels keeps Meta as sole updater pending independent schema verification. Android has no native conversion updater.

## Manifest resource

The podspec packages Resources/PrivacyInfo.xcprivacy in apprefer_privacy.bundle. Verify the final signed archive includes it and inspect Xcode's aggregate privacy report; podspec/plist validation does not establish archive inclusion. Only trk.apprefer.com is a tracking domain. apprefer.com is the first-party non-granted endpoint; do not classify it as tracking to solve a server consent bug. Tracking declarations describe supported consent-enabled behavior and never grant permission themselves.

Source inventory:

- DeviceID/UserID: services/storage.dart persistent AppRefer UUID, apprefer_sdk.dart user identity/configure/event stamps; IDFA only granted. App Functionality/Analytics and authorized advertising matching.
- ProductInteraction: event queue/custom app events and install/activation; analytics and authorized ad measurement. Functionality includes engagement/in-app customer context.
- PurchaseHistory: optional Billing API and purchase lifecycle/entitlement operations; functionality/analytics and consent-enabled advertising measurement. No extra purchase stream is initialized by this correction.
- CoarseLocation: backend request country/locale and attribution region (`web/app/api/track/configure/route.ts`, request-geo.ts). No SDK GPS access. Location comes from network/locale/attribution signals, may support analytics/ad measurement and regional operation.
- Optional EmailAddress/PhoneNumber/Name: setAdvancedMatching hashes host-supplied fields only when consent allows; Support customer profile may also use host-supplied contact data for functionality. Hashing does not remove tracking purpose.
- OtherDataTypes: optional hashed dateOfBirth in setAdvancedMatching. No automatic birthday acquisition.
- Optional CustomerSupport/OtherUserContent: support chat/customer submissions; App Functionality, not advertising matching.
- Optional PhotosorVideos/AudioData: support images and opt-in testimonial media. TestimonialMedia.swift camera video may contain audio, with required host usage-key guards; only user-selected/captured/uploaded media. No background recording. Core attribution does not collect this media.

These are SDK capabilities. A host's Apple labels and policy must describe its actual enabled use and backend sharing. In particular no claim is made that GymLevels uses Support/testimonial/media/advanced-matching fields. The SDK manifest is not a substitute for the host's own declarations, other SDK manifests or actual payload review. Actual optional GymLevels forwarded fields are still unverified.

Direct required-reason use: EngagementBridge.swift UserDefaults.standard and app-group suite storage; EngagementSnoozeGuard.swift preference replay/dedup. CA92.1 covers own-app preferences and1C8F.1 the authorized app group. C56D.1 is not appropriate merely because this is SDK code. No direct timestamp/uptime/disk-space API use found in the bounded Swift inventory; FileManager attributesOfItem reads file size only in PushEnvironment/TestimonialMedia, not timestamps. Dependency required-reason APIs remain declared by their own manifests.

No host microphone/camera purpose strings are added. Dormant support capture is guarded by host usage-key presence. Dead stripping is not assumed; final archive/upload checks remain host-owned. Do not invoke media capture without the corresponding truthful host usage descriptions.

## Integration and release scope

Pin the new immutable Git commit (not0.13.3), resolve Pods and lockfiles, set false only in GymLevels, preserve device UUID/RC appreferId, then validate manifest inclusion and conversion native-call/poll interception before one consolidated archive. No SDK registry publish/tag or backend deploy follows automatically.

Parity follow-up owner: AppRefer thread/gymlevels-native-consent-correction. Add the same ownership control and privacy resource audit to native iOS/React Native configuration before the next coordinated version release; Android config can expose a no-op option for parity. This narrow Flutter source commit intentionally keeps version0.13.3 until an explicitly authorized coordinated release; consume by immutable hash, never claim it is the existing0.13.3 tag.

Primary Apple references: https://developer.apple.com/documentation/storekit/skadnetwork ; https://developer.apple.com/documentation/bundleresources/privacy-manifest-files ; https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype .
