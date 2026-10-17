import 'dart:async';
import 'services/event_queue.dart';
export 'services/event_queue.dart' show AppReferEventResult;
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'services/tracking_consent.dart';
import 'services/conversion_value.dart';
import 'support/apprefer_support.dart';
import 'engagement/apprefer_engagement.dart';
import 'billing/billing_storage.dart';
import 'dart:io';

import 'config.dart';
import 'models/attribution.dart';
import 'services/adservices.dart';
import 'services/install_referrer.dart';
import 'services/device_info.dart';
import 'services/hashing.dart';
import 'services/http_client.dart';
import 'services/logger.dart';
import 'services/registry.dart';
import 'services/storage.dart';
import 'version.dart';

enum AttributionStatus { attributed, pending, organic, failed }

class AppReferAttributionResult {
  const AppReferAttributionResult(this.status, {this.attribution, this.error});
  final AttributionStatus status;
  final Attribution? attribution;
  final Object? error;
}

class AppReferSDK with WidgetsBindingObserver {
  Future<void>? _consentSync;
  bool _consentRecheck = false;
  int _generation = 0;
  bool _failed = false;
  late EventQueue _events;
  static AppReferSupport get support => AppReferSupport.instance;

  /// Lifecycle engagement: `AppReferSDK.engagement.start()`.
  static AppReferEngagement get engagement => AppReferEngagement.instance;
  static AppReferSDK? _instance;
  static EventQueue? _eventQueue;
  static int _accountGeneration = 0;
  static int _collectionGeneration = 0;
  // Kept in the registry so Support sees an "off" even when saving it failed.
  static bool get _collectionBlocked => AppReferRegistry.collectionBlocked;
  static set _collectionBlocked(bool value) =>
      AppReferRegistry.collectionBlocked = value;
  // In the registry too: Support and Billing link nothing while it waits for configure.
  static bool get _needsCollectionConfigure =>
      AppReferRegistry.collectionAwaitingConfigure;
  static set _needsCollectionConfigure(bool value) =>
      AppReferRegistry.collectionAwaitingConfigure = value;
  static Future<void> _collectionWrites = Future.value();
  static Future<void> _accountWrites = Future.value();
  static Future<void> _accountWrite(Future<void> Function() work) {
    final task = _accountWrites.then((_) => work());
    _accountWrites = task.then<void>((_) {}, onError: (Object _) {});
    return task;
  }

  late AppReferConfig _config;
  late AppReferStorage _storage;
  late AppReferHttpClient _httpClient;
  late AppReferLogger _logger;
  late AppReferDeviceInfo _deviceInfo;
  late AppReferAdServices _adServices;
  late AppReferInstallReferrer _installReferrer;

  late ConversionValue _conversion;

  AppReferSDK._();

  /// Disposes process state between isolated SDK tests; persisted install state is retained.
  @visibleForTesting
  static Future<void> disposeForTesting() async {
    final sdk = _instance;
    if (sdk != null) {
      sdk._httpClient.cancel();
      sdk._conversion.cancel();
      WidgetsBinding.instance.removeObserver(sdk);
    }
    await _eventQueue?.clear();
    _instance = null;
    _configuring = null;
    _requestedConfig = null;
    _eventQueue = null;
    _collectionBlocked = false;
    _needsCollectionConfigure = false;
    AppReferRegistry.stoppedByReset = false;
  }

