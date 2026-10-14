import 'dart:async';
import 'dart:convert';

import 'package:apprefer/src/billing/billing_api_client.dart';
import 'package:apprefer/src/billing/billing_engine.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/billing_store.dart';
import 'package:apprefer/src/billing/customer_info.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:shared_preferences/shared_preferences.dart';

const token = '11111111-2222-4333-8444-555555555555';
final now = DateTime.fromMillisecondsSinceEpoch(1760000000000);

/// Server CustomerInfo JSON with the given active entitlements.
Map<String, dynamic> customerJson(
  String appUserId, {
  Map<String, String> active = const {}, // entitlement -> productId
  bool withToken = true,
  int? expiresAtMs,
}) => {
  'appUserId': appUserId,
  'entitlements': {
    for (final e in active.entries)
      e.key: {
        'id': e.key,
        'isActive': true,
        'productId': e.value,
        'store': 'app_store',
        'expiresAtMs':
            expiresAtMs ??
            now.add(const Duration(days: 30)).millisecondsSinceEpoch,
        'willRenew': true,
        'periodType': 'normal',
        'state': 'active',
        'subscriptionKey': 'orig_1',
      },
  },
  'activeSubscriptions': active.values.toList(),
  'requestDateMs': now.millisecondsSinceEpoch,
  if (withToken) 'accountToken': token,
};

/// Programmable AppRefer server. [handler] returns (status, body) or throws
/// to simulate a network failure.
class FakeServer {
  final requests = <http.Request>[];
  FutureOr<(int, Object?)> Function(http.Request request)? handler;

  /// Headers added to every response (e.g. Retry-After).
  Map<String, String> responseHeaders = {};

  FakeServer([this.handler]);

  late final client = MockClient((request) async {
    requests.add(request);
    final h = handler;
    if (h == null) throw http.ClientException('offline');
    final (status, body) = await h(request);
    return http.Response(
      body == null ? '' : jsonEncode(body),
      status,
      headers: responseHeaders,
    );
  });

  /// Answers every call with CustomerInfo for the request's appUserId.
  void online({Map<String, String> active = const {}}) {
    handler = (r) {
      final user = r.method == 'GET'
          ? r.url.queryParameters['appUserId']!
          : (jsonDecode(r.body) as Map)['appUserId'] as String;
      return (200, customerJson(user, active: active));
    };
  }

  void offline() => handler = null;

  void status(int code) => handler = (_) => (code, {'error': 'nope'});

  List<String> get paths => [
    for (final r in requests) '${r.method} ${r.url.path}',
  ];

  /// Distinct logical calls (the client tries two hosts on 5xx/network errors).
  List<Map<String, dynamic>> bodiesFor(String path) => [
    for (final r in requests)
      if (r.url.path == path && r.method == 'POST')
        jsonDecode(r.body) as Map<String, dynamic>,
  ];
}

class FakeProduct extends ProductDetails {
  FakeProduct(String id)
    : super(
        id: id,
        title: id,
        description: id,
        price: r'$1',
        rawPrice: 1,
        currencyCode: 'USD',
      );
}

class FakeStore implements BillingStoreAdapter {
  @override
  BillingStore store = BillingStore.appStore;

  final updates = StreamController<List<StorePurchase>>.broadcast();
  List<StoreEntitlement> entitlements = [];
  List<StorePurchase> unfinishedList = [];
  List<StorePurchase> restoreList = [];
  final bought = <(String, StorePurchaseOptions)>[];
  final completed = <String>[];
  final acknowledged = <String>[];

  /// Ids whose next complete/acknowledge throws (store refused).
  final failNextCompletion = <String>{};

  Future<void> _finish(String id, List<String> into) async {
    if (failNextCompletion.remove(id)) throw Exception('billing unavailable');
    into.add(id);
  }

  int syncCalls = 0;
  Object? syncError;

  /// What the store does when [buy] is called (e.g. emit an update).
  void Function(ProductDetails product, StorePurchaseOptions options)? onBuy;

  @override
  Stream<List<StorePurchase>> get purchaseUpdates => updates.stream;

  @override
  Future<List<ProductDetails>> products(List<String> productIds) async => [
    for (final id in productIds) FakeProduct(id),
  ];

  @override
  Future<void> buy(ProductDetails product, StorePurchaseOptions options) async {
    bought.add((product.id, options));
    onBuy?.call(product, options);
  }

  @override
  Future<List<StorePurchase>> unfinished() async => unfinishedList;

  @override
  Future<List<StoreEntitlement>> activeEntitlements() async => entitlements;

