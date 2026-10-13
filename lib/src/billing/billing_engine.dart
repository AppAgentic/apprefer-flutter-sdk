import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';

import '../services/logger.dart';
import 'billing_api_client.dart';
import 'billing_error.dart';
import 'billing_storage.dart';
import 'billing_store.dart';
import 'customer_info.dart';
import 'pending_purchase_queue.dart';

enum FetchPolicy {
  /// The cached answer if it is under 5 minutes old, otherwise the server.
  cachedOrFetched,

  /// Always ask the server.
  fetchCurrent,
}

enum PurchaseOutcome {
  purchased,
  userCancelled,

  /// Waiting on Ask to Buy, SCA or a slow payment method; it arrives later
  /// through the purchase listener and `customerInfoStream`.
  pending,
}

class PurchaseResult {
  final PurchaseOutcome outcome;

  /// The plugin's purchase, when `outcome == PurchaseOutcome.purchased`.
  final PurchaseDetails? purchaseDetails;
  final AppReferCustomerInfo customerInfo;

  const PurchaseResult(this.outcome, this.purchaseDetails, this.customerInfo);

  /// RevenueCat-style flag.
  bool get userCancelled => outcome == PurchaseOutcome.userCancelled;
}

class BillingEngineOptions {
  final Map<String, List<String>> productEntitlements;
  final String? defaultEntitlement;

  /// How long a server answer counts as fresh for [FetchPolicy.cachedOrFetched].
  final Duration cacheTtl;

  const BillingEngineOptions({
    this.productEntitlements = const {},
    this.defaultEntitlement,
    this.cacheTtl = const Duration(minutes: 5),
  });
}

/// Core of AppReferBilling: identity, server sync, purchase processing, retry
/// queue and the outage fallback. Everything goes through [BillingStoreAdapter]
/// and [BillingApiClient] so it can be tested without the store.
class BillingEngine {
  final BillingApiClient _api;
  final BillingStorage _storage;
  final PendingPurchaseQueue _queue;
  final BillingStoreAdapter _store;
  final BillingEngineOptions _options;
  final Future<String?> Function() _appreferId;
  final AppReferLogger _logger;
  final void Function(AppReferCustomerInfo) _onChange;
  final DateTime Function() _now;

  AppReferCustomerInfo? _lastPublished;
  ({String appUserId, DateTime at})? _lastServerFetch;

  /// Users whose appreferId/attributes were registered (POST customers) this launch.
  final _registeredUsers = <String>{};
  StreamSubscription<List<StorePurchase>>? _updates;
  bool _isDraining = false;

  /// Purchases being sent right now, so a purchase delivered twice (stream and
  /// unfinished list) is only sent once.
  final _inFlight = <String, Future<AppReferCustomerInfo>>{};

  /// `purchase()` calls waiting for their result on the update stream.
  final _waiters = <String, Completer<PurchaseResult>>{};

  BillingEngine({
    required BillingApiClient api,
    required BillingStorage storage,
    required PendingPurchaseQueue queue,
    required BillingStoreAdapter store,
    BillingEngineOptions options = const BillingEngineOptions(),
    String? appUserId,
    required Future<String?> Function() appreferId,
    AppReferLogger logger = const AppReferLogger(),
    DateTime Function()? now,
    void Function(AppReferCustomerInfo)? onChange,
  }) : _api = api,
       _storage = storage,
       _queue = queue,
       _store = store,
       _options = options,
       _appreferId = appreferId,
       _logger = logger,
       _now = now ?? DateTime.now,
       _onChange = onChange ?? ((_) {}) {
    // configure(appUserId:) behaves like logIn: purchases made while anonymous
    // on this device move to the user (sent to /identify when reachable).
    if (appUserId != null &&
        appUserId.isNotEmpty &&
        appUserId != storage.loggedInAppUserId) {
      if (storage.loggedInAppUserId == null &&
          storage.hasAnonymousId &&
          !BillingStorage.isAnonymous(appUserId)) {
        storage.pendingIdentify = (
          anonymousId: storage.anonymousId(),
          appUserId: appUserId,
        );
      }
      storage.loggedInAppUserId = BillingStorage.isAnonymous(appUserId)
          ? null
          : appUserId;
    }
  }