  static Future<AppReferAttributionResult> configureResult(
    AppReferConfig config,
  ) async {
    try {
      final attribution = await configure(config);
      if (attribution?.trackingDecisionPending == true &&
          attribution?.matchType != 'adservices')
        return AppReferAttributionResult(
          AttributionStatus.pending,
          attribution: attribution,
        );
      if (attribution != null)
        return AppReferAttributionResult(
          attribution.network == 'organic'
              ? AttributionStatus.organic
              : AttributionStatus.attributed,
          attribution: attribution,
        );
      final prefs = await SharedPreferences.getInstance();
      if ((_instance?._failed ?? true) == false &&
          attribution == null &&
          prefs.getBool('apprefer_organic_confirmed') != true)
        return AppReferAttributionResult(
          AttributionStatus.failed,
          error: StateError('Attribution unavailable'),
        );
      if (prefs.getBool('apprefer_organic_confirmed') == true)
        return const AppReferAttributionResult(AttributionStatus.organic);
      return AppReferAttributionResult(
        AttributionStatus.failed,
        error: StateError('Attribution unavailable'),
      );
    } catch (error) {
      return AppReferAttributionResult(AttributionStatus.failed, error: error);
    }
  }

  /// Clears account state; install attribution and device id are retained.
  /// Attribution sends nothing, and Support sends no device id, until configure
  /// is called again.
  static Future<void> reset() async {
    // Billing's user as of this call: a logIn/logOut while reset() runs wins.
    final billingIdentity = BillingStorage.identityChanges;
    _accountGeneration++;
    AppReferRegistry.accountEpoch++;
    AppReferRegistry.stoppedByReset = true;
    _configuring = null;
    _requestedConfig = null;
    final sdk = _instance;
    if (sdk != null) {
      sdk._generation++;
      sdk._consentRecheck = false;
      sdk._httpClient.cancel();
      sdk._conversion.cancel();
      await _ignoreStorage(sdk._events.clear);
      await _ignoreStorage(() => _accountWrite(sdk._storage.clearUser));
    }
    if (sdk == null) {
      _eventQueue ??= EventQueue(
        (_) async => null,
        () => true,
        held: () => AppReferRegistry.stoppedByReset,
      );
      await _ignoreStorage(_eventQueue!.clear);
    }
    await _ignoreStorage(() async {
      final prefs = await SharedPreferences.getInstance();
      await _accountWrite(() async {
        await AppReferStorage.clearUserIn(prefs);
      });
    });
    // Billing keeps serving its user until logIn/logOut: remember who that
    // was, so a relaunch can't link them to the install.
    await _ignoreStorage(() async {
      await BillingStorage.markResetUser(
        await SharedPreferences.getInstance(),
        since: billingIdentity,
      );
    });
    await support.reset();
    // Lifecycle engagement: the account's queued messages stop, nothing waits to navigate.
    await _ignoreStorage(engagement.logout);
  }

  static Future<void> _ignoreStorage(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {}
  }

  static Future<void> clearPendingEvents() async {
    _instance?._httpClient.cancelEvents();
    if (_instance != null) {
      await _instance!._events.clear();
    } else {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(EventQueue.key);
      await prefs.remove('${EventQueue.key}.corrupt');
    }
  }

  /// Refresh iOS conversion values after purchases made outside AppRefer Billing.
  /// A no-op on Android.
  static Future<void> updateConversionValue() async {
    await _instance?._conversion.refresh(force: true);
  }

