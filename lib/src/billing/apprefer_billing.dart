import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:in_app_purchase_storekit/in_app_purchase_storekit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../apprefer_sdk.dart';
import '../services/logger.dart';
import '../services/registry.dart';
import '../services/storage.dart';
import 'billing_api_client.dart';
import 'offerings.dart';
import 'billing_engine.dart';
import 'billing_error.dart';
import 'billing_storage.dart';
import 'billing_store.dart';
import 'customer_info.dart';
import 'in_app_purchase_store.dart';
import 'pending_purchase_queue.dart';
import 'rejected_purchases.dart';

/// AppRefer Billing: App Store (StoreKit 2) and Google Play purchases and
/// entitlements, verified and recorded by AppRefer. A drop-in replacement for
/// RevenueCat's `Purchases`.
///
/// ```dart
/// AppReferSDK.configure(AppReferConfig(apiKey: 'pk_live_...'));
/// await AppReferBilling.configure(entitlementsByProduct: {'pro_yearly': ['premium']});
///
/// final products = await AppReferBilling.products(['pro_yearly']);
/// final result = await AppReferBilling.purchase(products.first);
/// if (result.customerInfo.entitlements['premium']?.isActive == true) unlock();
/// ```
class AppReferBilling {
  AppReferBilling._();

  static BillingEngine? _engine;
  static Future<void>? _configuring;
  static AppReferLogger _logger = const AppReferLogger();
  static _LifecycleObserver? _lifecycle;
  static final _broadcaster = _CustomerInfoBroadcaster();
  static final _listeners = <void Function(AppReferCustomerInfo)>[];

  /// Whether `configure` has finished.
  static bool get isConfigured => _engine != null;

  // --- Configure ---

  /// Starts AppRefer Billing. Call once at launch, after `AppReferSDK.configure`.
  /// Starts the store purchase listener right away.
  ///
  /// - [apiKey]: SDK key. Defaults to the key passed to `AppReferSDK.configure`.
  /// - [appUserId]: your user id. Null uses an anonymous `$ARAnon:<UUID>`.
  /// - [entitlementsByProduct]: productId → entitlement ids, used when AppRefer
  ///   is unreachable. Mirror the app's AppRefer billing config. Products not
  ///   listed fall back to what the server last said, then [defaultEntitlement].
  /// - [defaultEntitlement]: entitlement for unmapped products (server default `premium`).
  /// - [consumableProductIds]: Google Play one-time products that are consumed
  ///   after AppRefer records them. iOS reads the product type from StoreKit.
  static Future<void> configure({
    String? apiKey,
    String? appUserId,
    Map<String, List<String>> entitlementsByProduct = const {},
    String? defaultEntitlement,
    Set<String> consumableProductIds = const {},
    bool debug = false,
    int logLevel = 1,
  }) {
    return _configure(
      apiKey: apiKey,
      appUserId: appUserId,
      entitlementsByProduct: entitlementsByProduct,
      defaultEntitlement: defaultEntitlement,
      consumableProductIds: consumableProductIds,
      debug: debug,
      logLevel: logLevel,
    );
  }

  /// [configure] with an injected store and HTTP client.
  @visibleForTesting
  static Future<void> configureForTesting({
    required BillingStoreAdapter store,
    required http.Client httpClient,
    String apiKey = 'pk_test_123',
    String? appUserId,
    Map<String, List<String>> entitlementsByProduct = const {},
    String? defaultEntitlement,
    DateTime Function()? now,
  }) {
    return _configure(
      apiKey: apiKey,
      appUserId: appUserId,
      entitlementsByProduct: entitlementsByProduct,
      defaultEntitlement: defaultEntitlement,
      consumableProductIds: const {},
      debug: false,
      logLevel: 0,
      store: store,
      httpClient: httpClient,
      now: now,
      observeLifecycle: false,
    );
  }

  /// Forgets the configured engine.
  @visibleForTesting
  static Future<void> resetForTesting() async {
    await _engine?.dispose();
    _engine = null;
    _configuring = null;
    _broadcaster.reset();
    _listeners.clear();
    if (_lifecycle != null) {
      WidgetsBinding.instance.removeObserver(_lifecycle!);
      _lifecycle = null;
    }
  }

