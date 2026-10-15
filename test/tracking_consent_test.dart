import 'dart:convert';
import 'package:apprefer/src/apprefer_sdk.dart';
import 'package:apprefer/src/config.dart';
import 'package:apprefer/src/services/tracking_consent.dart';
import 'package:apprefer/src/services/http_client.dart';
import 'package:apprefer/src/services/logger.dart';
import 'package:apprefer/src/billing/billing_api_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  for (final entry in {
    'authorized': 'granted',
    'restricted': 'denied',
    'denied': 'denied',
    'notDetermined': 'undetermined',
    'unknown': 'undetermined',
  }.entries) {
    test('ATT mapping ${entry.key}', () {
      expect(TrackingConsent.mapStatus(entry.key), entry.value);
    });
  }

  test('persisted Android choice and legacy reset', () async {
    expect(await TrackingConsent.current(), isNull);
    await TrackingConsent.set(false);
    expect(await TrackingConsent.current(), 'denied');
    await TrackingConsent.set(true);
    expect(await TrackingConsent.current(), 'granted');
    await TrackingConsent.set(null);
    expect(await TrackingConsent.current(), isNull);
  });

  test(
    'per-request routing and no known-consent cross-host fallback',
    () async {
      final urls = <String>[];
      final fake = MockClient((r) async {
        urls.add(r.url.origin);
        return http.Response('{}', 403);
      });
      await http.runWithClient(() async {
        final client = AppReferHttpClient(
          baseUrl: 'https://trk.apprefer.com',
          fallbackUrl: 'https://apprefer.com',
          apiKey: 'pk',
          logger: AppReferLogger(debug: false, logLevel: 0),
        );
        await client.post('/api/track/event', {});
        expect(urls, ['https://trk.apprefer.com', 'https://apprefer.com']);
        for (final consent in ['denied', 'undetermined', 'granted']) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(TrackingConsent.consentKey, consent);
          urls.clear();
          await client.post('/api/track/event', {});
          expect(urls, TrackingConsent.hosts(consent, []));
          urls.clear();
          await client.get('/api/track/event');
          expect(urls, TrackingConsent.hosts(consent, []));
        }
      }, () => fake);
    },
  );

  test('billing chooses current consent with no cross-host fallback', () async {
    final urls = <String>[];
    final billing = BillingApiClient(
      baseUrls: const ['https://trk.apprefer.com', 'https://apprefer.com'],
      apiKey: () => 'pk',
      client: MockClient((r) async {
        urls.add(r.url.origin);
        return http.Response('{}', 503);
      }),
    );
    for (final consent in ['denied', 'undetermined', 'granted']) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(TrackingConsent.consentKey, consent);
      urls.clear();
      await expectLater(billing.send(const GetCustomer('u')), throwsException);
      expect(urls, TrackingConsent.hosts(consent, []));
    }
  });

  test(
    'change detection after first match, failure retry, cache refresh and PII gate',
    () async {
      final requests = <http.Request>[];
      var success = true;
      final fake = MockClient((r) async {
        requests.add(r);
        return http.Response(
          jsonEncode({
            'attribution': {'network': 'updated', 'matchType': 'organic'},
          }),
          success ? 200 : 403,
        );
      });
      await http.runWithClient(() async {
        await AppReferSDK.setTrackingConsent(false);
        await AppReferSDK.configure(const AppReferConfig(apiKey: 'pk'));
        expect(jsonDecode(requests.last.body)['tracking_consent'], 'denied');
        expect(jsonDecode(requests.last.body).containsKey('gaid'), false);
        requests.clear();
        await AppReferSDK.configure(const AppReferConfig(apiKey: 'pk'));
        expect(requests, isEmpty);
        await AppReferSDK.setAdvancedMatching(email: 'secret@example.com');
        expect(requests, isEmpty);
        success = false;
        await AppReferSDK.setTrackingConsent(true);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString(TrackingConsent.reportedKey), 'denied');
        success = true;
        await AppReferSDK.trackingConsentDidChange();
        expect(prefs.getString(TrackingConsent.reportedKey), 'granted');
        expect((await AppReferSDK.getAttribution())?.network, 'updated');
        expect(
          requests.every((r) => r.url.origin == 'https://trk.apprefer.com'),
          true,
        );
        requests.clear();
        await AppReferSDK.trackEvent('test');
        await AppReferSDK.setUserId('u');
        await Future<void>.delayed(Duration.zero);
        expect(requests.length, 2);
        expect(
          requests.every((r) => r.url.origin == 'https://trk.apprefer.com'),
          true,
        );
        // Activation is wired independently of configure/first-match.
        await prefs.setString(TrackingConsent.consentKey, 'denied');
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(prefs.getString(TrackingConsent.reportedKey), 'denied');
      }, () => fake);
    },
  );
}
