import 'dart:async' show Completer;
import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/services/conversion_value.dart';
import 'package:apprefer/src/services/http_client.dart';
import 'package:apprefer/src/services/logger.dart';
import 'package:apprefer/src/services/storage.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'billing/support.dart' as billing;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppReferStorage storage;
  late ConversionValue conversion;
  late DateTime time;
  late List<(int, String)> updates;
  late List<http.Request> requests;
  late Map<String, dynamic> response;
  late MockClient client;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    storage = AppReferStorage();
    await storage.init();
    time = DateTime.now();
    updates = [];
    requests = [];
    response = {'fine': 0, 'coarse': 'low'};
    client = MockClient((r) async {
      requests.add(r);
      return http.Response(jsonEncode(response), 200);
    });
    conversion = ConversionValue(
      storage: storage,
      client: AppReferHttpClient(
        baseUrl: 'https://apprefer.com',
        apiKey: 'pk_test',
        logger: const AppReferLogger(),
      ),
      isIOS: () => true,
      now: () => time,
      update: (fine, coarse) async => updates.add((fine, coarse)),
    );
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await AppReferBilling.resetForTesting();
  });

  Future<void> refresh({bool force = false}) =>
      http.runWithClient(() => conversion.refresh(force: force), () => client);

  test(
    'registers zero/low once and persists across a new controller',
    () async {
      await refresh();
      expect(updates, [(0, 'low')]);
      conversion = ConversionValue(
        storage: storage,
        client: AppReferHttpClient(
          baseUrl: 'https://apprefer.com',
          apiKey: 'pk_test',
          logger: const AppReferLogger(),
        ),
        isIOS: () => true,
        update: (fine, coarse) async => updates.add((fine, coarse)),
      );
      await refresh(force: true);
      expect(updates, [(0, 'low')]);
      expect(storage.conversionValue()?.fine, 0);
    },
  );
  test(
    'raises fine and coarse independently and never lowers either',
    () async {
      response = {'fine': 30, 'coarse': 'medium'};
      await refresh();
      response = {'fine': 10, 'coarse': 'high'};
      await refresh(force: true);
      response = {'fine': 40, 'coarse': 'low'};
      await refresh(force: true);
      response = {'fine': 20, 'coarse': 'medium'};
      await refresh(force: true);
      expect(updates, [(0, 'low'), (30, 'medium'), (30, 'high'), (40, 'high')]);
      expect(storage.conversionValue(), (fine: 40, coarse: 'high'));
    },
  );
  test('throttles unforced checks for ten minutes; force bypasses', () async {
    await refresh();
    await refresh();
    expect(requests.length, 1);
    time = time.add(const Duration(minutes: 9));
    await refresh();
    expect(requests.length, 1);
    time = time.add(const Duration(minutes: 1));
    await refresh();
    expect(requests.length, 2);
    await refresh(force: true);
    expect(requests.length, 3);
  });
  test(
    'uses first-party host, key and only device_id for every consent',
    () async {
      final prefs = await SharedPreferences.getInstance();
      for (final consent in ['granted', 'denied', 'undetermined']) {
        await prefs.setString('apprefer_tracking_consent', consent);
        await refresh(force: true);
      }
      for (final r in requests) {
        expect(
          r.url.toString(),
          'https://apprefer.com/api/track/conversion-value',
        );
        expect(r.headers['X-AppRefer-Key'], 'pk_test');
        expect(jsonDecode(r.body), {'device_id': await storage.getDeviceId()});
      }
    },
  );
  test('stops after 35 days even when forced', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'apprefer_first_run_date',
      time.subtract(const Duration(days: 36)).toIso8601String(),
    );
    await refresh(force: true);
    expect(updates, isEmpty);
    expect(requests, isEmpty);
  });
  test('kill switch prevents registration and requests', () async {
    await storage.setSdkEnabled(false);
    await refresh(force: true);
    expect(updates, isEmpty);
    expect(requests, isEmpty);
  });
  test('Android is a no-op', () async {
    conversion = ConversionValue(
      storage: storage,
      client: AppReferHttpClient(
        baseUrl: 'https://apprefer.com',
        apiKey: 'pk_test',
        logger: const AppReferLogger(),
      ),
      isIOS: () => false,
      update: (fine, coarse) async => updates.add((fine, coarse)),
    );
    await refresh(force: true);
    expect(updates, isEmpty);
    expect(requests, isEmpty);
  });
  test('rejects malformed and out-of-range server values', () async {
    for (final value in [
      {'fine': -1, 'coarse': 'high'},
      {'fine': 64, 'coarse': 'high'},
      {'fine': 1.5, 'coarse': 'low'},
      {'fine': 20, 'coarse': 'invalid'},
    ]) {
      response = value;
      await refresh(force: true);
    }
    expect(updates, [(0, 'low')]);
  });
  test('overlapping refreshes do not duplicate registration', () async {
    await http.runWithClient(
      () =>
          Future.wait([conversion.refresh(), conversion.refresh(force: true)]),
      () => client,
    );
    expect(updates, [(0, 'low')]);
    expect(requests.length, 1);
  });

  Future<void> configureSDK() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.apprefer.sdk/adservices'),
          (call) async {
            if (call.method == 'updateConversionValue')
              updates.add((
                call.arguments['fine'] as int,
                call.arguments['coarse'] as String,
              ));
            return null;
          },
        );
    await AppReferSDK.configure(const AppReferConfig(apiKey: 'pk_test'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  test(
    'configure is nonblocking; resume is throttled and refreshes when due',
    () async {
      await http.runWithClient(() async {
        await configureSDK();
        expect(updates, [(0, 'low')]);
        final count = requests
            .where((r) => r.url.path.endsWith('conversion-value'))
            .length;
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(
          requests.where((r) => r.url.path.endsWith('conversion-value')).length,
          count,
        );
        await storage.setConversionCheckedAt(
          DateTime.now().subtract(const Duration(minutes: 11)),
        );
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(
          requests.where((r) => r.url.path.endsWith('conversion-value')).length,
          count + 1,
        );
      }, () => client);
    },
  );
  test(
    'trial variants and positive revenue force refresh; ordinary events do not',
    () async {
      await http.runWithClient(() async {
        await configureSDK();
        requests.clear();
        for (final event in ConversionValue.trialEvents)
          await AppReferSDK.trackEvent(event);
        await AppReferSDK.trackEvent('paid', revenue: 1);
        await AppReferSDK.trackEvent('ordinary');
        await AppReferSDK.trackEvent('refund', revenue: -1);
        expect(
          requests.where((r) => r.url.path.endsWith('conversion-value')).length,
          5,
        );
      }, () => client);
    },
  );
  test('successful billing purchase forces conversion refresh', () async {
    await http.runWithClient(() async {
      await configureSDK();
      requests.clear();
      final server = billing.FakeServer()
        ..online(active: {'premium': 'pro_yearly'});
      final store = billing.FakeStore();
      store.onBuy = (product, _) => store.updates.add([
        store.applePurchase('conversion_purchase', product.id),
      ]);
      await AppReferBilling.configureForTesting(
        store: store,
        httpClient: server.client,
      );
      final product = (await AppReferBilling.products(['pro_yearly'])).single;
      expect(
        (await AppReferBilling.purchase(product)).outcome,
        PurchaseOutcome.purchased,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        requests.where((r) => r.url.path.endsWith('conversion-value')).length,
        1,
      );
    }, () => client);
  });
  test('a slow conversion response does not block configure', () async {
    final entered = Completer<void>();
    final finish = Completer<http.Response>();
    final slow = MockClient((r) async {
      if (r.url.path.endsWith('conversion-value')) {
        entered.complete();
        return finish.future;
      }
      return http.Response('{}', 200);
    });
    await http.runWithClient(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await AppReferSDK.configure(const AppReferConfig(apiKey: 'pk_test'));
      await entered.future;
      finish.complete(http.Response('{"fine":0,"coarse":"low"}', 200));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }, () => slow);
  });

  test('the 35 day boundary is included', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'apprefer_first_run_date',
      time.subtract(const Duration(days: 35)).toIso8601String(),
    );
    await refresh(force: true);
    expect(updates, [(0, 'low')]);
    expect(requests.length, 1);
    time = time.add(const Duration(milliseconds: 1));
    await refresh(force: true);
    expect(requests.length, 1);
  });
}
