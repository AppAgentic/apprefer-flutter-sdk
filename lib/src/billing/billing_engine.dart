import 'dart:async';
import 'dart:convert';

import 'package:in_app_purchase/in_app_purchase.dart';

import '../services/logger.dart';
import 'billing_api_client.dart';
import 'billing_error.dart';
import 'billing_storage.dart';
import 'billing_store.dart';
import 'customer_info.dart';
import 'pending_purchase_queue.dart';
import 'purchase_intents.dart';
import 'rejected_purchases.dart';

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
  final RejectedPurchaseLog _rejected;
  final PurchaseIntentStore _intents;
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

  /// Retry queue back-off after 401/403/404/409/429 or a `Retry-After`.
  ({DateTime until, Duration delay})? _drainBackoff;
  static const minBackoff = Duration(seconds: 30);
  static const maxBackoff = Duration(hours: 1);

  /// `configure(appUserId:)` that could not be applied because billing state
  /// was unreadable; applied once it can be read.
  String? _pendingConfigure;

  /// Google consumables the retry queue delivered this launch, still to be
  /// consumed (they are consumed only once AppRefer recorded them).
  final _recorded = <String>{};
  Future<void>? _retryingUnfinished;

  /// Set when the queue recorded a consumable while a [retryUnfinished] pass
  /// was running; that pass runs once more instead of being awaited from
  /// inside itself.
  bool _retryAgain = false;
  Future<void>? _flushingIdentifies;

  /// Purchases being sent right now, so a purchase delivered twice (stream and
  /// unfinished list) is only sent once.
  final _inFlight = <String, Future<AppReferCustomerInfo>>{};

  /// `purchase()` calls waiting for their result on the update stream, with
  /// the app user who started each one and the intent saved for it.
  final _waiters =
      <
        String,
        ({
          Completer<PurchaseResult> completer,
          String? appUserId,
          PurchaseIntent? intent,
        })
      >{};

  BillingEngine({
    required BillingApiClient api,
    required BillingStorage storage,
    required PendingPurchaseQueue queue,
    required BillingStoreAdapter store,
    RejectedPurchaseLog? rejected,
    PurchaseIntentStore? intents,
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
       _rejected =
           rejected ??
           RejectedPurchaseLog(
             storage.prefs,
             BillingStorage.rejectedPurchasesKey,
           ),
       _intents =
           intents ??
           PurchaseIntentStore(
             storage.prefs,
             BillingStorage.purchaseIntentsKey,
             now: now,
           ),
       _options = options,
       _appreferId = appreferId,
       _logger = logger,
       _now = now ?? DateTime.now,
       _onChange = onChange ?? ((_) {}) {
    if (appUserId != null && appUserId.isNotEmpty) {
      _pendingConfigure = appUserId;
      try {
        _applyPendingConfigure();
      } on AppReferBillingException catch (e) {
        _logger.warn('Billing: identity applied once storage is readable ($e)');
      }
    }
  }

  /// configure(appUserId:) behaves like logIn: purchases made while anonymous
  /// on this device move to the user (sent to /identify when reachable).
  /// Throws [AppReferBillingErrorCode.storage] when the identity can't be read.
  void _applyPendingConfigure() {
    final appUserId = _pendingConfigure;
    if (appUserId == null) return;
    final storage = _storage;
    if (appUserId != storage.loggedInAppUserId) {
      if (storage.loggedInAppUserId == null &&
          storage.hasAnonymousId &&
          !BillingStorage.isAnonymous(appUserId)) {
        storage.addPendingIdentify((
          anonymousId: storage.anonymousId(),
          appUserId: appUserId,
        ));
      }
      storage.loggedInAppUserId = BillingStorage.isAnonymous(appUserId)
          ? null
          : appUserId;
    }
    _pendingConfigure = null;
  }

  /// The current app user, or null when billing state can't be read or the
  /// identity did not reach disk. Then nothing is sent and no new identity is
  /// minted; answers come from the store.
  Future<String?> _activeUser() async {
    try {
      _applyPendingConfigure();
      final user = _storage.currentAppUserId;
      if (await _storage.flush()) return user;
      _logger.warn('Billing: could not save the app user id; not sending yet');
    } on AppReferBillingException catch (e) {
      _logger.warn('Billing: $e');
    }
    return null;
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
    await retryUnfinished();
    await customerInfo(FetchPolicy.fetchCurrent);
  }

  /// App came to the foreground: retries failed store completions (Google
  /// acknowledge/consume), refreshes entitlements and drains the queue.
  Future<void> resume() async {
    await retryUnfinished();
    await customerInfo(FetchPolicy.cachedOrFetched);
    await drainQueue();
  }

  Future<void> dispose() async {
    await _updates?.cancel();
    _updates = null;
  }

  /// Empty when billing state can't be read.
  String get currentAppUserId {
    try {
      _applyPendingConfigure();
      return _storage.currentAppUserId;
    } on AppReferBillingException {
      return '';
    }
  }

  bool get isAnonymous {
    try {
      _applyPendingConfigure();
      return _storage.loggedInAppUserId == null;
    } on AppReferBillingException {
      return true;
    }
  }

  // --- CustomerInfo ---

  Future<AppReferCustomerInfo> customerInfo(FetchPolicy policy) async {
    final user = await _activeUser();
    if (user == null) return localFallback();
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
      return await _fetchFromServer(user);
    } catch (e) {
      _logger.warn(
        'Billing: customer refresh failed ($e); using store fallback',
      );
      return localFallback();
    }
  }

  Future<AppReferCustomerInfo> _fetchFromServer(String user) async {
    await _flushPendingIdentifies();
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

  /// Merges this customer's verified store purchases into a server answer, so
  /// a payer is never locked out when the server didn't get the purchase
  /// (upload dropped or rejected, or no account token for the store
  /// notification to match). A purchase counts as the customer's when it has
  /// no account token, carries the customer's token, or is still queued for
  /// them; one tagged with another user's token is left out.
  Future<AppReferCustomerInfo> _withPendingLocal(
    AppReferCustomerInfo info,
  ) async {
    final user = info.appUserId;
    final token = _storage.accountToken(user)?.toLowerCase();
    final queued = {
      for (final e in _queue.entries)
        if (e.appUserId == user) e.transactionId,
      for (final e in _rejected.entries)
        if (e.appUserId == user) e.transactionId,
    };
    final mine = [
      for (final e in await _activeEntitlements())
        if (e.accountToken == null ||
            e.accountToken!.toLowerCase() == token ||
            queued.contains(e.transactionId))
          e,
    ];
    if (mine.isEmpty) return info;
    return _mergeLocal(info, mine, user, info.source);
  }

  /// What callers see after a purchase upload failed or was rejected: the
  /// server answer with this customer's own store purchases merged in when
  /// the customer endpoint works; every purchase on the device only when
  /// AppRefer can't be reached at all. After a network failure one customer
  /// fetch is still tried, and only if that fails too is the answer the
  /// unrestricted store fallback.
  Future<AppReferCustomerInfo> _answerAfterUploadFailure([
    AppReferBillingException? error,
  ]) => customerInfo(
    error?.code == AppReferBillingErrorCode.network
        ? FetchPolicy.fetchCurrent
        : FetchPolicy.cachedOrFetched,
  );

  /// Outage path: every store-verified active purchase on the device merged
  /// with the cached server answer for the same user. A paying user is never
  /// locked out because AppRefer is down.
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
        // The saved intent stays: the purchase may complete after a restart,
        // a logout or a user switch.
        _resolve(purchase.productId, PurchaseOutcome.pending, null);
      case StorePurchaseStatus.canceled:
        if (purchase.needsCompletion) await _complete(purchase);
        await _dropIntent(_waiters[purchase.productId]?.intent);
        _resolve(purchase.productId, PurchaseOutcome.userCancelled, null);
      case StorePurchaseStatus.error:
        if (purchase.needsCompletion) await _complete(purchase);
        final waiter = _waiters.remove(purchase.productId);
        // Only a definitive failure ends the purchase; after a network or
        // service error it may still complete, and the intent is needed.
        if (isDefinitiveStoreFailure(purchase)) {
          await _dropIntent(waiter?.intent);
        }
        waiter?.completer.completeError(
          AppReferBillingException(
            AppReferBillingErrorCode.store,
            message: purchase.errorMessage,
          ),
        );
      case StorePurchaseStatus.purchased:
      case StorePurchaseStatus.restored:
        // A renewal is not the purchase a waiting `purchase()` call started.
        final waiter = purchase.isRenewal
            ? null
            : _waiters.remove(purchase.productId);
        final info = await process(
          purchase,
          appUserId: waiter?.appUserId,
          intent: waiter?.intent,
        );
        waiter?.completer.complete(
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
      customerInfo(FetchPolicy.cachedOrFetched).then(
        (info) =>
            waiter.completer.complete(PurchaseResult(outcome, details, info)),
      ),
    );
  }

  /// Sends a store purchase to AppRefer, then completes it with the store. If
  /// AppRefer can't take it now, it is queued on disk and secured with the
  /// store (see [_queueAndSecure]); if AppRefer refuses it for good, it is
  /// saved to the rejected list first (see [_secureRejected]). Access comes
  /// from the store meanwhile.
  ///
  /// [appUserId] is the user who started the purchase. Otherwise a purchase
  /// tagged with an account token issued to a user on this device goes to that
  /// user, then a new purchase (never a renewal) matching a saved purchase
  /// intent to the user who started it, and anything else to the current
  /// user. While saved intents are lost (see [PurchaseIntentStore]) an
  /// untagged new purchase with no intent is left open with the store for up
  /// to 48 hours before it goes to the current user. Never sent as a restore.
  /// [intent] is ignored for a renewal: it is neither used nor removed.
  Future<AppReferCustomerInfo> process(
    StorePurchase purchase, {
    String? appUserId,
    PurchaseIntent? intent,
  }) {
    final key = '${purchase.store.value}:${purchase.id}';
    final running = _inFlight[key];
    if (running != null) return running;
    // A block body: `=> _inFlight.remove(key)` would return this very future
    // to whenComplete, which would then wait on itself.
    final future = _process(purchase, appUserId, intent).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<AppReferCustomerInfo> _process(
    StorePurchase purchase,
    String? initiator,
    PurchaseIntent? suppliedIntent,
  ) async {
    // A renewal never matches or uses up a saved intent, even one handed in
    // by the purchase sheet that is waiting.
    final waiterIntent = purchase.isRenewal ? null : suppliedIntent;
    final fields = purchase.storeFields;
    if (fields == null || purchase.id.isEmpty) {
      _logger.error(
        'Billing: purchase of ${purchase.productId} has no verifiable store data; not granting access',
      );
      if (await _secureRejected(
        purchase,
        fields,
        null,
        null,
        'no verifiable store data',
      )) {
        await _dropIntent(waiterIntent);
      }
      return _answerAfterUploadFailure();
    }

    final current = await _activeUser();
    if (current == null) {
      // Whose purchase this is can't be read, so there is no retry copy:
      // left open with the store, which delivers it again (Google: the
      // server acknowledges from its store notification within 3 days).
      return localFallback();
    }
    final byToken = initiator == null ? _ownerByToken(purchase) : null;
    var intent = waiterIntent;
    String? note;
    var held = false;
    if (intent == null && initiator == null && !purchase.isRenewal) {
      try {
        intent = await _intentFor(purchase);
        if (intent == null &&
            byToken == null &&
            purchase.accountToken == null) {
          final lost = _intents.lostMarker();
          if (lost != null) {
            await _intents.hold(lost, _key(purchase));
            // From the earlier of the purchase and the loss, so it stays inside
            // Google's 3-day acknowledgement window.
            final at = purchase.purchasedAt;
            final from = at != null && at.isBefore(lost.lostAt)
                ? at
                : lost.lostAt;
            if (_now().isBefore(from.add(PurchaseIntentStore.lostHold))) {
              _logger.warn(
                'Billing: purchase ${purchase.id} left open: saved purchase intents were lost and it carries no account token',
              );
              return localFallback();
            }
            held = true;
            note =
                'Owner guessed: saved purchase intents were lost on ${lost.lostAt.toUtc().toIso8601String()}; after a ${PurchaseIntentStore.lostHold.inHours} h hold this untagged purchase went to the user signed in then ($current)';
            _logger.warn('Billing: purchase ${purchase.id}: $note');
          }
        }
      } on AppReferBillingException catch (e) {
        if (byToken == null) {
          // Who started it can't be read: never given to whoever is current.
          // Left open with the store, which delivers it again.
          _logger.warn(
            'Billing: purchase ${purchase.id} left open until its owner can be read ($e)',
          );
          return localFallback();
        }
        intent = null;
      }
    }
    final user = initiator ?? byToken ?? intent?.appUserId ?? current;
    final attributes = user == current
        ? _storage.pendingAttributes
        : const <String, String>{};
    final deviceId = await _safeAppreferId();
    try {
      final response = await _api.send(
        RecordPurchase(user, deviceId, fields, attributes),
      );
      _storage.clearSentAttributes(attributes);
      await _complete(purchase);
      await _rejected.remove(purchase.store, purchase.id);
      await _dropIntent(intent);
      if (held) await _releaseHold(purchase);
      final info = await _accept(response, user);
      await drainQueue();
      return user == currentAppUserId
          ? info
          : customerInfo(FetchPolicy.cachedOrFetched);
    } on AppReferBillingException catch (e) {
      final bool secured;
      if (e.isRetryable) {
        _notePause(e);
        secured = await _queueAndSecure(purchase, fields, user, deviceId, e);
      } else {
        // Refused for good (400/413/422): kept on the device for support and
        // Restore Purchases; the store fallback still unlocks a verified
        // purchase.
        _logger.error('Billing: AppRefer rejected purchase ${purchase.id}: $e');
        secured = await _secureRejected(
          purchase,
          fields,
          user,
          deviceId,
          e.toString(),
          note: note,
        );
      }
      // Until a copy is on disk the store delivers the purchase again, and the
      // intent is still needed.
      if (secured) {
        await _dropIntent(intent);
        if (held) await _releaseHold(purchase);
      }
      return _answerAfterUploadFailure(e.isRetryable ? e : null);
    }
  }

  /// The user an account token on the purchase was issued to on this device.
  String? _ownerByToken(StorePurchase purchase) {
    final token = purchase.accountToken;
    return token == null ? null : _storage.appUserIdForAccountToken(token);
  }

  static String _key(StorePurchase purchase) =>
      '${purchase.store.value}:${purchase.id}';

  /// The saved intent for a new purchase delivered without its `purchase()`
  /// call (Ask to Buy approved later, the app restarted, or a user switch
  /// meanwhile): the oldest with the purchase's account token; for an
  /// untagged purchase, the oldest for the same product, with or without a
  /// token. Oldest is the earliest `startedAt`, never the stored order.
  /// Never called for a renewal. Throws [AppReferBillingErrorCode.storage]
  /// when the intents can't be read.
  Future<PurchaseIntent?> _intentFor(StorePurchase purchase) async {
    final intents = await _intents.read();
    final token = purchase.accountToken?.toLowerCase();
    if (token != null) {
      return _oldest(
        intents.where((i) => i.accountToken?.toLowerCase() == token),
      );
    }
    return _oldest(intents.where((i) => i.productId == purchase.productId));
  }

  /// The intent with the earliest `startedAt`, whatever order they are
  /// stored in; on a tie, the first stored.
  static PurchaseIntent? _oldest(Iterable<PurchaseIntent> intents) {
    PurchaseIntent? oldest;
    for (final i in intents) {
      if (oldest == null || i.startedAt.isBefore(oldest.startedAt)) oldest = i;
    }
    return oldest;
  }

  Future<void> _releaseHold(StorePurchase purchase) async {
    try {
      await _intents.release(_key(purchase));
    } catch (e) {
      _logger.warn('Billing: could not release held purchase ($e)');
    }
  }

  Future<void> _dropIntent(PurchaseIntent? intent) async {
    if (intent == null) return;
    try {
      await _intents.remove(intent);
    } catch (e) {
      _logger.warn('Billing: could not drop purchase intent ($e)');
    }
  }

  /// Queues a purchase AppRefer couldn't take, then secures it with the
  /// store once the queue entry is on disk: Google is acknowledged (never
  /// consumed), so Google can't refund it even if the app isn't opened again
  /// within 3 days; Apple is finished. Until the entry is on disk the purchase
  /// stays open and [retryUnfinished] saves and secures it on the next
  /// foreground (the server acknowledges Google purchases too).
  Future<bool> _queueAndSecure(
    StorePurchase purchase,
    Map<String, String> fields,
    String user,
    String? deviceId,
    AppReferBillingException error, {
    bool restore = false,
    bool attempted = true,
  }) async {
    _logger.warn('Billing: queued purchase ${purchase.id} for retry ($error)');
    await _queue.add(
      PendingPurchase(
        transactionId: purchase.id,
        productId: purchase.productId,
        appUserId: user,
        appreferId: deviceId,
        storeFields: fields,
        enqueuedAt: _now(),
        attempts: attempted && !error.pausesQueue ? 1 : 0,
        restore: restore,
      ),
    );
    return _secureQueued(purchase);
  }

  /// Secures a queued purchase with the store, only once its retry copy is
  /// on disk (saving it again first if needed). Returns whether it is.
  Future<bool> _secureQueued(StorePurchase purchase) async {
    if (!_queue.isDurable(purchase.id) && !await _queue.persist()) {
      _logger.error(
        'Billing: could not save purchase ${purchase.id}; left open so the store delivers it again',
      );
      return false;
    }
    if (!_queue.isDurable(purchase.id)) return false;
    if (purchase.store == BillingStore.playStore) {
      await _acknowledge(purchase);
    } else {
      await _complete(purchase);
    }
    return true;
  }

  /// A purchase AppRefer won't take (final 400/413/422, or no verifiable store
  /// data): its full data is saved to the rejected list first, and only then
  /// is it secured with the store. Until that copy is on disk nothing is
  /// completed, so the store delivers it again. Returns whether it is on disk.
  Future<bool> _secureRejected(
    StorePurchase purchase,
    Map<String, String>? fields,
    String? user,
    String? deviceId,
    String reason, {
    String? note,
  }) async {
    final saved = await _rejected.add(
      RejectedPurchase(
        transactionId: purchase.id,
        productId: purchase.productId,
        store: purchase.store,
        appUserId: user,
        appreferId: deviceId,
        storeFields: fields,
        accountToken: purchase.accountToken,
        kind: _kindName(purchase.kind),
        reason: reason,
        rejectedAt: _now(),
        raw: fields == null ? _rawPurchase(purchase) : null,
        note: note,
      ),
    );
    if (!saved) {
      _logger.error(
        'Billing: could not save rejected purchase ${purchase.id}; left open so the store delivers it again',
      );
      return false;
    }
    await _completeRejected(purchase);
    return true;
  }

  /// Secures an archived purchase with the store, only once its archived copy
  /// is on disk (saving it again first if needed): never from a copy held only
  /// in memory.
  Future<void> _secureArchived(StorePurchase purchase) async {
    if (!_rejected.isDurable(purchase.store, purchase.id) &&
        (!await _rejected.persist() ||
            !_rejected.isDurable(purchase.store, purchase.id))) {
      _logger.error(
        'Billing: could not save rejected purchase ${purchase.id}; left open so the store delivers it again',
      );
      return;
    }
    await _completeRejected(purchase);
  }

  /// A consumable is never consumed or finished here: Google is only
  /// acknowledged (so it is not refunded) and Apple is left unfinished, so it
  /// stays recoverable. Anything else is completed.
  Future<void> _completeRejected(StorePurchase purchase) async {
    if (purchase.kind == StoreProductKind.consumable) {
      if (purchase.store == BillingStore.playStore) {
        await _acknowledge(purchase);
      }
    } else {
      await _complete(purchase);
    }
  }

  static String? _kindName(StoreProductKind? kind) => switch (kind) {
    StoreProductKind.autoRenewable => 'auto_renewable',
    StoreProductKind.nonRenewable => 'non_renewable',
    StoreProductKind.consumable => 'consumable',
    StoreProductKind.nonConsumable => 'non_consumable',
    null => null,
  };

  /// What the store plugin delivered, for support, when there is nothing
  /// AppRefer can verify.
  static String? _rawPurchase(StorePurchase purchase) {
    final d = purchase.details;
    try {
      return jsonEncode({
        'id': purchase.id,
        'productId': purchase.productId,
        'status': purchase.status.name,
        'accountToken': purchase.accountToken,
        'signedTransaction': purchase.signedTransaction,
        'purchaseToken': purchase.purchaseToken,
        if (d != null) ...{
          'purchaseID': d.purchaseID,
          'transactionDate': d.transactionDate,
          'localVerificationData': d.verificationData.localVerificationData,
          'serverVerificationData': d.verificationData.serverVerificationData,
          'verificationSource': d.verificationData.source,
          'error': d.error?.message,
        },
      });
    } catch (_) {
      return null;
    }
  }

  /// Finish / acknowledge / consume. False when the store refused; retried by
  /// [retryUnfinished] on the next foreground.
  Future<bool> _complete(StorePurchase purchase) async {
    if (!purchase.needsCompletion) return true;
    try {
      await purchase.complete();
      return true;
    } catch (e) {
      _logger.error('Billing: completing ${purchase.productId} failed: $e');
      return false;
    }
  }

  Future<bool> _acknowledge(StorePurchase purchase) async {
    if (!purchase.needsAcknowledgement) return true;
    try {
      await purchase.acknowledge();
      return true;
    } catch (e) {
      _logger.error('Billing: acknowledging ${purchase.productId} failed: $e');
      return false;
    }
  }

  /// Finishes what the store still has open: purchases never sent, Google
  /// purchases whose acknowledge or consume failed, and consumables AppRefer
  /// recorded from the retry queue. Runs at start and on every foreground.
  Future<void> retryUnfinished() {
    final running = _retryingUnfinished;
    if (running != null) return running;
    final future = _retryUnfinished().whenComplete(() {
      _retryingUnfinished = null;
    });
    _retryingUnfinished = future;
    return future;
  }

  Future<void> _retryUnfinished() async {
    do {
      _retryAgain = false;
      await _retryUnfinishedPass();
    } while (_retryAgain);
  }

  Future<void> _retryUnfinishedPass() async {
    final List<StorePurchase> open;
    try {
      open = await _store.unfinished();
    } catch (e) {
      _logger.warn('Billing: could not read unfinished purchases: $e');
      return;
    }
    for (final purchase in open) {
      if (_recorded.contains(purchase.id)) {
        if (await _complete(purchase)) _recorded.remove(purchase.id);
      } else if (_queue.contains(purchase.id)) {
        // Sending it is the retry queue's job; only secure it with the store.
        await _secureQueued(purchase);
      } else if (_rejected.contains(purchase.store, purchase.id)) {
        // Refused for good and kept for Restore Purchases: a consumable stays
        // unconsumed (Apple: unfinished) on purpose.
        await _secureArchived(purchase);
      } else {
        await process(purchase);
      }
    }
    // Purchases held while intents are lost and no longer open are forgotten;
    // the marker goes once nothing is held.
    try {
      await _intents.clearLostIfDone(open: {for (final p in open) _key(p)});
    } catch (e) {
      _logger.warn('Billing: could not update the lost-intents marker ($e)');
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
  /// and waits for the result, which arrives on the store update stream. The
  /// purchase is recorded for the user who started it, even if the app logs
  /// in or out meanwhile.
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
    // The initiator is read before anything is awaited, so a logIn/logOut
    // while the token is fetched or the sheet is open can't change it.
    final initiator = _activeUser();
    _waiters[product.id] = (completer: waiter, appUserId: null, intent: null);
    PurchaseIntent? intent;
    try {
      final user = await initiator;
      if (user == null) {
        throw const AppReferBillingException(
          AppReferBillingErrorCode.storage,
          message:
              'Could not read or save the app user on this device; the purchase was not started',
        );
      }
      final accountToken = await _accountTokenFor(user);
      // Saved before the sheet opens, so a purchase delivered after a restart,
      // logout or user switch still goes to this user.
      intent = PurchaseIntent(
        appUserId: user,
        productId: product.id,
        accountToken: accountToken,
        startedAt: _now(),
      );
      if (!await _intents.add(intent)) {
        intent = null;
        throw const AppReferBillingException(
          AppReferBillingErrorCode.storage,
          message:
              'Could not save who started the purchase on this device; the purchase was not started',
        );
      }
      _waiters[product.id] = (
        completer: waiter,
        appUserId: user,
        intent: intent,
      );
      await _store.buy(
        product,
        StorePurchaseOptions(
          accountToken: accountToken,
          promotionalOffer: options.promotionalOffer,
          winBackOfferId: options.winBackOfferId,
          changeSubscriptionParam: options.changeSubscriptionParam,
        ),
      );
    } catch (e) {
      if (identical(_waiters[product.id]?.completer, waiter)) {
        _waiters.remove(product.id);
      }
      // Kept unless the store said no purchase can come of it: after an
      // ambiguous failure the purchase may still be delivered.
      if (isDefinitiveStoreFailure(e)) await _dropIntent(intent);
      if (e is AppReferBillingException) rethrow;
      throw AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: e.toString(),
      );
    }
    return waiter.future;
  }

  /// Apple `AppStore.sync()`, then sends every purchase the store owns to
  /// AppRefer as a restore, which may move a purchase owned by another app
  /// user to this one.
  Future<AppReferCustomerInfo> restore() async {
    try {
      // The restoring customer is whoever was current when restore started.
      final restoring = _activeUser();
      await _store.sync();
      final purchases = await _store.restore();
      final user = await restoring;
      // Archived purchases the store no longer lists (finished App Store
      // purchases) are sent again too.
      final listed = {for (final p in purchases) '${p.store.value}:${p.id}'};
      final archived = [
        for (final e in _rejected.entries)
          if (e.storeFields != null &&
              e.transactionId.isNotEmpty &&
              !listed.contains('${e.store.value}:${e.transactionId}'))
            e,
      ];
      if (purchases.isEmpty && archived.isEmpty) {
        return customerInfo(FetchPolicy.fetchCurrent);
      }
      // Identity unreadable: nothing can be queued for anyone, so the
      // purchases stay open with the store.
      if (user == null) return localFallback();
      await _flushPendingIdentifies();
      final deviceId = await _safeAppreferId();
      BillingCustomerResponse? last;
      AppReferBillingException? failed;
      AppReferBillingException? paused;
      for (final purchase in purchases) {
        final fields = purchase.storeFields;
        if (fields == null) continue;
        if (paused != null) {
          await _queueAndSecure(
            purchase,
            fields,
            user,
            deviceId,
            paused,
            restore: true,
            attempted: false,
          );
          continue;
        }
        try {
          last = await _api.send(
            RecordPurchase(user, deviceId, fields, const {}, restore: true),
          );
          await _rejected.remove(purchase.store, purchase.id);
          await _complete(purchase);
        } on AppReferBillingException catch (e) {
          failed = e;
          if (e.isRetryable) {
            _notePause(e);
            await _queueAndSecure(
              purchase,
              fields,
              user,
              deviceId,
              e,
              restore: true,
            );
            if (e.isConnectivity || e.pausesQueue) paused = e;
          } else {
            _logger.error(
              'Billing: AppRefer rejected restored purchase ${purchase.id}: $e',
            );
            await _secureRejected(purchase, fields, user, deviceId, '$e');
          }
        }
      }
      for (final entry in archived) {
        if (paused != null) break;
        try {
          last = await _api.send(
            RecordPurchase(
              user,
              deviceId,
              entry.storeFields!,
              const {},
              restore: true,
            ),
          );
          await _rejected.remove(entry.store, entry.transactionId);
          // A consumable kept open can now be consumed.
          if (entry.isConsumable) _recorded.add(entry.transactionId);
        } on AppReferBillingException catch (e) {
          // Kept in the list either way; sent again with the next restore.
          failed = e;
          if (e.isRetryable) {
            _notePause(e);
            if (e.isConnectivity || e.pausesQueue) paused = e;
          }
        }
      }
      if (_recorded.isNotEmpty) await retryUnfinished();
      // A server answer is filtered to this customer's purchases (its queued
      // restores included); with none, unrestricted fallback only on outage.
      if (last != null) return _accept(last, user);
      if (failed != null) return _answerAfterUploadFailure(failed);
      return customerInfo(FetchPolicy.fetchCurrent);
    } on AppReferBillingException {
      rethrow;
    } catch (e) {
      throw AppReferBillingException(
        AppReferBillingErrorCode.store,
        message: e.toString(),
      );
    }
  }

  /// Re-sends queued purchases (a queued restore is still sent as a restore).
  /// Stops at the first connectivity failure. A 401/403/404/409/429 stops the
  /// drain and backs off (30 s doubling to 1 h, or the server's Retry-After)
  /// without counting an attempt, so a server-side setup problem never uses
  /// up a purchase's retries.
  Future<void> drainQueue() async {
    if (_isDraining || _queue.isEmpty) return;
    final backoff = _drainBackoff;
    if (backoff != null && _now().isBefore(backoff.until)) return;
    _isDraining = true;
    final bool consumablesRecorded;
    try {
      consumablesRecorded = await _drain();
    } finally {
      _isDraining = false;
    }
    if (!consumablesRecorded) return;
    if (_retryingUnfinished != null) {
      // Reached from inside a retryUnfinished pass (it processed a purchase,
      // which drained the queue): awaiting it here would wait on itself.
      _retryAgain = true;
    } else {
      await retryUnfinished();
    }
  }

  /// Returns whether a Google consumable was recorded (and can now be consumed).
  Future<bool> _drain() async {
    var consumables = false;
    for (final old in _queue.expired(_now())) {
      _logger.error(
        'Billing: gave up resending purchase ${old.transactionId} after ${old.attempts} attempts',
      );
      await _moveToRejected(old, 'not recorded after ${old.attempts} attempts');
    }
    for (final entry in _queue.entries) {
      try {
        final response = await _api.send(
          RecordPurchase(
            entry.appUserId,
            entry.appreferId,
            entry.storeFields,
            const {},
            restore: entry.restore,
          ),
        );
        await _queue.remove(entry.transactionId);
        _drainBackoff = null;
        if (entry.isConsumable) {
          _recorded.add(entry.transactionId);
          consumables = true;
        }
        if (entry.appUserId == currentAppUserId) {
          await _accept(response, entry.appUserId);
        }
      } on AppReferBillingException catch (e) {
        if (!e.isRetryable) {
          _logger.error(
            'Billing: AppRefer rejected queued purchase ${entry.transactionId}: $e',
          );
          await _moveToRejected(entry, e.toString());
          continue;
        }
        if (e.pausesQueue) {
          _notePause(e);
          return consumables;
        }
        await _queue.recordAttempt(entry.transactionId);
        if (e.isConnectivity) {
          _notePause(e);
          return consumables;
        }
      }
    }
    return consumables;
  }

  /// Moves a queued purchase to the rejected list; it leaves the queue only
  /// once that copy is on disk (a queued Google purchase was acknowledged,
  /// never consumed, so it stays recoverable).
  Future<void> _moveToRejected(PendingPurchase entry, String reason) async {
    final saved = await _rejected.add(
      RejectedPurchase(
        transactionId: entry.transactionId,
        productId: entry.productId,
        store: entry.storeFields['store'] == 'play_store'
            ? BillingStore.playStore
            : BillingStore.appStore,
        appUserId: entry.appUserId,
        appreferId: entry.appreferId,
        storeFields: entry.storeFields,
        accountToken: null,
        kind: entry.isConsumable ? 'consumable' : null,
        reason: reason,
        rejectedAt: _now(),
      ),
    );
    if (saved) {
      await _queue.removeIfUnchanged(entry);
    } else {
      _logger.error(
        'Billing: could not save rejected purchase ${entry.transactionId}; kept in the retry queue',
      );
    }
  }

  /// Backs the retry queue off after a "not now" status, or for as long as
  /// the server's Retry-After says (e.g. 503 when it verified a purchase but
  /// couldn't record it yet).
  void _notePause(AppReferBillingException error) {
    final retryAfter = error.retryAfter;
    if (!error.isBackoff && retryAfter == null) return;
    Duration delay;
    if (retryAfter != null) {
      delay = retryAfter;
    } else {
      delay = (_drainBackoff?.delay ?? Duration.zero) * 2;
      if (delay < minBackoff) delay = minBackoff;
    }
    if (delay > maxBackoff) delay = maxBackoff;
    _drainBackoff = (until: _now().add(delay), delay: delay);
    _logger.warn(
      'Billing: AppRefer answered $error; retrying queued purchases in ${delay.inSeconds}s',
    );
  }

  /// See `AppReferBilling.rejectedPurchases`.
  List<RejectedPurchase> rejectedPurchases() => _rejected.entries;

  // --- Purchases ---

  /// The account token (Apple `appAccountToken` / Google `obfuscatedAccountId`)
  /// for the current user, fetched from AppRefer if not cached. Null when
  /// AppRefer is unreachable: the purchase still goes ahead.
  Future<String?> accountToken() async {
    final user = await _activeUser();
    return user == null ? null : _accountTokenFor(user);
  }

  Future<String?> _accountTokenFor(String user) async {
    final cached = _storage.accountToken(user);
    if (cached != null) return cached;
    try {
      await _fetchFromServer(user);
    } catch (_) {}
    return _storage.accountToken(user);
  }

  // --- Identity ---

  /// Throws [AppReferBillingErrorCode.storage] when the current identity can't
  /// be read (nothing is changed then).
  Future<AppReferCustomerInfo> logIn(String appUserId) async {
    if (!isValidAppUserId(appUserId) || BillingStorage.isAnonymous(appUserId)) {
      throw const AppReferBillingException(
        AppReferBillingErrorCode.invalidAppUserId,
      );
    }
    _applyPendingConfigure();
    if (appUserId != _storage.currentAppUserId) {
      if (_storage.loggedInAppUserId == null) {
        _storage.addPendingIdentify((
          anonymousId: _storage.anonymousId(),
          appUserId: appUserId,
        ));
      }
      _storage.loggedInAppUserId = appUserId;
      _lastServerFetch = null;
    }
    return customerInfo(FetchPolicy.fetchCurrent);
  }

  /// Pending identifies stay: they still have to reach the server.
  Future<AppReferCustomerInfo> logOut() async {
    _applyPendingConfigure();
    _storage.loggedInAppUserId = null;
    _storage.resetAnonymousId();
    _lastServerFetch = null;
    return customerInfo(FetchPolicy.fetchCurrent);
  }

  void setAttributes(Map<String, String> attributes) {
    _storage.mergePendingAttributes(attributes);
  }

  /// Sends waiting identifies in order; stops at the first one to retry.
  Future<void> _flushPendingIdentifies() {
    final running = _flushingIdentifies;
    if (running != null) return running;
    final future = _flushIdentifies().whenComplete(() {
      _flushingIdentifies = null;
    });
    _flushingIdentifies = future;
    return future;
  }

  Future<void> _flushIdentifies() async {
    try {
      for (final pending in _storage.pendingIdentifies) {
        try {
          await _api.send(Identify(pending.anonymousId, pending.appUserId));
        } on AppReferBillingException catch (e) {
          if (e.isRetryable) {
            _logger.warn('Billing: identify will be retried ($e)');
            return;
          }
        }
        // Only this entry: a login queued while it was in flight stays.
        _storage.removePendingIdentify(pending);
      }
    } on AppReferBillingException catch (e) {
      _logger.warn('Billing: pending identifies unreadable ($e)');
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