  /// Configure + resolve attribution in ONE call.
  /// On first open: sends device signals + AdServices token to backend,
  /// resolves attribution, caches locally, returns result.
  /// On subsequent opens: reports changed consent, then returns cached attribution.
  static Future<Attribution?>? _configuring;
  static AppReferConfig? _requestedConfig;
  static bool _sameConfig(AppReferConfig a, AppReferConfig b) =>
      a.apiKey == b.apiKey &&
      a.userId == b.userId &&
      a.debug == b.debug &&
      a.logLevel == b.logLevel;
  static Future<Attribution?> configure(AppReferConfig config) async {
    // Lifecycle engagement started without its own key follows this one.
    unawaited(
      engagement.configurationChanged(config.apiKey).catchError((Object _) {}),
    );
    // Configuring for the next account restarts attribution after reset().
    AppReferRegistry.stoppedByReset = false;
    final accountEpoch = _accountGeneration;
    final epoch = _collectionGeneration;
    await _collectionWrites;
    final prefs = await SharedPreferences.getInstance();
    // reset() ran meanwhile: this configure belonged to the previous account.
    if (accountEpoch != _accountGeneration) return null;
    if (_collectionBlocked ||
        epoch != _collectionGeneration ||
        prefs.getBool('apprefer_collection_enabled') == false) {
      AppReferRegistry.apiKey = config.apiKey;
      // Stored even while collection is off, so Support uses this account, not the last one.
      final userId = config.userId;
      if (userId != null) {
        await _ignoreStorage(
          () => _accountWrite(() async {
            if (accountEpoch == _accountGeneration)
              await AppReferStorage.writeUserId(prefs, userId);
          }),
        );
      }
      return Attribution.fromJsonString(
        prefs.getString('apprefer_attribution_cache'),
      );
    }
    if (_needsCollectionConfigure) {
      if (_instance != null) WidgetsBinding.instance.removeObserver(_instance!);
      _instance = null;
      _configuring = null;
      _needsCollectionConfigure = false;
    }
    return _configureEnabled(config);
  }

