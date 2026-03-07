# AppRefer Flutter SDK

First-party mobile attribution for Flutter apps. Captures click IDs, resolves attribution, and forwards conversions to ad networks — without third-party SDKs.

[![Flutter 3.0+](https://img.shields.io/badge/Flutter-3.0+-blue.svg)](https://flutter.dev)
[![Dart 3.0+](https://img.shields.io/badge/Dart-3.0+-blue.svg)](https://dart.dev)
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

Get your **API Key** from the [AppRefer dashboard](https://apprefer.com) → Setup.

```dart
import 'package:apprefer/apprefer.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final attribution = await AppReferSDK.configure(AppReferConfig(
    apiKey: 'pk_...',
  ));

  if (attribution != null) {
    print('Attributed to: ${attribution.network} via ${attribution.matchType}');
  }

  runApp(MyApp());
}
```

## API

### Configure

Call once at app launch. Resolves attribution on first install, returns cached result on subsequent launches.

```dart
final attribution = await AppReferSDK.configure(AppReferConfig(
  apiKey: 'pk_...',
  userId: null,       // optional — link RevenueCat user ID at init
  debug: false,       // optional — enable verbose logging
  logLevel: 1,        // optional — 0=none, 1=errors, 2=warnings, 3=verbose
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

## Best Practices

- **Call `configure()` once** — ideally in `main()` before `runApp()`. The SDK deduplicates automatically; subsequent calls return the cached result with no network overhead.
- **Set the RevenueCat user ID early** — call `AppReferSDK.setUserId()` right after `Purchases.configure()` so purchase webhooks can be attributed to the correct device.
- **Call `setAdvancedMatching()` after login/signup** — this sends hashed PII to improve Meta CAPI match rates. Only needs to be called once per user session.
- **Don't track purchases with `trackEvent()`** — revenue events are handled automatically via RevenueCat webhooks. Use `trackEvent()` only for non-purchase milestones like `signup`, `tutorial_complete`, or `onboarding_finish`.
- **Use the Debugger** — verify events are flowing correctly in the [AppRefer dashboard](https://apprefer.com) → Debugger before going to production.
- **Android: add the Install Referrer dependency** — without it, Android attribution falls back to probabilistic matching instead of deterministic referrer-based matching.
- **No IDFA required** — on iOS, the SDK uses Apple's AdServices framework and does not require ATT permission.

## Requirements

- Flutter 3.0+
- Dart 3.0+
- iOS 14.0+ / Android API 21+

## License

Proprietary. All rights reserved.
