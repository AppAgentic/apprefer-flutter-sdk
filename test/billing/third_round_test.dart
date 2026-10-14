import 'dart:async';
import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/billing/billing_storage.dart';
import 'package:apprefer/src/billing/pending_purchase_queue.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

const purchases = '/api/billing/v1/purchases';
const otherToken = '99999999-2222-4333-8444-555555555555';

/// SharedPreferences whose first write waits for [gate] and reports failure;
/// later writes succeed at once. Every write is logged.
class FirstWriteFails implements SharedPreferences {
  final SharedPreferences inner;
  final gate = Completer<void>();
  final writes = <String>[];

  FirstWriteFails(this.inner);

  @override
  String? getString(String key) => inner.getString(key);

  @override
  Future<bool> setString(String key, String value) async {
    writes.add(value);
    final first = writes.length == 1;
    await inner.setString(key, value);
    if (!first) return true;
    await gate.future;
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('upload network failure', () {
    test(
      'a working customer fetch gives the ownership-filtered answer',
      () async {
        final h = await Harness.create(appUserId: 'u2');
        h.server.handler = (r) {
          if (r.url.path == purchases) throw http.ClientException('reset');
          final user = r.method == 'GET'
              ? r.url.queryParameters['appUserId']!
              : (jsonDecode(r.body) as Map)['appUserId'] as String;
          return (200, customerJson(user));
        };
        // Another user's purchase on the device.
        h.store.entitlements = [
          activeSub(
            'pro_yearly',
            accountToken: otherToken,
            transactionId: 'tA',
          ),
        ];
        final info = await h.engine.process(h.store.applePurchase('t1', 'x'));
        expect(info.source, CustomerInfoSource.server);
        expect(info.entitlements['premium'], isNull);
        expect(h.queue.contains('t1'), isTrue);
      },
    );
  });

  group('queue durability tracks contents', () {
    test('a replaced entry is not durable until its save succeeds', () async {
      SharedPreferences.setMockInitialValues({});
      final flaky = FlakyPrefs(await SharedPreferences.getInstance());
      final queue = PendingPurchaseQueue(flaky, 'q');
      PendingPurchase entry(String user, {bool restore = false}) =>
          PendingPurchase(
            transactionId: 't1',
            productId: 'p',
            appUserId: user,
            appreferId: null,
            storeFields: {'store': 'app_store', 'signedTransaction': 'j_$user'},
            enqueuedAt: now,
            restore: restore,
          );
      expect(await queue.add(entry('u1')), isTrue);
      expect(queue.isDurable('t1'), isTrue);

      flaky.failWrites = true;
      expect(await queue.add(entry('u2', restore: true)), isFalse);
      expect(queue.entries.single.appUserId, 'u2');
      expect(queue.isDurable('t1'), isFalse);

      flaky.failWrites = false;
      expect(await queue.persist(), isTrue);
      expect(queue.isDurable('t1'), isTrue);
    });
  });

  group('identity writes', () {
    test('a failed stale write is not redone over a newer one', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = FirstWriteFails(await SharedPreferences.getInstance());
      final storage = BillingStorage(prefs);
      storage.loggedInAppUserId = 'old';
      final flushed = storage.flush();
      storage.loggedInAppUserId = 'new';
      prefs.gate.complete();
      expect(await flushed, isTrue);
      expect(storage.loggedInAppUserId, 'new');
      expect(prefs.writes, ['old', 'new']);
    });
  });
}
