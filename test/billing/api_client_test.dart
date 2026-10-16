import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import 'package:apprefer/src/billing/billing_api_client.dart';
import 'package:apprefer/src/billing/billing_error.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

BillingApiClient client(
  FakeServer server, {
  String? Function()? apiKey,
  int keyWaitAttempts = 0,
}) => BillingApiClient(
  baseUrls: const ['https://trk.example.com', 'https://example.com'],
  apiKey: apiKey ?? () => 'pk_test_1',
  client: server.client,
  keyWaitAttempts: keyWaitAttempts,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  group('request building', () {
    test('create customer', () {
      final r = BillingApiClient.makeRequest(
        const CreateCustomer(r'$ARAnon:ABC', 'device-1', {
          r'$email': 'a@b.com',
        }),
        'https://trk.example.com',
        'pk_1',
      );
      expect(r.method, 'POST');
      expect(
        r.url.toString(),
        'https://trk.example.com/api/billing/v1/customers',
      );
      expect(r.headers['X-AppRefer-Key'], 'pk_1');
      expect(r.headers['Content-Type'], 'application/json');
      expect(r.headers['X-SDK-Version'], isNotEmpty);
      expect(jsonDecode(r.body), {
        'appUserId': r'$ARAnon:ABC',
        'appreferId': 'device-1',
        'attributes': {r'$email': 'a@b.com'},
      });
    });

    test('create customer omits empty optional fields', () {
      final r = BillingApiClient.makeRequest(
        const CreateCustomer('u1', null, {}),
        'https://x.com',
        'k',
      );
      expect(jsonDecode(r.body), {'appUserId': 'u1'});
    });

    test('get customer encodes anonymous id and plus', () {
      final r = BillingApiClient.makeRequest(
        const GetCustomer(r'$ARAnon:A+B c'),
        'https://x.com',
        'k',
      );
      expect(r.method, 'GET');
      expect(r.url.query, 'appUserId=%24ARAnon%3AA%2BB+c');
      expect(r.url.queryParameters['appUserId'], r'$ARAnon:A+B c');
      expect(r.body, isEmpty);
    });

    test('iOS purchase', () {
      final r = BillingApiClient.makeRequest(
        const RecordPurchase('u1', 'device-1', {
          'store': 'app_store',
          'signedTransaction': 'jws',
        }, {}),
        'https://x.com',
        'k',
      );
      expect(r.url.path, '/api/billing/v1/purchases');
      expect(jsonDecode(r.body), {
        'appUserId': 'u1',
        'appreferId': 'device-1',
        'store': 'app_store',
        'signedTransaction': 'jws',
      });
    });

    test('Android purchase', () {
      final r = BillingApiClient.makeRequest(
        const RecordPurchase(
          'u1',
          null,
          {
            'store': 'play_store',
            'purchaseToken': 'tok',
            'productId': 'coins',
            'productType': 'consumable',
          },
          {r'$email': 'a@b.com'},
        ),
        'https://x.com',
        'k',
      );
      expect(jsonDecode(r.body), {
        'appUserId': 'u1',
        'store': 'play_store',
        'purchaseToken': 'tok',
        'productId': 'coins',
        'productType': 'consumable',
        'attributes': {r'$email': 'a@b.com'},
      });
    });

    test('identify', () {
      final r = BillingApiClient.makeRequest(
        const Identify(r'$ARAnon:X', 'u1'),
        'https://x.com',
        'k',
      );
      expect(r.url.path, '/api/billing/v1/identify');
      expect(jsonDecode(r.body), {
        'anonymousId': r'$ARAnon:X',
        'appUserId': 'u1',
        'link': true,
      });
    });
  });

  group('sending', () {
    test('falls back to main host when tracking host is down', () async {
      final server = FakeServer((r) {
        if (r.url.host == 'trk.example.com') throw Exception('dns');
        return (200, customerJson('u1'));
      });
      final res = await client(server).send(const GetCustomer('u1'));
      expect(res.info.appUserId, 'u1');
      expect(res.accountToken, token);
      expect(server.requests.map((r) => r.url.host), [
        'trk.example.com',
        'example.com',
      ]);
    });

    test('falls back on 5xx', () async {
      final server = FakeServer(
        (r) => r.url.host == 'trk.example.com'
            ? (502, {'error': 'bad gateway'})
            : (200, customerJson('u1')),
      );
      final res = await client(server).send(const GetCustomer('u1'));
      expect(res.info.appUserId, 'u1');
      expect(server.requests, hasLength(2));
    });

    test('client error is final and not retried', () async {
      final server = FakeServer((_) => (422, {'error': 'bad'}));
      await expectLater(
        client(server).send(const GetCustomer('u1')),
        throwsA(
          isA<AppReferBillingException>()
              .having((e) => e.status, 'status', 422)
              .having((e) => e.message, 'message', 'bad')
              .having((e) => e.isRetryable, 'retryable', false),
        ),
      );
      expect(server.requests, hasLength(1));
    });

    test('all hosts down throws a retryable connectivity error', () async {
      final server = FakeServer();
      await expectLater(
        client(server).send(const GetCustomer('u1')),
        throwsA(
          isA<AppReferBillingException>()
              .having((e) => e.code, 'code', AppReferBillingErrorCode.network)
              .having((e) => e.isRetryable, 'retryable', true)
              .having((e) => e.isConnectivity, 'connectivity', true),
        ),
      );
      expect(server.requests, hasLength(2));
    });

    test('unreadable 2xx body is invalidResponse', () async {
      final server = FakeServer((_) => (200, ['not', 'an', 'object']));
      await expectLater(
        client(server).send(const GetCustomer('u1')),
        throwsA(
          isA<AppReferBillingException>().having(
            (e) => e.code,
            'code',
            AppReferBillingErrorCode.invalidResponse,
          ),
        ),
      );
    });

    test('missing api key makes no request', () async {
      final server = FakeServer((_) => (200, customerJson('u1')));
      await expectLater(
        client(server, apiKey: () => null).send(const GetCustomer('u1')),
        throwsA(
          isA<AppReferBillingException>().having(
            (e) => e.code,
            'code',
            AppReferBillingErrorCode.missingApiKey,
          ),
        ),
      );
      expect(server.requests, isEmpty);
    });

    test('waits briefly for the api key from AppReferSDK.configure', () async {
      final server = FakeServer((_) => (200, customerJson('u1')));
      String? key;
      Future<void>.delayed(
        const Duration(milliseconds: 150),
        () => key = 'pk_late',
      );
      final res = await client(
        server,
        apiKey: () => key,
        keyWaitAttempts: 10,
      ).send(const GetCustomer('u1'));
      expect(res.info.appUserId, 'u1');
      expect(server.requests.single.headers['X-AppRefer-Key'], 'pk_late');
    });
  });

  test('retryable classification', () {
    AppReferBillingException server(int s) =>
        AppReferBillingException(AppReferBillingErrorCode.server, status: s);
    for (final s in [400, 413, 422]) {
      expect(server(s).isRetryable, isFalse, reason: '$s');
    }
    for (final s in [401, 404, 409, 429, 500, 503]) {
      expect(server(s).isRetryable, isTrue, reason: '$s');
    }
    expect(server(503).isConnectivity, isTrue);
    expect(server(404).isConnectivity, isFalse);
    expect(
      const AppReferBillingException(
        AppReferBillingErrorCode.invalidAppUserId,
      ).isRetryable,
      isFalse,
    );
  });
}