  /// Persistently pause attribution and analytics. Support and Billing stay available.
  /// Enabling takes effect on the next configure.
  ///
  /// Calling it with `true` while collection is already on changes nothing. It
  /// never throws: if the choice can't be saved, collection still stops for
  /// this session.
  static Future<void> setCollectionEnabled(bool enabled) async {
    if (enabled && !_collectionBlocked && !_needsCollectionConfigure) {
      // Already on (unless an earlier launch saved "off"): a consent tool
      // reporting "granted" on every launch changes nothing.
      try {
        await _collectionWrites;
        final prefs = await SharedPreferences.getInstance();
        if (prefs.getBool('apprefer_collection_enabled') != false) return;
      } catch (_) {}
    }
    _collectionGeneration++;
    _collectionBlocked = !enabled;
    _needsCollectionConfigure = true;
    _configuring = null;
    final sdk = _instance;
    if (sdk != null) {
      sdk._storage.pauseCollection();
      sdk._generation++;
      sdk._consentRecheck = false;
      sdk._httpClient.cancel();
      sdk._conversion.cancel();
    }
    final write = _collectionWrites.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool('apprefer_collection_enabled', enabled))
        throw StateError('Cannot persist collection setting');
    });
    _collectionWrites = write.then<void>((_) {}, onError: (Object _) {});
    // Applied in memory above even when saving fails: err on not collecting.
    if (!enabled) await _ignoreStorage(clearPendingEvents);
    await _ignoreStorage(() => write);
    // Lifecycle engagement keeps sending its own state; the server stops SDK-event journeys.
    await _ignoreStorage(engagement.collectionChanged);
  }

  static Future<Attribution?> _configureEnabled(AppReferConfig config) {
    support.api.resumeRevocations();
    if (_requestedConfig != null &&
        _sameConfig(_requestedConfig!, config) &&
        _configuring != null)
      return _configuring!;
    if (_instance != null && _sameConfig(_instance!._config, config)) {
      final sdk = _instance!;
      // reset() cleared the stored user: store it again (under the account
      // epoch, and tell the server) so events and Support carry it.
      final userId = config.userId;
      final restore = userId != null && sdk._storage.getUserId() != userId
          ? setUserId(userId)
          : Future<void>.value();
      unawaited(sdk._events.flush());
      return restore
          .then((_) => trackingConsentDidChange())
          .then((_) => _getCachedAttribution());
    }
    _requestedConfig = config;
    final task = _configureNew(config);
    _configuring = task;
    unawaited(
      task.then<void>(
        (_) {
          if (identical(_configuring, task)) _configuring = null;
        },
        onError: (Object _) {
          if (identical(_configuring, task)) _configuring = null;
        },
      ),
    );
    return task;
  }

  static Future<Attribution?> _configureNew(AppReferConfig config) async {
    final accountEpoch = _accountGeneration;
    final collectionEpoch = _collectionGeneration;
    _instance?._httpClient.cancel();
    _instance?._conversion.cancel();
    final sdk = AppReferSDK._();
    sdk._config = config;
    AppReferRegistry.apiKey = config.apiKey;
    sdk._logger = AppReferLogger(
      debug: config.debug,
      logLevel: config.logLevel,
    );
    sdk._storage = AppReferStorage();
    await sdk._storage.init();
    if (collectionEpoch != _collectionGeneration || _collectionBlocked)
      return _getCachedAttribution();
    if (accountEpoch != _accountGeneration) return null;
    sdk._httpClient = AppReferHttpClient(
      baseUrl: AppReferConfig.trackingUrl,
      collectionAllowed: () =>
          collectionEpoch == _collectionGeneration &&
          !_collectionBlocked &&
          !AppReferRegistry.stoppedByReset &&
          sdk._storage.isSdkEnabled(),
      fallbackUrl: AppReferConfig.fallbackUrl,
      apiKey: config.apiKey,
      logger: sdk._logger,
    );
    if (_eventQueue == null) {
      _eventQueue = EventQueue(
        sdk._httpClient.eventResponse,
        sdk._storage.isSdkEnabled,
        held: () => AppReferRegistry.stoppedByReset,
        discard: sdk._storage.shouldDiscardEvents,
      );
    } else {
      _eventQueue!.replace(
        sdk._httpClient.eventResponse,
        sdk._storage.isSdkEnabled,
        discard: sdk._storage.shouldDiscardEvents,
      );
    }
    sdk._events = _eventQueue!;
    unawaited(sdk._events.flush());
    sdk._conversion = ConversionValue(
      storage: sdk._storage,
      client: AppReferHttpClient(
        baseUrl: 'https://apprefer.com',
        collectionAllowed: () =>
            collectionEpoch == _collectionGeneration &&
            !_collectionBlocked &&
            !AppReferRegistry.stoppedByReset &&
            sdk._storage.isSdkEnabled(),
        apiKey: config.apiKey,
        logger: sdk._logger,
      ),
      active: () => !AppReferRegistry.stoppedByReset,
    );
    sdk._deviceInfo = AppReferDeviceInfo(logger: sdk._logger);
    sdk._adServices = AppReferAdServices(logger: sdk._logger);
    sdk._installReferrer = AppReferInstallReferrer(logger: sdk._logger);

    if (_instance != null) WidgetsBinding.instance.removeObserver(_instance!);
    _instance = sdk;
    WidgetsBinding.instance.addObserver(sdk);

    sdk._logger.info('AppReferSDK initialized');

    // Set user ID if provided at init time
    if (config.userId != null) {
      await _accountWrite(() async {
        if (accountEpoch == _accountGeneration)
          await sdk._storage.setUserId(config.userId!);
      });
    }

    if (accountEpoch != _accountGeneration) return null;

    // Record first run date
    await sdk._storage.getFirstRunDate();

    if (sdk._storage.isMatchRequestAttempted()) {
      await trackingConsentDidChange();
    }

    // Check kill switch from local cache
    if (!sdk._storage.isSdkEnabled()) {
      sdk._logger.info('SDK disabled by kill switch');
      return _getCachedAttribution();
    }

    // If match already attempted, return cached attribution
    if (sdk._storage.isMatchRequestAttempted()) {
      sdk._logger.info('Skipping match request: existing install detected.');
      unawaited(sdk._conversion.refresh());
      return _getCachedAttribution();
    }

    if (accountEpoch != _accountGeneration) return null;

    // First run — resolve attribution
    try {
      return await sdk._resolveAttribution();
    } catch (e) {
      sdk._logger.error('Attribution resolution failed: $e');
      return null;
    } finally {
      unawaited(sdk._conversion.refresh());
    }
  }

  Future<Attribution?> _resolveAttribution() async {
    final epoch = _generation;
    final consent = await TrackingConsent.current();
    final deviceId = await _storage.getDeviceId();
    final deviceInfoMap = await _deviceInfo.getDeviceInfo();

    // Get AdServices token + IDFA (iOS only)
    String? asaToken;
    String? idfa;
    if (Platform.isIOS) {
      asaToken = await _adServices.getAdServicesToken();
      if (consent == 'granted') idfa = await _adServices.getIdfa();
    }

    // Get Install Referrer + GAID (Android only)
    Map<String, dynamic>? referrerData;
    String? arClickId;
    String? gaid;
    if (Platform.isAndroid) {
      referrerData = await _installReferrer.getInstallReferrer();
      if (referrerData != null) {
        arClickId = AppReferInstallReferrer.extractClickId(
          referrerData['installReferrer'] as String?,
        );
      }
      if (TrackingConsent.allowed(consent)) gaid = await _adServices.getGaid();
    }

    final body = <String, dynamic>{
      'device_id': deviceId,
      'device_info': deviceInfoMap,
      'asa_token': asaToken,
      if (idfa != null && consent == 'granted') 'idfa': idfa,
      if (gaid != null && TrackingConsent.allowed(consent)) 'gaid': gaid,
      if (consent != null) 'tracking_consent': consent,
      'install_referrer': referrerData?['installReferrer'],
      'ar_click_id': arClickId,
      'referrer_click_ts': referrerData?['referrerClickTimestampSeconds'],
      'referrer_install_ts': referrerData?['installBeginTimestampSeconds'],
      'sdk_version': appReferVersion,
      'is_debug': _config.debug,
      'customer_user_id': _storage.getUserId(),
    };

    _logger.info('Sending configure request...');
    if (epoch != _generation) {
      _failed = true;
      return null;
    }
    final response = await _httpClient.post(
      '/api/track/configure',
      body,
      consent: consent,
      consentSnapshot: true,
    );

    if (epoch != _generation) {
      _failed = true;
      return null;
    }
    _failed = response == null;
    if (response != null &&
        (response['organic'] == true ||
            (response.containsKey('attribution') &&
                response['attribution'] == null))) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('apprefer_organic_confirmed', true);
    }
    if (response == null) {
      _logger.error('Configure request failed — will retry on next launch');
      // Do NOT set matchRequestAttempted so next launch retries attribution
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

    if (consent != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(TrackingConsent.reportedKey, consent);
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

    await trackingConsentDidChange();
    return _getCachedAttribution() ?? attribution;
  }

  /// Track non-purchase events (signup, tutorial_complete, etc.)
  /// Purchases are tracked via RevenueCat webhooks, NOT here.
  static Future<void> trackEvent(
    String eventName, {
    Map<String, dynamic>? properties,
    double? revenue,
    String? currency,
  }) async {
    await trackEventResult(
      eventName,
      properties: properties,
      revenue: revenue,
      currency: currency,
    );
  }

  static Future<AppReferEventResult> trackEventResult(
    String eventName, {
    Map<String, dynamic>? properties,
    double? revenue,
    String? currency,
  }) async {
    try {
      final sdk = _instance;
      if (sdk == null) return AppReferEventResult.dropped;
      // After reset() nothing is queued until configure runs for the next account: those
      // events come before the new user consents, so they must never be sent later.
      if (AppReferRegistry.stoppedByReset) return AppReferEventResult.dropped;
      final epoch = sdk._generation;
      if (!sdk._storage.isSdkEnabled()) {
        if (sdk._storage.shouldDiscardEvents()) await sdk._events.clear();
        return AppReferEventResult.dropped;
      }

      final userId = sdk._storage.getUserId(); // snapshot before awaiting
      final deviceId = await sdk._storage.getDeviceId();
      final body = <String, dynamic>{
        'device_id': deviceId,
        'event_name': eventName,
        if (!eventName.startsWith('_') && userId != null) 'app_user_id': userId,
        if (properties != null) 'properties': properties,
        if (revenue != null) 'revenue': revenue,
        if (currency != null) 'currency': currency,
        // Only a stamp is queued; the credential is added at send time while current.
        if (engagement.eventStamp(eventName, sdk._config.apiKey)
            case final stamp?)
          engagementStampKey: stamp,
      };

      sdk._logger.info('Tracking event: $eventName');
      if (epoch != sdk._generation) return AppReferEventResult.dropped;
      final result = await sdk._events.enqueue(body);
      if ((revenue ?? 0) > 0 ||
          ConversionValue.trialEvents.contains(eventName)) {
        unawaited(sdk._conversion.refresh(force: true));
      }
      return result;
    } catch (_) {
      return AppReferEventResult.dropped;
    }
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
      assert(() {
        print(
          '[AppRefer] setAdvancedMatching called before configure() — ignoring',
        );
        return true;
      }());
      return;
    }
    final epoch = sdk._generation;
    if (!sdk._storage.isSdkEnabled() || AppReferRegistry.stoppedByReset) return;

    if (!TrackingConsent.allowed(await TrackingConsent.current())) return;
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
    if (epoch != sdk._generation) return;
    await sdk._httpClient.post('/api/track/event', body);
  }

  /// Set RevenueCat app_user_id so webhook events can be linked
  /// to this device's attribution.
  static Future<void> setUserId(String userId) async {
    final accountEpoch = _accountGeneration;
    final sdk = _instance;
    if (sdk == null) {
      assert(() {
        print('[AppRefer] Support identity stored');
        return true;
      }());
      final storage = AppReferStorage();
      await storage.init();
      await _accountWrite(() async {
        if (accountEpoch == _accountGeneration) await storage.setUserId(userId);
      });
      return;
    }
    await _accountWrite(() async {
      if (accountEpoch == _accountGeneration)
        await sdk._storage.setUserId(userId);
    });
    if (accountEpoch != _accountGeneration) return;
    sdk._logger.info('User ID set: $userId');

    // Sync userId to server so webhook userId fallback can find this attribution
    if (!sdk._storage.isSdkEnabled() || AppReferRegistry.stoppedByReset) return;
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

  /// Android app permission; iOS always reads ATT without prompting.
  static Future<void> setTrackingConsent(bool? granted) async {
    await TrackingConsent.set(granted);
    await trackingConsentDidChange();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) support.api.resumeRevocations();
    if (state == AppLifecycleState.resumed) {
      unawaited(engagement.becameActive().catchError((Object _) {}));
      unawaited(_conversion.refresh());
      unawaited(_events.flush());
      unawaited(
        trackingConsentDidChange().catchError((Object e) {
          _logger.error('Consent sync failed: $e');
        }),
      );
    }
  }

  /// Call after the app's own ATT prompt. Failed reports retry on the next trigger.
  static Future<void> trackingConsentDidChange() async {
    final sdk = _instance;
    if (sdk == null ||
        AppReferRegistry.stoppedByReset ||
        !sdk._storage.isSdkEnabled() ||
        !sdk._storage.isMatchRequestAttempted())
      return;
    if (sdk._consentSync != null) {
      sdk._consentRecheck = true;
      await sdk._consentSync;
      return;
    }
    sdk._consentSync = () async {
      try {
        do {
          sdk._consentRecheck = false;
          try {
            await sdk._reportConsent();
          } catch (e) {
            sdk._logger.error('Consent sync failed: $e');
          }
        } while (sdk._consentRecheck);
      } finally {
        sdk._consentSync = null;
      }
    }();
    await sdk._consentSync;
  }

  Future<void> _reportConsent() async {
    final epoch = _generation;
    if (AppReferRegistry.stoppedByReset ||
        !_storage.isSdkEnabled() ||
        !_storage.isMatchRequestAttempted())
      return;
    final consent = await TrackingConsent.current();
    final prefs = await SharedPreferences.getInstance();
    final cached = _getCachedAttribution();
    if ((consent == null ||
            consent == prefs.getString(TrackingConsent.reportedKey)) &&
        !(cached?.trackingDecisionPending == true &&
            cached?.matchType != 'adservices'))
      return;
    final body = <String, dynamic>{
      'device_id': await _storage.getDeviceId(),
      'tracking_consent': consent,
      'device_info': await _deviceInfo.getDeviceInfo(),
      'sdk_version': appReferVersion,
      if (_storage.getUserId() != null)
        'customer_user_id': _storage.getUserId(),
    };
    if (Platform.isIOS && consent == 'granted') {
      final idfa = await _adServices.getIdfa();
      if (idfa != null) body['idfa'] = idfa;
    }
    if (Platform.isAndroid && TrackingConsent.allowed(consent)) {
      final gaid = await _adServices.getGaid();
      if (gaid != null) body['gaid'] = gaid;
    }
    if (prefs.getString(TrackingConsent.reportedKey) == null) {
      if (Platform.isIOS) {
        final token = await _adServices.getAdServicesToken();
        if (token != null) body['asa_token'] = token;
      }
      if (Platform.isAndroid) {
        final referrer = await _installReferrer.getInstallReferrer();
        body['install_referrer'] = referrer?['installReferrer'];
        body['ar_click_id'] = AppReferInstallReferrer.extractClickId(
          referrer?['installReferrer'] as String?,
        );
        body['referrer_click_ts'] = referrer?['referrerClickTimestampSeconds'];
        body['referrer_install_ts'] = referrer?['installBeginTimestampSeconds'];
      }
    }
    if (epoch != _generation) {
      _failed = true;
      return;
    }
    final response = await _httpClient.post(
      '/api/track/configure',
      body,
      consent: consent,
      consentSnapshot: true,
    );
    if (epoch != _generation) {
      _failed = true;
      return;
    }
    _failed = response == null;
    if (response == null) return;
    if (response['organic'] == true ||
        (response.containsKey('attribution') &&
            response['attribution'] == null)) {
      await prefs.setBool('apprefer_organic_confirmed', true);
    }
    if (response['sdkEnabled'] == false) {
      await _storage.setSdkEnabled(false);
      return;
    }
    final raw = response['attribution'] as Map<String, dynamic>?;
    if (raw != null) {
      await _storage.setAttributionCache(
        Attribution.fromJson(raw).toJsonString(),
      );
    } else {
      await _storage.clearAttributionCache();
    }
    if (consent != null)
      await prefs.setString(TrackingConsent.reportedKey, consent);
  }

  /// Get cached attribution result (instant, no network call).
  static Future<Attribution?> getAttribution() async {
    if (_instance == null && AppReferRegistry.apiKey != null) {
      // Configured while collection is off: the stored result, like iOS/Android.
      final prefs = await SharedPreferences.getInstance();
      return Attribution.fromJsonString(
        prefs.getString('apprefer_attribution_cache'),
      );
    }
    return _getCachedAttribution();
  }

  /// Get the AppRefer device ID (for setting as RC subscriber attribute).
  static Future<String?> getDeviceId() async {
    final sdk = _instance;
    if (sdk == null) {
      if (AppReferRegistry.apiKey == null) return null;
      // Configured while collection is off: the stored id, like iOS/Android.
      final storage = AppReferStorage();
      await storage.init();
      return storage.existingDeviceId();
    }
    return sdk._storage.getDeviceId();
  }

  static Attribution? _getCachedAttribution() {
    final sdk = _instance;
    if (sdk == null) return null;
    final cached = sdk._storage.getAttributionCache();
    return Attribution.fromJsonString(cached);
  }
}
