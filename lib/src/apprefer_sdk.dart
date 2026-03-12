import 'dart:io';

import 'config.dart';
import 'models/attribution.dart';
import 'services/adservices.dart';
import 'services/install_referrer.dart';
import 'services/device_info.dart';
import 'services/hashing.dart';
import 'services/http_client.dart';
import 'services/logger.dart';
import 'services/storage.dart';
import 'version.dart';

class AppReferSDK {
  static AppReferSDK? _instance;

  late AppReferConfig _config;
  late AppReferStorage _storage;
  late AppReferHttpClient _httpClient;
  late AppReferLogger _logger;
  late AppReferDeviceInfo _deviceInfo;
  late AppReferAdServices _adServices;
  late AppReferInstallReferrer _installReferrer;

  AppReferSDK._();

  /// Configure + resolve attribution in ONE call.
  /// On first open: sends device signals + AdServices token to backend,
  /// resolves attribution, caches locally, returns result.
  /// On subsequent opens: returns cached attribution (no network call).
  static Future<Attribution?> configure(AppReferConfig config) async {
    final sdk = AppReferSDK._();
    sdk._config = config;
    sdk._logger = AppReferLogger(
      debug: config.debug,
      logLevel: config.logLevel,
    );
    sdk._storage = AppReferStorage();
    await sdk._storage.init();
    sdk._httpClient = AppReferHttpClient(
      backendUrl: AppReferConfig.backendUrl,
      apiKey: config.apiKey,
      logger: sdk._logger,
    );
    sdk._deviceInfo = AppReferDeviceInfo(logger: sdk._logger);
    sdk._adServices = AppReferAdServices(logger: sdk._logger);
    sdk._installReferrer = AppReferInstallReferrer(logger: sdk._logger);

    _instance = sdk;

    sdk._logger.info('AppReferSDK initialized');

    // Set user ID if provided at init time
    if (config.userId != null) {
      await sdk._storage.setUserId(config.userId!);
    }

    // Record first run date
    await sdk._storage.getFirstRunDate();

    // Check kill switch from local cache
    if (!sdk._storage.isSdkEnabled()) {
      sdk._logger.info('SDK disabled by kill switch');
      return _getCachedAttribution();
    }

    // If match already attempted, return cached attribution
    if (sdk._storage.isMatchRequestAttempted()) {
      sdk._logger.info('Skipping match request: existing install detected.');
      return _getCachedAttribution();
    }

    // First run — resolve attribution
    try {
      return await sdk._resolveAttribution();
    } catch (e) {
      sdk._logger.error('Attribution resolution failed: $e');
      return null;
    }
  }

  Future<Attribution?> _resolveAttribution() async {
    final deviceId = await _storage.getDeviceId();
    final deviceInfoMap = await _deviceInfo.getDeviceInfo();

    // Get AdServices token (iOS only)
    String? asaToken;
    if (Platform.isIOS) {
      asaToken = await _adServices.getAdServicesToken();
    }

    // Get Install Referrer (Android only)
    Map<String, dynamic>? referrerData;
    String? arClickId;
    if (Platform.isAndroid) {
      referrerData = await _installReferrer.getInstallReferrer();
      if (referrerData != null) {
        arClickId = AppReferInstallReferrer.extractClickId(
          referrerData['installReferrer'] as String?,
        );
      }
    }

    final body = <String, dynamic>{
      'device_id': deviceId,
      'device_info': deviceInfoMap,
      'asa_token': asaToken,
      'install_referrer': referrerData?['installReferrer'],
      'ar_click_id': arClickId,
      'referrer_click_ts': referrerData?['referrerClickTimestampSeconds'],
      'referrer_install_ts': referrerData?['installBeginTimestampSeconds'],
      'sdk_version': appReferVersion,
      'is_debug': _config.debug,
      'customer_user_id': _storage.getUserId(),
    };

    _logger.info('Sending configure request...');
    final response = await _httpClient.post('/api/track/configure', body);

    if (response == null) {
      _logger.error('Configure request failed');
      await _storage.setMatchRequestAttempted(true);
      return null;
    }

    // Update kill switch from server
    final sdkEnabled = response['sdkEnabled'] as bool? ?? true;
    await _storage.setSdkEnabled(sdkEnabled);
    if (!sdkEnabled) {
      _logger.info('SDK disabled by server');
      await _storage.setMatchRequestAttempted(true);
      return null;
    }

    // Parse attribution
    final attributionJson = response['attribution'] as Map<String, dynamic>?;
    Attribution? attribution;
    if (attributionJson != null) {
      attribution = Attribution.fromJson(attributionJson);
      await _storage.setAttributionCache(attribution.toJsonString());
      _logger.info('Attribution resolved: $attribution');
    } else {
      _logger.info('No attribution (organic install)');
    }

    // Mark dedup flags
    await _storage.setMatchRequestAttempted(true);
    await _storage.setInstallEventSent(true);
    await _storage.setLastConfigFetch(DateTime.now().toIso8601String());

    return attribution;
  }