  // --- Lifecycle ---

  /// Starts listening to store updates. Call as early as possible so renewals
  /// and Ask to Buy approvals delivered at launch are not missed.
  void listen() {
    _updates ??= _store.purchaseUpdates.listen((list) {
      for (final purchase in list) {
        unawaited(_handleUpdate(purchase));
      }
    }, onError: (Object e) => _logger.error('Billing: store update error: $e'));
  }

  /// Completes anything the store still has unfinished, flushes the retry
  /// queue and refreshes entitlements.
  Future<void> start() async {
    listen();
    try {
      for (final purchase in await _store.unfinished()) {
        await process(purchase);
      }
    } catch (e) {
      _logger.warn('Billing: could not read unfinished purchases: $e');
    }
    await customerInfo(FetchPolicy.fetchCurrent);
  }

  Future<void> dispose() async {
    await _updates?.cancel();
    _updates = null;
  }

  String get currentAppUserId => _storage.currentAppUserId;
  bool get isAnonymous => _storage.loggedInAppUserId == null;

  // --- CustomerInfo ---

  Future<AppReferCustomerInfo> customerInfo(FetchPolicy policy) async {
    final user = currentAppUserId;
    final fetched = _lastServerFetch;
    if (policy == FetchPolicy.cachedOrFetched &&
        fetched != null &&
        fetched.appUserId == user &&
        _now().difference(fetched.at) < _options.cacheTtl) {
      final cached = _storage.cachedCustomerInfo();
      if (cached != null && cached.appUserId == user) {
        return _publish(await _withPendingLocal(cached.reevaluated(_now())));
      }
    }
    try {
      return await _fetchFromServer();
    } catch (e) {
      _logger.warn(
        'Billing: customer refresh failed ($e); using store fallback',
      );
      return localFallback();
    }
  }

  Future<AppReferCustomerInfo> _fetchFromServer() async {
    await _flushPendingIdentify();
    final user = currentAppUserId;
    final attributes = _storage.pendingAttributes;
    final needsRegister =
        !_registeredUsers.contains(user) ||
        attributes.isNotEmpty ||
        _storage.accountToken(user) == null;
    final response = await _api.send(
      needsRegister
          ? CreateCustomer(user, await _safeAppreferId(), attributes)
          : GetCustomer(user),
    );
    if (needsRegister) {
      _registeredUsers.add(user);
      _storage.clearSentAttributes(attributes);
    }
    final info = await _accept(response, user);
    await drainQueue();
    return info;
  }

  /// Stores a server answer and returns what callers should see.
  Future<AppReferCustomerInfo> _accept(
    BillingCustomerResponse response,
    String user,
  ) async {
    final token = response.accountToken;
    if (token != null) _storage.setAccountToken(token, response.info.appUserId);
    _storage.learnEntitlements(response.info);
    if (response.info.appUserId != user || user != currentAppUserId) {
      // Answer for a user who is no longer current (logIn/logOut raced it).
      return response.info;
    }
    _storage.setCachedCustomerInfo(response.info);
    _lastServerFetch = (appUserId: user, at: _now());
    return _publish(await _withPendingLocal(response.info));
  }

  /// While a purchase for this user is still queued, the server can't know it
  /// yet, so the store's own entitlements are merged in.
  Future<AppReferCustomerInfo> _withPendingLocal(
    AppReferCustomerInfo info,
  ) async {
    if (!_queue.containsUser(info.appUserId)) return info;
    return _mergeLocal(
      info,
      await _activeEntitlements(),
      info.appUserId,
      info.source,
    );
  }