  static Future<void> _configure({
    required String? apiKey,
    required String? appUserId,
    required Map<String, List<String>> entitlementsByProduct,
    required String? defaultEntitlement,
    required Set<String> consumableProductIds,
    required bool debug,
    required int logLevel,
    BillingStoreAdapter? store,
    http.Client? httpClient,
    DateTime Function()? now,
    bool observeLifecycle = true,
  }) {
    final logger = AppReferLogger(debug: debug, logLevel: logLevel);
    if (_configuring != null) {
      logger.warn('AppReferBilling.configure called more than once; ignoring');
      return _configuring!;
    }
    _logger = logger;
    final done = () async {
      final prefs = await SharedPreferences.getInstance();
      final storage = BillingStorage(prefs);
      final engine = BillingEngine(
        api: BillingApiClient(
          baseUrls: const [
            AppReferConfig.trackingUrl,
            AppReferConfig.fallbackUrl,
          ],
          apiKey: () => apiKey ?? AppReferRegistry.apiKey,
          client: httpClient,
        ),
        storage: storage,
        queue: PendingPurchaseQueue(prefs, BillingStorage.pendingPurchasesKey),
        store:
            store ??
            InAppPurchaseBillingStore(
              storage: storage,
              consumableProductIds: consumableProductIds,
              logger: logger,
            ),
        options: BillingEngineOptions(
          productEntitlements: entitlementsByProduct,
          defaultEntitlement: defaultEntitlement,
        ),
        appUserId: appUserId,
        appreferId: _appreferDeviceId,
        logger: logger,
        now: now,
        onChange: _publish,
      );
      engine.listen();
      _engine = engine;
      if (observeLifecycle) _observeLifecycle(engine);
      Timer.run(() {
        unawaited(
          engine.start().catchError((Object e) {
            logger.error('AppReferBilling start failed: $e');
          }),
        );
      });
    }();
    _configuring = done.catchError((Object e) {
      logger.error('AppReferBilling.configure failed: $e');
      _configuring = null;
    });
    return _configuring!;
  }

  /// The attribution device id, sent as `appreferId` so purchases are matched
  /// to the ad click without `setUserId`. Only read: attribution owns minting
  /// it, so billing can never race it into a second id.
  static Future<String?> _appreferDeviceId() async {
    final storage = AppReferStorage();
    await storage.init();
    return storage.existingDeviceId();
  }

  static void _observeLifecycle(BillingEngine engine) {
    try {
      final observer = _LifecycleObserver(engine);
      WidgetsFlutterBinding.ensureInitialized().addObserver(observer);
      _lifecycle = observer;
    } catch (e) {
      _logger.warn('AppReferBilling: no lifecycle observer ($e)');
    }
  }

  static void _publish(AppReferCustomerInfo info) {
    _broadcaster.publish(info);
    for (final listener in List.of(_listeners)) {
      try {
        listener(info);
      } catch (e) {
        _logger.error('AppReferBilling listener threw: $e');
      }
    }
  }

  static Future<BillingEngine> _requireEngine() async {
    final pending = _configuring;
    if (pending != null) await pending;
    final engine = _engine;
    if (engine == null) {
      throw const AppReferBillingException(
        AppReferBillingErrorCode.notConfigured,
      );
    }
    return engine;
  }

  // --- Identity ---

  /// The current app user id (`$ARAnon:<UUID>` while anonymous); empty before configure.
  static Future<String> get appUserId async {
    try {
      return (await _requireEngine()).currentAppUserId;
    } catch (_) {
      return '';
    }
  }

  static Future<bool> get isAnonymous async {
    try {
      return (await _requireEngine()).isAnonymous;
    } catch (_) {
      return true;
    }
  }

  /// Switches to a signed-in user. Purchases made while anonymous move to them.
  static Future<AppReferCustomerInfo> logIn(String appUserId) async =>
      (await _requireEngine()).logIn(appUserId);

  /// Signs out and starts a fresh anonymous id. A login still waiting to
  /// reach AppRefer is kept and sent later.
  static Future<AppReferCustomerInfo> logOut() async =>
      (await _requireEngine()).logOut();

  /// Customer attributes, sent with the next AppRefer call. Supported keys:
  /// `$email`, `$displayName`, `$phoneNumber`, `$idfa`, `$idfv`, `$fbAnonId`,
  /// `$attConsentStatus`, `$deviceVersion`, `$ip`, `$gpsAdId`.
  static Future<void> setAttributes(Map<String, String> attributes) async {
    try {
      (await _requireEngine()).setAttributes(attributes);
    } catch (_) {}
  }

  static Future<void> setEmail(String email) =>
      setAttributes({r'$email': email});
  static Future<void> setDisplayName(String name) =>
      setAttributes({r'$displayName': name});
  static Future<void> setPhoneNumber(String phone) =>
      setAttributes({r'$phoneNumber': phone});

  // --- Entitlements ---

  /// The customer's entitlements. Never throws: if AppRefer can't be reached,
  /// the answer comes from the store's verified active purchases merged with the cache.
  static Future<AppReferCustomerInfo> customerInfo({
    FetchPolicy fetchPolicy = FetchPolicy.cachedOrFetched,
  }) async {
    final BillingEngine engine;
    try {
      engine = await _requireEngine();
    } catch (_) {
      return _unconfiguredFallback();
    }
    return engine.customerInfo(fetchPolicy);
  }