  @override
  Future<void> sync() async {
    syncCalls++;
    if (syncError != null) throw syncError!;
  }

  @override
  Future<List<StorePurchase>> restore() async => restoreList;

  StorePurchase applePurchase(
    String id,
    String productId, {
    StorePurchaseStatus status = StorePurchaseStatus.purchased,
    String? jws = 'jws.payload.sig',
    StoreProductKind kind = StoreProductKind.autoRenewable,
    String? accountToken,
  }) => StorePurchase(
    id: id,
    productId: productId,
    store: BillingStore.appStore,
    status: status,
    signedTransaction: jws,
    kind: kind,
    accountToken: accountToken,
    needsCompletion: status == StorePurchaseStatus.purchased,
    complete: () => _finish(id, completed),
  );

  /// `complete` consumes a consumable / acknowledges otherwise (recorded in
  /// [completed]); `acknowledge` never consumes (recorded in [acknowledged]).
  StorePurchase googlePurchase(
    String purchaseToken,
    String productId, {
    StoreProductKind kind = StoreProductKind.autoRenewable,
    StorePurchaseStatus status = StorePurchaseStatus.purchased,
    String? accountToken,
    bool isAcknowledged = false,
  }) => StorePurchase(
    id: purchaseToken,
    productId: productId,
    store: BillingStore.playStore,
    status: status,
    purchaseToken: purchaseToken,
    kind: kind,
    accountToken: accountToken,
    needsCompletion: kind == StoreProductKind.consumable || !isAcknowledged,
    needsAcknowledgement: !isAcknowledged,
    complete: () => _finish(purchaseToken, completed),
    acknowledge: () => _finish(purchaseToken, acknowledged),
  );
}

StoreEntitlement activeSub(
  String productId, {
  Duration left = const Duration(days: 3),
  String? accountToken,
  String? transactionId,
}) => StoreEntitlement(
  productId: productId,
  originalId: 'orig_$productId',
  kind: StoreProductKind.autoRenewable,
  store: BillingStore.appStore,
  expirationDate: now.add(left),
  accountToken: accountToken,
  transactionId: transactionId,
);

/// SharedPreferences whose disk writes can fail (the in-memory copy still
/// updates, as the real plugin does) and whose reads can throw.
class FlakyPrefs implements SharedPreferences {
  final SharedPreferences inner;
  bool failWrites = false;
  final unreadable = <String>{};

  FlakyPrefs(this.inner);

  @override
  String? getString(String key) {
    if (unreadable.contains(key)) throw StateError('storage locked');
    return inner.getString(key);
  }

  @override
  Future<bool> setString(String key, String value) async {
    final ok = await inner.setString(key, value);
    return failWrites ? false : ok;
  }

  @override
  Future<bool> remove(String key) async {
    final ok = await inner.remove(key);
    return failWrites ? false : ok;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Harness {
  final FakeServer server;
  final FakeStore store;
  final SharedPreferences prefs;
  final BillingStorage storage;
  final PendingPurchaseQueue queue;
  final BillingEngine engine;
  final published = <AppReferCustomerInfo>[];

  /// The engine's clock.
  DateTime time = now;

  Harness._(
    this.server,
    this.store,
    this.prefs,
    this.storage,
    this.queue,
    this.engine,
  );

  static Future<Harness> create({
    FakeServer? server,
    FakeStore? store,
    Map<String, Object> prefs = const {},
    String? appUserId,
    Map<String, List<String>> entitlementsByProduct = const {
      'pro_yearly': ['premium'],
    },
    String? apiKey = 'pk_test_1',
    SharedPreferences Function(SharedPreferences prefs)? wrapPrefs,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final real = await SharedPreferences.getInstance();
    final p = wrapPrefs == null ? real : wrapPrefs(real);
    final s = server ?? FakeServer();
    final st = store ?? FakeStore();
    final storage = BillingStorage(p);
    final queue = PendingPurchaseQueue(p, BillingStorage.pendingPurchasesKey);
    late Harness h;
    final engine = BillingEngine(
      api: BillingApiClient(
        baseUrls: const ['https://trk.example.com', 'https://example.com'],
        apiKey: () => apiKey,
        client: s.client,
        keyWaitAttempts: 0,
      ),
      storage: storage,
      queue: queue,
      store: st,
      options: BillingEngineOptions(productEntitlements: entitlementsByProduct),
      appUserId: appUserId,
      appreferId: () async => 'device-1',
      now: () => h.time,
      onChange: (info) => h.published.add(info),
    );
    h = Harness._(s, st, p, storage, queue, engine);
    return h;
  }
}