  /// Outage path: store-verified active purchases merged with the cached server
  /// answer for the same user. A paying user is never locked out because
  /// AppRefer is down.
  Future<AppReferCustomerInfo> localFallback() async {
    final user = currentAppUserId;
    final purchases = await _activeEntitlements();
    final cached = _storage.cachedCustomerInfo();
    final sameUser = cached != null && cached.appUserId == user
        ? cached.reevaluated(_now())
        : null;
    return _publish(
      _mergeLocal(sameUser, purchases, user, CustomerInfoSource.localFallback),
    );
  }

  Future<List<StoreEntitlement>> _activeEntitlements() async {
    try {
      return await _store.activeEntitlements();
    } catch (e) {
      _logger.warn('Billing: could not read store entitlements: $e');
      return const [];
    }
  }

  AppReferCustomerInfo _mergeLocal(
    AppReferCustomerInfo? server,
    List<StoreEntitlement> purchases,
    String user,
    CustomerInfoSource source,
  ) {
    final local = LocalEntitlements.compute(
      purchases,
      configured: _options.productEntitlements,
      learned: _storage.learnedEntitlements,
      defaultEntitlement: _options.defaultEntitlement,
      now: _now(),
    );
    return LocalEntitlements.merge(
      server: server,
      local: local,
      appUserId: user,
      now: _now(),
      source: source,
    );
  }

  AppReferCustomerInfo _publish(AppReferCustomerInfo info) {
    final last = _lastPublished;
    _lastPublished = info;
    if (last == null || !last.hasSameContent(info)) {
      try {
        _onChange(info);
      } catch (e) {
        _logger.error('Billing: customer info listener threw: $e');
      }
    }
    return info;
  }

  // --- Store updates ---

  Future<void> _handleUpdate(StorePurchase purchase) async {
    switch (purchase.status) {
      case StorePurchaseStatus.pending:
        _resolve(purchase.productId, PurchaseOutcome.pending, null);
      case StorePurchaseStatus.canceled:
        if (purchase.needsCompletion) await _complete(purchase);
        _resolve(purchase.productId, PurchaseOutcome.userCancelled, null);
      case StorePurchaseStatus.error:
        if (purchase.needsCompletion) await _complete(purchase);
        _waiters
            .remove(purchase.productId)
            ?.completeError(
              AppReferBillingException(
                AppReferBillingErrorCode.store,
                message: purchase.errorMessage,
              ),
            );
      case StorePurchaseStatus.purchased:
      case StorePurchaseStatus.restored:
        final info = await process(purchase);
        _waiters
            .remove(purchase.productId)
            ?.complete(
              PurchaseResult(PurchaseOutcome.purchased, purchase.details, info),
            );
    }
  }

  void _resolve(
    String productId,
    PurchaseOutcome outcome,
    PurchaseDetails? details,
  ) {
    final waiter = _waiters.remove(productId);
    if (waiter == null) return;
    unawaited(
      customerInfo(
        FetchPolicy.cachedOrFetched,
      ).then((info) => waiter.complete(PurchaseResult(outcome, details, info))),
    );
  }