  /// The store read by [customerInfo] before `configure`.
  @visibleForTesting
  static BillingStoreAdapter Function() unconfiguredStore = () =>
      InAppPurchaseBillingStore(logger: _logger);

  /// Not configured: still never lock a payer out.
  static Future<AppReferCustomerInfo> _unconfiguredFallback() async {
    List<StoreEntitlement> purchases = const [];
    try {
      purchases = await unconfiguredStore().activeEntitlements();
    } catch (_) {}
    final now = DateTime.now();
    final local = LocalEntitlements.compute(
      purchases,
      configured: const {},
      learned: const {},
      now: now,
    );
    return LocalEntitlements.merge(
      server: null,
      local: local,
      appUserId: '',
      now: now,
      source: CustomerInfoSource.localFallback,
    );
  }

  /// Every entitlement change, starting with the latest known value.
  static Stream<AppReferCustomerInfo> get customerInfoStream =>
      _broadcaster.stream();

  /// Called on every entitlement change (RevenueCat-style listener).
  static void addCustomerInfoUpdateListener(
    void Function(AppReferCustomerInfo) listener,
  ) {
    _listeners.add(listener);
  }

  static void removeCustomerInfoUpdateListener(
    void Function(AppReferCustomerInfo) listener,
  ) {
    _listeners.remove(listener);
  }

  static Future<AppReferOfferings> offerings({
    FetchPolicy fetchPolicy = FetchPolicy.cachedOrFetched,
  }) async => (await _requireEngine()).offerings(fetchPolicy);
  static Future<PurchaseResult> purchasePackage(AppReferPackage package) async {
    final result = await (await _requireEngine()).purchasePackage(package);
    if (result.outcome == PurchaseOutcome.purchased)
      unawaited(AppReferSDK.updateConversionValue());
    return result;
  }
  // --- Products and purchases ---

  /// Store products in the order requested. On Google Play a subscription
  /// returns one entry per base plan / offer.
  static Future<List<ProductDetails>> products(List<String> productIds) async {
    final engine = await _requireEngine();
    return engine.products(productIds);
  }

  /// Buys a product. Tags the purchase with the customer's AppRefer account
  /// token (Apple `appAccountToken`, Google `obfuscatedAccountId`), records it
  /// with AppRefer and only then completes it with the store.
  ///
  /// - [promotionalOffer], [winBackOfferId]: App Store offers (StoreKit 2).
  /// - [changeSubscriptionParam]: Google Play upgrade / downgrade.
  static Future<PurchaseResult> purchase(
    ProductDetails product, {
    SK2PromotionalOffer? promotionalOffer,
    String? winBackOfferId,
    ChangeSubscriptionParam? changeSubscriptionParam,
  }) async {
    final engine = await _requireEngine();
    final result = await engine.purchase(
      product,
      StorePurchaseOptions(
        promotionalOffer: promotionalOffer,
        winBackOfferId: winBackOfferId,
        changeSubscriptionParam: changeSubscriptionParam,
      ),
    );
    if (result.outcome == PurchaseOutcome.purchased) {
      unawaited(AppReferSDK.updateConversionValue());
    }
    return result;
  }

  /// `AppStore.sync()` (iOS), then sends every purchase the store owns to AppRefer.
  /// Throws if the user cancels the App Store sign-in.
  static Future<AppReferCustomerInfo> restorePurchases() async =>
      (await _requireEngine()).restore();

  /// Store purchases AppRefer refused for good, that had no verifiable store
  /// data, or that could not be delivered after many retries. Each is kept on
  /// the device (with its signed store data) before it is completed with the
  /// store, for support; [restorePurchases] sends them again.
  static Future<List<RejectedPurchase>> rejectedPurchases() async =>
      (await _requireEngine()).rejectedPurchases();
}

class _LifecycleObserver with WidgetsBindingObserver {
  final BillingEngine engine;
  _LifecycleObserver(this.engine);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(engine.resume());
  }
}

/// Fans entitlement changes out to any number of stream subscribers, replaying
/// the latest value to each new one.
class _CustomerInfoBroadcaster {
  AppReferCustomerInfo? _latest;
  final _controller = StreamController<AppReferCustomerInfo>.broadcast();

  void publish(AppReferCustomerInfo info) {
    _latest = info;
    _controller.add(info);
  }

  void reset() => _latest = null;

  Stream<AppReferCustomerInfo> stream() =>
      Stream<AppReferCustomerInfo>.multi((controller) {
        final latest = _latest;
        if (latest != null) controller.add(latest);
        final sub = _controller.stream.listen(controller.add);
        controller.onCancel = sub.cancel;
      });
}
