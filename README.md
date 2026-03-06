# AppRefer Flutter SDK

First-party mobile attribution for Flutter apps.

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  apprefer:
    git:
      url: https://github.com/AppAgentic/apprefer-flutter-sdk.git
```

## Quick Start

```dart
import 'package:apprefer/apprefer.dart';

// Call once at app launch (e.g., in main() or first screen)
final attribution = await AppReferSDK.configure(AppReferConfig(
  backendUrl: 'https://trk.yourdomain.com',
  appId: 'your-app-id',
));

if (attribution != null) {
  print('Attributed to: ${attribution.network} via ${attribution.matchType}');
}
```

## Configuration Options

```dart
AppReferConfig(
  backendUrl: 'https://trk.yourdomain.com',  // Required — your AppRefer backend
  appId: 'your-app-id',                       // Required — matches your dashboard app
  userId: 'user-123',                          // Optional — set user identity at init
  debug: true,                                 // Optional — enable debug logging
  logLevel: 3,                                 // Optional — 0=none, 1=errors, 2=warnings, 3=verbose
)
```

## API

### `AppReferSDK.configure(config)`

Resolves attribution on first launch. Subsequent calls return the cached result instantly (no network call).

Returns `Attribution?` with fields:
- `network` — attributed ad network (e.g., `meta`, `google`, `tiktok`, `organic`)
- `matchType` — how attribution was resolved (`adservices`, `click_id`, `referrer`, `fingerprint`, `probabilistic`, `organic`)
- `campaign`, `campaignId`, `campaignName` — campaign details
- `fbclid`, `gclid`, `ttclid` — raw click IDs (when available)

### `AppReferSDK.trackEvent(name, {properties, revenue, currency})`

Track non-purchase events. Purchases should be tracked via RevenueCat webhooks.

```dart
await AppReferSDK.trackEvent('tutorial_complete');

await AppReferSDK.trackEvent('signup', properties: {'method': 'google'});
```

### `AppReferSDK.setAdvancedMatching({email, phoneNumber, firstName, lastName})`

Improve ad network match rates by sending hashed user PII. All data is SHA256-hashed on-device before sending.

```dart
await AppReferSDK.setAdvancedMatching(
  email: 'user@example.com',
  firstName: 'John',
);
```

### `AppReferSDK.setUserId(userId)`

Link a RevenueCat `app_user_id` to this device's attribution.

```dart
await AppReferSDK.setUserId(Purchases.appUserID);
```

### `AppReferSDK.getAttribution()`

Get the cached attribution result (no network call).

### `AppReferSDK.getDeviceId()`

Get the AppRefer device ID for use as a RevenueCat subscriber attribute.

## Platform Setup

### iOS

No additional setup required. The SDK automatically collects the AdServices attribution token.

### Android

Add the Install Referrer dependency to your app's `android/app/build.gradle`:

```gradle
dependencies {
    implementation 'com.android.installreferrer:installreferrer:2.2'
}
```

## Requirements

- Flutter 3.0+
- Dart 3.0+
- iOS 12+ / Android API 21+

## License

MIT