  /// Sends a store purchase to AppRefer, then completes it with the store. If
  /// AppRefer can't take it now, it is queued on disk first and still
  /// completed, so the store never keeps redelivering it (and Google never
  /// refunds it); access comes from the store meanwhile.
  Future<AppReferCustomerInfo> process(StorePurchase purchase) {
    final key = '${purchase.store.value}:${purchase.id}';
    final running = _inFlight[key];
    if (running != null) return running;
    // A block body: `=> _inFlight.remove(key)` would return this very future
    // to whenComplete, which would then wait on itself.
    final future = _process(purchase).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<AppReferCustomerInfo> _process(StorePurchase purchase) async {
    final fields = purchase.storeFields;
    if (fields == null || purchase.id.isEmpty) {
      _logger.error(
        'Billing: purchase of ${purchase.productId} has no verifiable store data; completed without granting access',
      );
      await _complete(purchase);
      return localFallback();
    }

    final user = currentAppUserId;
    final attributes = _storage.pendingAttributes;
    final deviceId = await _safeAppreferId();
    try {
      final response = await _api.send(
        RecordPurchase(user, deviceId, fields, attributes),
      );
      _storage.clearSentAttributes(attributes);
      await _complete(purchase);
      final info = await _accept(response, user);
      await drainQueue();
      return info;
    } on AppReferBillingException catch (e) {
      if (e.isRetryable) {
        _logger.warn('Billing: queued purchase ${purchase.id} for retry ($e)');
        await _queue.add(
          PendingPurchase(
            transactionId: purchase.id,
            productId: purchase.productId,
            appUserId: user,
            appreferId: deviceId,
            storeFields: fields,
            enqueuedAt: _now(),
          ),
        );
      } else {
        // Rejected as malformed: retrying won't help. Store notifications still
        // reach the server; the store fallback still unlocks a verified purchase.
        _logger.error('Billing: AppRefer rejected purchase ${purchase.id}: $e');
      }
    }
    await _complete(purchase);
    return localFallback();
  }

  Future<void> _complete(StorePurchase purchase) async {
    if (!purchase.needsCompletion) return;
    try {
      await purchase.complete();
    } catch (e) {
      _logger.error('Billing: completing ${purchase.productId} failed: $e');
    }
  }

  Future<List<ProductDetails>> products(List<String> productIds) async {
    try {
      return await _store.products(productIds);
    } on AppReferBillingException {
      rethrow;
    } catch (e) {
      throw AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: e.toString(),
      );
    }
  }