  /// Track non-purchase events (signup, tutorial_complete, etc.)
  /// Purchases are tracked via RevenueCat webhooks, NOT here.
  static Future<void> trackEvent(
    String eventName, {
    Map<String, dynamic>? properties,
    double? revenue,
    String? currency,
  }) async {
    final sdk = _instance;
    if (sdk == null) {
      assert(() { print('[AppRefer] trackEvent called before configure() — ignoring'); return true; }());
      return;
    }
    if (!sdk._storage.isSdkEnabled()) return;

    final deviceId = await sdk._storage.getDeviceId();
    final body = <String, dynamic>{
      'device_id': deviceId,
      'event_name': eventName,
      if (properties != null) 'properties': properties,
      if (revenue != null) 'revenue': revenue,
      if (currency != null) 'currency': currency,
    };

    sdk._logger.info('Tracking event: $eventName');
    await sdk._httpClient.post('/api/track/event', body);
  }

  /// Meta Advanced Matching: send hashed user PII to improve CAPI match rates.
  /// Call once after signup/login. Data is SHA256-hashed before sending.
  static Future<void> setAdvancedMatching({
    String? email,
    String? phoneNumber,
    String? firstName,
    String? lastName,
    String? dateOfBirth,
  }) async {
    final sdk = _instance;
    if (sdk == null) {
      assert(() { print('[AppRefer] setAdvancedMatching called before configure() — ignoring'); return true; }());
      return;
    }
    if (!sdk._storage.isSdkEnabled()) return;

    final hashedData = <String, String>{};
    if (email != null) hashedData['em'] = AppReferHashing.hashEmail(email);
    if (phoneNumber != null) {
      hashedData['ph'] = AppReferHashing.hashPhone(phoneNumber);
    }
    if (firstName != null) {
      hashedData['fn'] = AppReferHashing.hashName(firstName);
    }
    if (lastName != null) {
      hashedData['ln'] = AppReferHashing.hashName(lastName);
    }
    if (dateOfBirth != null) {
      hashedData['db'] = AppReferHashing.hashDateOfBirth(dateOfBirth);
    }

    if (hashedData.isEmpty) return;

    final deviceId = await sdk._storage.getDeviceId();
    final body = <String, dynamic>{
      'device_id': deviceId,
      'event_name': '_advanced_matching',
      'advanced_matching': hashedData,
    };

    sdk._logger.info('Sending advanced matching data');
    await sdk._httpClient.post('/api/track/event', body);
  }

  /// Set RevenueCat app_user_id so webhook events can be linked
  /// to this device's attribution.
  static Future<void> setUserId(String userId) async {
    final sdk = _instance;
    if (sdk == null) {
      assert(() { print('[AppRefer] setUserId called before configure() — ignoring'); return true; }());
      return;
    }
    await sdk._storage.setUserId(userId);
    sdk._logger.info('User ID set: $userId');

    // Sync userId to server so webhook userId fallback can find this attribution
    if (!sdk._storage.isSdkEnabled()) return;
    final deviceId = await sdk._storage.getDeviceId();
    final body = <String, dynamic>{
      'device_id': deviceId,
      'event_name': '_set_user_id',
      'properties': {'user_id': userId},
    };
    sdk._httpClient.post('/api/track/event', body).catchError((e) {
      sdk._logger.error('Failed to sync userId to server: $e');
      return null;
    });
  }

  /// Get cached attribution result (instant, no network call).
  static Future<Attribution?> getAttribution() async {
    return _getCachedAttribution();
  }

  /// Get the AppRefer device ID (for setting as RC subscriber attribute).
  static Future<String?> getDeviceId() async {
    final sdk = _instance;
    if (sdk == null) return null;
    return sdk._storage.getDeviceId();
  }

  static Attribution? _getCachedAttribution() {
    final sdk = _instance;
    if (sdk == null) return null;
    final cached = sdk._storage.getAttributionCache();
    return Attribution.fromJsonString(cached);
  }
}