  /// Opens the store's purchase sheet tagged with the customer's account token
  /// and waits for the result, which arrives on the store update stream.
  Future<PurchaseResult> purchase(
    ProductDetails product,
    StorePurchaseOptions options,
  ) async {
    if (_waiters.containsKey(product.id)) {
      throw const AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: 'A purchase of this product is already in progress',
      );
    }
    listen();
    final waiter = Completer<PurchaseResult>();
    _waiters[product.id] = waiter;
    try {
      await _store.buy(
        product,
        StorePurchaseOptions(
          accountToken: await accountToken(),
          promotionalOffer: options.promotionalOffer,
          winBackOfferId: options.winBackOfferId,
          changeSubscriptionParam: options.changeSubscriptionParam,
        ),
      );
    } catch (e) {
      if (identical(_waiters[product.id], waiter)) _waiters.remove(product.id);
      if (e is AppReferBillingException) rethrow;
      throw AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: e.toString(),
      );
    }
    return waiter.future;
  }

  /// Apple `AppStore.sync()`, then sends every purchase the store owns to AppRefer.
  Future<AppReferCustomerInfo> restore() async {
    try {
      await _store.sync();
      final purchases = await _store.restore();
      if (purchases.isEmpty) return customerInfo(FetchPolicy.fetchCurrent);

      await _flushPendingIdentify();
      final user = currentAppUserId;
      final deviceId = await _safeAppreferId();
      BillingCustomerResponse? last;
      var failed = false;
      var unreachable = false;
      for (final purchase in purchases) {
        final fields = purchase.storeFields;
        if (fields == null) continue;
        if (unreachable) {
          await _queuePurchase(purchase, fields, user, deviceId);
          await _complete(purchase);
          continue;
        }
        try {
          last = await _api.send(
            RecordPurchase(user, deviceId, fields, const {}),
          );
        } on AppReferBillingException catch (e) {
          failed = true;
          if (e.isRetryable) {
            await _queuePurchase(purchase, fields, user, deviceId);
            if (e.isConnectivity) unreachable = true;
          }
        }
        await _complete(purchase);
      }
      if (last != null && !failed) return _accept(last, user);
      if (last != null) await _accept(last, user);
      return localFallback();
    } on AppReferBillingException {
      rethrow;
    } catch (e) {
      throw AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: e.toString(),
      );
    }
  }

  Future<void> _queuePurchase(
    StorePurchase purchase,
    Map<String, String> fields,
    String user,
    String? deviceId,
  ) => _queue.add(
    PendingPurchase(
      transactionId: purchase.id,
      productId: purchase.productId,
      appUserId: user,
      appreferId: deviceId,
      storeFields: fields,
      enqueuedAt: _now(),
    ),
  );

  /// Re-sends queued purchases. Stops at the first connectivity failure.
  Future<void> drainQueue() async {
    if (_isDraining || _queue.isEmpty) return;
    _isDraining = true;
    try {
      for (final dropped in _queue.prune(_now())) {
        _logger.error(
          'Billing: gave up resending purchase ${dropped.transactionId} after ${dropped.attempts} attempts',
        );
      }
      for (final entry in _queue.entries) {
        try {
          final response = await _api.send(
            RecordPurchase(
              entry.appUserId,
              entry.appreferId,
              entry.storeFields,
              const {},
            ),
          );
          _queue.remove(entry.transactionId);
          if (entry.appUserId == currentAppUserId) {
            await _accept(response, entry.appUserId);
          }
        } on AppReferBillingException catch (e) {
          if (!e.isRetryable) {
            _queue.remove(entry.transactionId);
            continue;
          }
          _queue.recordAttempt(entry.transactionId);
          if (e.isConnectivity) return;
        }
      }
    } finally {
      _isDraining = false;
    }
  }

  // --- Purchases ---

  /// The account token (Apple `appAccountToken` / Google `obfuscatedAccountId`)
  /// for the current user, fetched from AppRefer if not cached. Null when
  /// AppRefer is unreachable: the purchase still goes ahead.
  Future<String?> accountToken() async {
    final user = currentAppUserId;
    final cached = _storage.accountToken(user);
    if (cached != null) return cached;
    try {
      await _fetchFromServer();
    } catch (_) {}
    return _storage.accountToken(user);
  }

  // --- Identity ---

  Future<AppReferCustomerInfo> logIn(String appUserId) async {
    if (!isValidAppUserId(appUserId) || BillingStorage.isAnonymous(appUserId)) {
      throw const AppReferBillingException(
        AppReferBillingErrorCode.invalidAppUserId,
      );
    }
    if (appUserId != currentAppUserId) {
      if (isAnonymous) {
        _storage.pendingIdentify = (
          anonymousId: _storage.anonymousId(),
          appUserId: appUserId,
        );
      }
      _storage.loggedInAppUserId = appUserId;
      _lastServerFetch = null;
    }
    return customerInfo(FetchPolicy.fetchCurrent);
  }

  Future<AppReferCustomerInfo> logOut() async {
    _storage.loggedInAppUserId = null;
    _storage.pendingIdentify = null;
    _storage.resetAnonymousId();
    _lastServerFetch = null;
    return customerInfo(FetchPolicy.fetchCurrent);
  }

  void setAttributes(Map<String, String> attributes) {
    _storage.mergePendingAttributes(attributes);
  }

  Future<void> _flushPendingIdentify() async {
    final pending = _storage.pendingIdentify;
    if (pending == null) return;
    try {
      await _api.send(Identify(pending.anonymousId, pending.appUserId));
      _storage.pendingIdentify = null;
    } on AppReferBillingException catch (e) {
      if (e.isRetryable) {
        _logger.warn('Billing: identify will be retried ($e)');
      } else {
        _storage.pendingIdentify = null;
      }
    }
  }

  Future<String?> _safeAppreferId() async {
    try {
      return await _appreferId();
    } catch (_) {
      return null;
    }
  }

  static final _appUserIdPattern = RegExp(r'^\S{1,256}$');

  static bool isValidAppUserId(String appUserId) =>
      _appUserIdPattern.hasMatch(appUserId);
}
