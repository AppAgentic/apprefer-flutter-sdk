import 'dart:convert';

import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/engagement/apprefer_engagement.dart'
    show engagementChannel, engagementStampKey;
import 'package:apprefer/src/engagement/engagement_client.dart';
import 'package:apprefer/src/services/http_client.dart';
import 'package:apprefer/src/services/logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory stand-in for AppRefer's engagement routes (web/lib/engagement).
class FakeServer {
  final installs = <String, Map<String, dynamic>>{};
  final calls = <http.Request>[];
  bool offline = false, disabled = false;
  final delays = <String, Duration>{};
  String receiptStatus = 'accepted';
  int _counter = 0;

  http.Client client() => MockClient((request) async {
    final delay = delays['${request.method} ${request.url.path}'];
    if (delay != null) await Future<void>.delayed(delay);
    calls.add(request);
    if (offline) throw http.ClientException('offline');
    final (status, body) = _handle(request);
    return http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );
  });

  (int, Map<String, dynamic>) _err(int s, String c) => (
    s,
    {
      'error': {'code': c},
    },
  );

  (int, Map<String, dynamic>) _handle(http.Request r) {
    if (disabled) return _err(404, 'ENGAGEMENT_DISABLED');
    final key = r.headers['X-AppRefer-Key'] ?? '';
    final body = r.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(r.body) as Map<String, dynamic>;
    if (r.method == 'POST' && r.url.path == '/api/engagement/v1/installs') {
      _counter++;
      final id = 'ei_${'a' * 25}${'234567'[_counter % 6]}';
      final secret = 'eis_${'S' * 42}${_counter % 10}';
      installs[id] = {
        'secret': secret,
        'key': key,
        'epoch': 0,
        'account': null,
        'prefs': {'marketing': false, 'reminders': false, 'service': true},
        'patches': <Map>[],
      };
      return (201, {'installId': id, 'installSecret': secret});
    }
    final cred = r.headers['X-AppRefer-Install'];
    if (cred == null) return _err(401, 'INVALID_INSTALL');
    final id = cred.split('.').first;
    final inst = installs[id];
    if (inst == null ||
        inst['secret'] != cred.substring(id.length + 1) ||
        inst['key'] != key)
      return _err(401, 'INVALID_INSTALL');
    Map<String, dynamic> me() => {
      'install': {'installId': id, 'accountEpoch': inst['epoch']},
    };
    Map<String, dynamic> prefs() => {
      'purposes': (inst['prefs'] as Map).map(
        (k, v) => MapEntry(k, {'granted': v}),
      ),
      'accountEpoch': inst['epoch'],
    };
    // Identity mutations must state the epoch they were made under (web/lib/engagement/identity.ts).
    final route = '${r.method} ${r.url.path}';
    final expected = body['expectedEpoch'];
    if (const [
          'PUT /api/engagement/v1/installs/me/preferences',
          'POST /api/engagement/v1/installs/me/logout',
          'POST /api/engagement/v1/installs/me/account',
        ].contains(route) &&
        expected is! int)
      return _err(400, 'INVALID_BODY');
    final stale = _err(409, 'IDENTITY_CHANGED');
    switch (route) {
      case 'GET /api/engagement/v1/installs/me':
        return (200, me());
      case 'PATCH /api/engagement/v1/installs/me':
        (inst['patches'] as List).add(body);
        return (200, me());
      case 'DELETE /api/engagement/v1/installs/me':
        installs.remove(id);
        return (200, {'deleted': true});
      case 'POST /api/engagement/v1/installs/me/account':
        final a = body['assertion'];
        if (a is! String || !a.startsWith('ok:'))
          return _err(401, 'INVALID_ASSERTION');
        if (inst['account'] != a.substring(3) && expected != inst['epoch'])
          return stale;
        if (inst['account'] != a.substring(3)) {
          inst['account'] = a.substring(3);
          inst['epoch'] = (inst['epoch'] as int) + 1;
          (inst['prefs'] as Map)
            ..['marketing'] = false
            ..['reminders'] = false;
        }
        return (200, {'accountEpoch': inst['epoch']});
      case 'POST /api/engagement/v1/installs/me/logout':
        if (expected != inst['epoch']) return stale;
        inst['account'] = null;
        inst['epoch'] = (inst['epoch'] as int) + 1;
        (inst['prefs'] as Map)
          ..['marketing'] = false
          ..['reminders'] = false;
        return (200, {'accountEpoch': inst['epoch']});
      case 'GET /api/engagement/v1/installs/me/preferences':
        return (200, prefs());
      case 'PUT /api/engagement/v1/installs/me/preferences':
        if (expected != inst['epoch']) return stale;
        body.forEach((k, v) {
          if (v is bool) (inst['prefs'] as Map)[k] = v;
        });
        return (200, prefs());
      case 'POST /api/engagement/v1/installs/me/receipts':
        return (
          200,
          {
            'results': [
              for (final x in body['receipts'] as List)
                {'messageId': x['messageId'], 'status': receiptStatus},
            ],
          },
        );
    }
    return _err(404, 'NOT_FOUND');
  }

  int count(String method, String path) =>
      calls.where((c) => c.method == method && c.url.path == path).length;

  /// The app's backend binds (null: detaches) directly; the SDK isn't told.
  void backendBind(String id, String? account) {
    final inst = installs[id]!;
    inst['account'] = account;
    inst['epoch'] = (inst['epoch'] as int) + 1;
    (inst['prefs'] as Map)
      ..['marketing'] = false
      ..['reminders'] = false;
  }

  Map<String, dynamic> lastBody(String method, String suffix) =>
      jsonDecode(
            calls
                .lastWhere(
                  (c) => c.method == method && c.url.path.endsWith(suffix),
                )
                .body,
          )
          as Map<String, dynamic>;
}

class MemPrefs implements EngagementPrefs {
  final map = <String, String>{};
  @override
  String? get(String key) => map[key];
  @override
  Future<void> set(String key, String? value) async =>
      value == null ? map.remove(key) : map[key] = value;
}

class MemSecure implements EngagementSecureStore {
  final map = <String, String>{};
  bool locked = false, failWrites = false;
  @override
  Future<SecureRead> read(String key) async => locked
      ? const SecureRead(SecureReadStatus.unavailable)
      : map[key] == null
      ? const SecureRead(SecureReadStatus.missing)
      : SecureRead(SecureReadStatus.found, map[key]);
  @override
  Future<bool> write(String key, String value) async {
    if (failWrites) return false;
    map[key] = value;
    return true;
  }

  @override
  Future<void> delete(String key) async => map.remove(key);
}

const key = 'pk_live_sparkly000000000000000001';
final token = 'er1.${'A' * 43}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeServer server;
  late MemSecure secure;
  late MemPrefs prefs;
  late List<(String?, int)> identity;

  setUp(() {
    server = FakeServer();
    secure = MemSecure();
    prefs = MemPrefs();
    identity = [];
  });

  EngagementClient client({DateTime Function()? now}) => EngagementClient(
    secure: secure,
    prefs: prefs,
    client: server.client,
    now: now,
    deviceState: () async => const EngagementDeviceState(
      timezone: 'Europe/London',
      locale: 'en-GB',
      collectionEnabled: true,
      permission: 'granted',
    ),
    deviceId: () async => 'dev-0000-0001',
    identitySink: (iid, epoch) async => identity.add((iid, epoch)),
    pushEnvironment: () async => 'sandbox',
  );

  group('client', () {
    test(
      'registers once and keeps the secret only in secure storage',
      () async {
        final c = client();
        final status = await c.start(key, explicit: true, images: true);
        expect(status.isActive, isTrue);
        final id = status.installId!;
        expect(server.count('POST', '/api/engagement/v1/installs'), 1);
        final reg = server.calls.firstWhere(
          (c) => c.url.path == '/api/engagement/v1/installs',
        );
        expect(reg.headers['X-AppRefer-Install'], isNull);
        expect(jsonDecode(reg.body)['deviceId'], 'dev-0000-0001');
        final secret = server.installs[id]!['secret'] as String;
        expect(secure.map.values.single, contains(secret));
        expect(prefs.map.values.any((v) => v.contains(secret)), isFalse);
        final patch = (server.installs[id]!['patches'] as List).last as Map;
        expect(patch['notificationPermission'], 'granted');
        expect(patch['capabilities'], {
          'schema': 1,
          'images': true,
          'actions': true,
        });
        expect(identity.last, (id, 0));
        expect((await client().start(key, explicit: true)).installId, id);
        expect(server.count('POST', '/api/engagement/v1/installs'), 1);
      },
    );

    test(
      'token sent once with the signing environment; unchanged state not resent',
      () async {
        final c = client();
        final id = (await c.start(key, explicit: true)).installId!;
        await c.setPushToken('ab' * 32);
        await c.setPushToken('ab' * 32);
        final patches = server.installs[id]!['patches'] as List;
        expect(patches, hasLength(2));
        expect((patches.last as Map)['pushEnvironment'], 'sandbox');
      },
    );

    test('disabled degrades quietly and is retried after six hours', () async {
      server.disabled = true;
      final c = client();
      expect(
        await c.start(key, explicit: true),
        AppReferEngagementStatus.disabled,
      );
      expect(secure.map, isEmpty);
      server.disabled = false;
      expect(
        await client().start(key, explicit: true),
        AppReferEngagementStatus.disabled,
      );
      expect(server.calls, hasLength(1));
      await expectLater(
        c.preferences(),
        throwsA(
          isA<AppReferEngagementException>().having(
            (e) => e.reason,
            'reason',
            AppReferEngagementErrorReason.notStarted,
          ),
        ),
      );
      final later = DateTime.now().add(const Duration(hours: 6, seconds: 1));
      expect(
        (await client(now: () => later).start(key, explicit: true)).isActive,
        isTrue,
      );
    });

    test(
      'locked storage and offline are pending, then recover; never a second install',
      () async {
        secure.locked = true;
        final c = client();
        expect(
          await c.start(key, explicit: true),
          AppReferEngagementStatus.pending,
        );
        expect(server.calls, isEmpty);
        secure.locked = false;
        server.offline = true;
        await c.becameActive();
        expect(c.status, AppReferEngagementStatus.pending);
        server.offline = false;
        await c.becameActive();
        expect(c.status.isActive, isTrue);
        expect(server.installs, hasLength(1));
      },
    );

    test('an unsaveable credential leaves no install behind', () async {
      secure.failWrites = true;
      expect(
        await client().start(key, explicit: true),
        AppReferEngagementStatus.pending,
      );
      expect(server.installs, isEmpty);
    });

    test(
      'an erased install is replaced once; a key switch uses its own slot',
      () async {
        final c = client();
        final a = (await c.start(key, explicit: false)).installId!;
        server.installs.remove(a);
        final b = (await client().start(key, explicit: false)).installId!;
        expect(b, isNot(a));
        await c.configurationChanged('pk_test_sparkly000000000000000001');
        expect(
          server.installs[c.status.installId]!['key'],
          'pk_test_sparkly000000000000000001',
        );
      },
    );

    test(
      'sign-in, logout and sign-in run in call order while in flight',
      () async {
        final c = client();
        final id = (await c.start(key, explicit: true)).installId!;
        server.delays['POST /api/engagement/v1/installs/me/account'] =
            const Duration(milliseconds: 150);
        final a = c.identify('ok:user-a');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final out = c.logout();
        final b = c.identify('ok:user-b');
        await Future.wait([a, out, b]);
        final order = server.calls
            .where(
              (r) =>
                  r.url.path.endsWith('/account') ||
                  r.url.path.endsWith('/logout'),
            )
            .map(
              (r) => r.url.path.endsWith('/logout')
                  ? 'logout'
                  : jsonDecode(r.body)['assertion'],
            )
            .toList();
        expect(order, ['ok:user-a', 'logout', 'ok:user-b']);
        expect(server.installs[id]!['account'], 'user-b');
        expect(c.stateForTesting().epoch, server.installs[id]!['epoch']);
      },
    );

    test(
      'a cold restart after a backend change never reuses the old stamp',
      () async {
        final c = client();
        final id = (await c.start(key, explicit: true)).installId!;
        await c.identify('ok:user-a');
        final underA = c.snapshot!;
        server.backendBind(id, 'user-b'); // while the app isn't running
        final restarted = client();
        await restarted.start(key, explicit: true);
        final underB = restarted.snapshot!;
        expect(underB.accountEpoch, 2);
        expect(underB.serial, greaterThan(underA.serial));
        expect(underB.stamp, isNot(underA.stamp));
        server.backendBind(id, null); // to anonymous
        final again = client();
        await again.start(key, explicit: true);
        expect(again.snapshot!.serial, greaterThan(underB.serial));
        expect(again.snapshot!.stamp, isNot(underB.stamp));
        final same = client();
        await same.start(key, explicit: true);
        expect(
          same.snapshot!.stamp,
          again.snapshot!.stamp,
          reason: 'nothing changed',
        );
        server.installs.remove(id); // erased: replaced
        final replaced = client();
        await replaced.start(key, explicit: true);
        expect(replaced.snapshot!.installId, isNot(id));
        expect(replaced.snapshot!.stamp, isNot(same.snapshot!.stamp));
      },
    );

    test(
      'preferences state their epoch and are refused for the next account',
      () async {
        final c = client();
        final id = (await c.start(key, explicit: true)).installId!;
        await c.identify('ok:user-a');
        await c.preferences();
        server.backendBind(id, 'user-b');
        await expectLater(
          c.setPreferences({'marketing': true}),
          throwsA(
            isA<AppReferEngagementException>().having(
              (e) => e.reason,
              'reason',
              AppReferEngagementErrorReason.identityChanged,
            ),
          ),
        );
        expect(server.lastBody('PUT', '/preferences')['expectedEpoch'], 1);
        expect(
          (server.installs[id]!['prefs'] as Map)['marketing'],
          isFalse,
          reason: "A's cached choice never reaches B",
        );
        await c.setPreferences({'marketing': true});
        expect(server.lastBody('PUT', '/preferences')['expectedEpoch'], 2);
        expect((server.installs[id]!['prefs'] as Map)['marketing'], isTrue);
      },
    );

    test('reading preferences learns their epoch', () async {
      final c = client();
      final id = (await c.start(key, explicit: true)).installId!;
      final before = c.snapshot!.serial;
      server.backendBind(id, 'user-b');
      await c.preferences();
      expect(c.snapshot!.accountEpoch, 1);
      expect(c.snapshot!.serial, greaterThan(before));
    });

    test('a stale logout never detaches the next account', () async {
      final c = client();
      final id = (await c.start(key, explicit: true)).installId!;
      await c.identify('ok:user-a');
      server.offline = true;
      await c.logout(); // saved for epoch 1
      server.offline = false;
      server.backendBind(id, 'user-b');
      await client().start(key, explicit: true);
      expect(server.lastBody('POST', '/logout')['expectedEpoch'], 1);
      expect(
        server.installs[id]!['account'],
        'user-b',
        reason: 'refused (409): B stays bound',
      );
      expect(
        client().stateForTesting().pendingLogout,
        isFalse,
        reason: 'settled, not retried forever',
      );
    });

    group('pending logout target', () {
      final slot = EngagementClient.slotFor(key);

      test('an offline logout is saved as one value for its install', () async {
        final c = client();
        final id = (await c.start(key, explicit: true)).installId!;
        await c.identify('ok:user-a');
        server.offline = true;
        await c.logout();
        expect(prefs.map['apprefer_engagement_pending_logout_target_$slot'], '$id:1');
        expect(
          prefs.map['apprefer_engagement_pending_logout_$slot'],
          isNull,
          reason: 'no separate flag that a crash could strand',
        );
        expect(prefs.map['apprefer_engagement_pending_logout_epoch_$slot'], isNull);
        server.offline = false;
        await client().start(key, explicit: true);
        expect(server.lastBody('POST', '/logout')['expectedEpoch'], 1);
        expect(server.installs[id]!['account'], isNull);
        expect(prefs.map['apprefer_engagement_pending_logout_target_$slot'], isNull);
      });

      test(
        'an interrupted two-value logout signs out only the persisted epoch',
        () async {
          final c = client();
          final id = (await c.start(key, explicit: true)).installId!;
          await c.identify('ok:user-a'); // epoch 1, persisted with the install id
          // An earlier build crashed between its two writes: the flag without its epoch.
          prefs.map['apprefer_engagement_pending_logout_$slot'] = '1';
          server.backendBind(id, 'user-b'); // epoch 2 while the app wasn't running
          final restarted = client();
          await restarted.start(key, explicit: true);
          final logouts = server.calls
              .where((r) => r.url.path.endsWith('/logout'))
              .map((r) => (jsonDecode(r.body) as Map)['expectedEpoch'])
              .toList();
          expect(logouts, [1], reason: 'aimed at the persisted epoch, never the fresh one');
          expect(server.installs[id]!['account'], 'user-b');
          expect(restarted.snapshot!.accountEpoch, 2);
          expect(restarted.stateForTesting().pendingLogout, isFalse);
          expect(prefs.map['apprefer_engagement_pending_logout_$slot'], isNull);
        },
      );

      test(
        "a retained credential without its epoch never detaches the server's identity",
        () async {
          final first = client();
          final id = (await first.start(key, explicit: true)).installId!;
          await first.identify('ok:user-a');
          // Reinstall: the Keychain credential survives, the prefs (the epoch) do not.
          prefs.map.clear();
          server.backendBind(id, 'user-b');
          final reinstalled = client();
          await reinstalled.logout(); // reset() before start
          await reinstalled.start(key, explicit: true);
          expect(
            server.count('POST', '/api/engagement/v1/installs/me/logout'),
            0,
            reason: 'no target known: dropped',
          );
          expect(server.installs[id]!['account'], 'user-b');
          expect(reinstalled.snapshot!.accountEpoch, 2);
          expect(prefs.map['apprefer_engagement_pending_logout_any'], isNull);
          // Started but never verified (offline), then a logout: nothing saved or sent later.
          prefs.map.clear();
          server.offline = true;
          final offline = client();
          expect(
            await offline.start(key, explicit: true),
            AppReferEngagementStatus.pending,
          );
          await offline.logout();
          server.offline = false;
          server.backendBind(id, 'user-c');
          await client().start(key, explicit: true);
          expect(server.count('POST', '/api/engagement/v1/installs/me/logout'), 0);
          expect(server.installs[id]!['account'], 'user-c');
        },
      );
    });

    test(
      'a sign-in started under an old identity does not replace the new one',
      () async {
        final c = client();
        final id = (await c.start(key, explicit: true)).installId!;
        server.backendBind(id, 'user-b');
        await expectLater(
          c.identify('ok:user-a'),
          throwsA(
            isA<AppReferEngagementException>().having(
              (e) => e.reason,
              'reason',
              AppReferEngagementErrorReason.identityChanged,
            ),
          ),
        );
        expect(server.lastBody('POST', '/account')['expectedEpoch'], 0);
        expect(server.installs[id]!['account'], 'user-b');
        expect(c.snapshot!.accountEpoch, 1);
      },
    );

    test('deferred events recheck the real clock and identity', () {
      const snap = EngagementSnapshot('s', 'ei_x', 2, 1, 'h', null);
      const open = AppReferEngagementNotificationEvent(
        kind: 'opened',
        messageId: 'm',
        purpose: 'reminders',
        destination: '/x',
      );
      const dismissed = AppReferEngagementNotificationEvent(
        kind: 'dismissed',
        messageId: 'm',
        purpose: 'reminders',
      );
      Map raw(int? exp, [int epoch = 2]) => {
        if (exp != null) 'expiresAt': exp,
        'installId': 'ei_x',
        'accountEpoch': epoch,
      };
      const now = 1000000;
      expect(
        AppReferEngagement.stillDeliverable(open, raw(now + 1), snap, now),
        isTrue,
      );
      expect(
        AppReferEngagement.stillDeliverable(open, raw(now + 1), snap, now + 1),
        isFalse,
        reason: 'expired while waiting',
      );
      expect(
        AppReferEngagement.stillDeliverable(
          dismissed,
          raw(now + 1),
          snap,
          now + 2,
        ),
        isFalse,
      );
      expect(
        AppReferEngagement.stillDeliverable(open, raw(null), snap, now),
        isFalse,
        reason: 'no expiry: never navigates',
      );
      expect(
        AppReferEngagement.stillDeliverable(dismissed, raw(null), snap, now),
        isTrue,
        reason: 'extension markers carry no expiry',
      );
      expect(
        AppReferEngagement.stillDeliverable(open, raw(now + 1, 1), snap, now),
        isFalse,
      );
      expect(
        AppReferEngagement.stillDeliverable(open, raw(now + 1), null, now),
        isFalse,
      );
    });

    test('logout during registration is sent after it', () async {
      server.delays['POST /api/engagement/v1/installs'] = const Duration(
        milliseconds: 120,
      );
      final c = client();
      final started = c.start(key, explicit: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await c.logout();
      final id = (await started).installId!;
      expect(server.count('POST', '/api/engagement/v1/installs/me/logout'), 1);
      expect(server.installs[id]!['epoch'], 1);
    });

    test(
      'offline logout blocks matching and is sent first next time; reset before start too',
      () async {
        final c = client();
        final id = (await c.start(key, explicit: true)).installId!;
        await c.identify('ok:user-a');
        server.offline = true;
        await c.logout();
        expect(c.stateForTesting().pendingLogout, isTrue);
        expect(c.snapshot!.accountEpoch, isNull);
        expect(identity.last, (id, -1));
        server.offline = false;
        await client().start(key, explicit: true);
        expect(server.installs[id]!['account'], isNull);

        final again = client();
        await again.start(key, explicit: true);
        await again.identify('ok:user-c');
        final next = client();
        await next
            .logout(); // AppReferSDK.reset() before engagement started this launch
        expect(server.installs[id]!['account'], 'user-c');
        await next.start(key, explicit: true);
        expect(server.installs[id]!['account'], isNull);
      },
    );

    test('invalid assertion and preferences belong to the identity', () async {
      final c = client();
      final id = (await c.start(key, explicit: true)).installId!;
      await expectLater(
        c.identify('forged'),
        throwsA(
          isA<AppReferEngagementException>().having(
            (e) => e.reason,
            'reason',
            AppReferEngagementErrorReason.invalidAssertion,
          ),
        ),
      );
      expect(c.stateForTesting().epoch, 0);
      await c.identify('ok:user-a');
      expect((await c.setPreferences({'marketing': true})).marketing, isTrue);
      await c.logout();
      expect((server.installs[id]!['prefs'] as Map)['marketing'], isFalse);
      server.offline = true;
      await c.logout();
      server.offline = false;
      await expectLater(
        c.setPreferences({'marketing': true}),
        throwsA(
          isA<AppReferEngagementException>().having(
            (e) => e.reason,
            'reason',
            AppReferEngagementErrorReason.identityChanged,
          ),
        ),
      );
    });

    test(
      'receipts only for the current identity, dropped on change, final once answered',
      () async {
        final c = client();
        final id = (await c.start(key, explicit: true)).installId!;
        final now = DateTime.now().millisecondsSinceEpoch;
        await c.queueReceipt(
          kind: 'opened',
          messageId: 'sparkly_live_j_a_nudge',
          token: token,
          installId: id,
          accountEpoch: 0,
          at: now,
        );
        final sent =
            jsonDecode(
                  server.calls
                      .lastWhere((r) => r.url.path.endsWith('/receipts'))
                      .body,
                )['receipts']
                as List;
        expect(sent.single, containsPair('token', token));
        expect(c.pendingReceiptCount, 0);
        await c.queueReceipt(
          kind: 'opened',
          messageId: 'sparkly_live_j_b_nudge',
          token: token,
          installId: id,
          accountEpoch: 7,
          at: now,
        );
        expect(
          server.count('POST', '/api/engagement/v1/installs/me/receipts'),
          1,
          reason: 'another epoch is never queued',
        );
        server.offline = true;
        await c.queueReceipt(
          kind: 'opened',
          messageId: 'sparkly_live_j_c_nudge',
          token: token,
          installId: id,
          accountEpoch: 0,
          at: now,
        );
        expect(c.pendingReceiptCount, 1);
        server.offline = false;
        await c.identify('ok:user-b');
        expect(
          c.pendingReceiptCount,
          0,
          reason: 'never sent under the next account',
        );
        server.receiptStatus = 'rejected';
        await c.queueReceipt(
          kind: 'dismissed',
          messageId: 'sparkly_live_j_d_nudge',
          token: token,
          installId: id,
          accountEpoch: c.snapshot!.accountEpoch!,
          at: now,
        );
        expect(c.pendingReceiptCount, 0);
      },
    );

    test('offline delete is retried before a fresh registration', () async {
      final c = client();
      final id = (await c.start(key, explicit: true)).installId!;
      server.offline = true;
      await c.deleteInstall();
      expect(c.status, AppReferEngagementStatus.pending);
      expect(c.snapshot, isNull);
      server.offline = false;
      final fresh = (await client().start(key, explicit: true)).installId!;
      expect(server.installs.containsKey(id), isFalse);
      expect(fresh, isNot(id));
    });
  });

  group('payload', () {
    Map<String, dynamic> object([Map<String, Object?> overrides = const {}]) =>
        {
          'type': 'engagement',
          'v': 1,
          'mid': 'sparkly_live_finish-setup_abc_nudge',
          'purpose': 'reminders',
          'exp': DateTime.now().millisecondsSinceEpoch + 3600000,
          'epoch': 2,
          'iid': 'ei_${'a' * 26}',
          'dest': '/setup',
          'title': 'Finish Garden',
          'body': 'One step left.',
          'rt': token,
          'actions': [
            {'id': 'start', 'kind': 'start', 'dest': '/setup/next'},
            {'id': 'later', 'kind': 'snooze', 'min': 60},
          ],
          ...overrides,
        }..removeWhere((k, v) => v == #remove);
    String? reason(Map<String, dynamic> o) {
      try {
        AppReferEngagementPayload.parseObject(o);
        return null;
      } on FormatException catch (e) {
        return e.message;
      }
    }

    test('FCM data map and APNs userInfo; Support is not engagement', () {
      final fcm = AppReferEngagementPayload.parse({
        'type': 'engagement',
        'v': '1',
        'engagement': jsonEncode(object()),
      })!;
      expect(fcm.actions.map((a) => a.kind), ['start', 'snooze']);
      expect(
        AppReferEngagementPayload.parse({'apprefer': object()})!.installId,
        'ei_${'a' * 26}',
      );
      expect(
        AppReferEngagementPayload.parse({
          'type': 'support_reply',
          'conversationId': 'cv_1',
        }),
        isNull,
      );
      expect(
        AppReferEngagementPayload.parse({
          'apprefer': {'type': 'support_reply'},
        }),
        isNull,
      );
      expect(
        () => AppReferEngagementPayload.parse({
          'type': 'engagement',
          'engagement': '{bad',
        }),
        throwsFormatException,
      );
    });

    test('strict validation', () {
      expect(reason(object({'v': 2})), 'unsupported_version');
      expect(reason(object({'v': true})), 'unsupported_version');
      expect(reason(object({'mid': 'a/b'})), 'message_id');
      expect(reason(object({'epoch': 1.5})), 'epoch');
      expect(reason(object({'iid': 'ei_x'})), 'install');
      expect(reason(object({'rt': 'x'})), 'receipt_token');
      for (final bad in [
        'https://evil.example/x',
        '//evil.example/x',
        'javascript:x',
        'setup',
      ]) {
        expect(reason(object({'dest': bad})), 'destination', reason: bad);
      }
      for (final bad in [
        'http://assets.example.com/a.png',
        'https://10.0.0.1/a.png',
        'https://assets.example.com:8443/a.png',
        'https://assets.example.com/a.png?x',
        'https://assets.example.com/../a.png',
        'https://localhost/a.png',
      ]) {
        expect(reason(object({'img': bad})), 'image', reason: bad);
      }
      expect(
        reason(
          object({
            'actions': [
              {'id': 'a', 'kind': 'open'},
              {'id': 'b', 'kind': 'open'},
            ],
          }),
        ),
        'actions',
      );
      expect(
        reason(
          object({
            'actions': [
              {'id': 'a', 'kind': 'snooze', 'min': 2},
            ],
          }),
        ),
        'actions',
      );
      expect(
        AppReferEngagementPayload.parseObject(
          object({'exp': DateTime.now().millisecondsSinceEpoch - 1}),
        ).isExpired(),
        isTrue,
      );
    });
  });

  group('facade', () {
    late List<MethodCall> nativeCalls;
    late List<Map<String, Object?>> nativeEvents;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      nativeCalls = [];
      nativeEvents = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(engagementChannel, (call) async {
            nativeCalls.add(call);
            if (call.method == 'takeEvents') {
              final out = List.of(nativeEvents);
              nativeEvents.clear();
              return out;
            }
            if (call.method == 'permission') return 'granted';
            return null;
          });
    });
    tearDown(() => AppReferEngagement.setClientForTesting(null));

    Map<String, Object?> event(
      String kind,
      String iid,
      int epoch, {
      String? dest,
      String mid = 'sparkly_live_j_x_nudge',
    }) => {
      'kind': kind,
      'messageId': mid,
      'purpose': 'reminders',
      'installId': iid,
      'accountEpoch': epoch,
      'receiptToken': token,
      'at': DateTime.now().millisecondsSinceEpoch,
      // Both natives record the notification's expiry with every event.
      'expiresAt': DateTime.now().millisecondsSinceEpoch + 3600000,
      if (dest != null) 'destination': dest,
    };

    test(
      'start registers buttons and channels in the app language and mirrors the identity natively',
      () async {
        final c = client();
        AppReferEngagement.setClientForTesting(c);
        final status = await AppReferEngagement.instance.start(apiKey: key);
        expect(status.isActive, isTrue);
        final configure =
            nativeCalls
                    .firstWhere((m) => m.method == 'configureNotifications')
                    .arguments
                as Map;
        expect((configure['labels'] as Map)['snooze'], 'Remind me later');
        expect(
          (configure['channels'] as Map)['service'],
          'Account and billing',
        );
      },
    );

    test(
      'navigation waits for readiness, is delivered once and dropped after an account change',
      () async {
        final c = client();
        AppReferEngagement.setClientForTesting(c);
        final id = (await AppReferEngagement.instance.start(
          apiKey: key,
        )).installId!;
        final delivered = <AppReferEngagementNotificationEvent>[];
        AppReferEngagement.instance.onNotificationEvent = delivered.add;
        nativeEvents.add(event('opened', id, 0, dest: '/setup'));
        nativeEvents.add(
          event('dismissed', id, 0, mid: 'sparkly_live_j_y_nudge'),
        );
        await AppReferEngagement.instance.drain();
        expect(
          delivered.map((e) => e.kind),
          ['dismissed'],
          reason: 'not navigation: no readiness needed',
        );
        AppReferEngagement.instance.setNavigationReady(true);
        expect(delivered.map((e) => e.kind), ['dismissed', 'opened']);
        expect(delivered.last.destination, '/setup');
        AppReferEngagement.instance.setNavigationReady(true);
        expect(delivered, hasLength(2));

        // A tap for the previous identity, drained after sign-in, never navigates.
        AppReferEngagement.instance.setNavigationReady(false);
        nativeEvents.add(
          event('opened', id, 0, dest: '/old', mid: 'sparkly_live_j_z_nudge'),
        );
        await AppReferEngagement.instance.drain();
        await c.identify('ok:user-a');
        AppReferEngagement.instance.setNavigationReady(true);
        expect(delivered, hasLength(2));
        // Unsafe destinations are dropped (the app opens its default screen).
        nativeEvents.add(
          event(
            'opened',
            id,
            c.snapshot!.accountEpoch!,
            dest: 'https://evil.example',
            mid: 'sparkly_live_j_w_nudge',
          ),
        );
        await AppReferEngagement.instance.drain();
        expect(delivered.last.destination, isNull);
      },
    );

    test('logout clears what waits natively and in Dart', () async {
      AppReferEngagement.setClientForTesting(client());
      final id = (await AppReferEngagement.instance.start(
        apiKey: key,
      )).installId!;
      nativeEvents.add(event('opened', id, 0, dest: '/setup'));
      await AppReferEngagement.instance.drain();
      await AppReferEngagement.instance.logout();
      expect(
        nativeCalls.map((c) => c.method),
        contains('clearForAccountChange'),
      );
      final delivered = <AppReferEngagementNotificationEvent>[];
      AppReferEngagement.instance.onNotificationEvent = delivered.add;
      AppReferEngagement.instance.setNavigationReady(true);
      expect(delivered, isEmpty);
    });

    test('Support and foreign messages are not taken', () async {
      AppReferEngagement.setClientForTesting(client());
      expect(
        await AppReferEngagement.instance.handleMessage({
          'type': 'support_reply',
          'conversationId': 'cv_1',
        }),
        isFalse,
      );
      expect(
        await AppReferEngagement.instance.handleMessage({'title': 'x'}),
        isFalse,
      );
      expect(nativeCalls.where((c) => c.method == 'showNotification'), isEmpty);
    });

    test(
      'a tracked event carries the header only while its stamp is current; the stamp never leaves',
      () async {
        final c = client();
        AppReferEngagement.setClientForTesting(c);
        await AppReferEngagement.instance.start(
          apiKey: key,
          options: const AppReferEngagementOptions(
            trackedEvents: {'setup_started'},
          ),
        );
        final stamp = AppReferEngagement.instance.eventStamp(
          'setup_started',
          key,
        );
        expect(stamp, isNotNull);
        expect(
          AppReferEngagement.instance.eventStamp('paywall_viewed', key),
          isNull,
        );
        expect(
          AppReferEngagement.instance.eventStamp('_set_user_id', key),
          isNull,
        );
        expect(
          AppReferEngagement.instance.eventStamp(
            'setup_started',
            'pk_live_other0000000000000000001',
          ),
          isNull,
        );
        final sent = <http.Request>[];
        await http.runWithClient(
          () async {
            final transport = AppReferHttpClient(
              baseUrl: 'https://apprefer.test',
              apiKey: key,
              logger: AppReferLogger(),
            );
            await transport.eventResponse({
              'event_name': 'setup_started',
              engagementStampKey: stamp,
            });
            await c.logout();
            await transport.eventResponse({
              'event_name': 'setup_started',
              engagementStampKey: stamp,
            });
          },
          () => MockClient((r) async {
            sent.add(r);
            return http.Response('{}', 200);
          }),
        );
        expect(sent.first.headers['X-AppRefer-Install'], startsWith('ei_'));
        expect(sent.first.headers['X-AppRefer-Install-Epoch'], '0');
        expect(
          sent.last.headers['X-AppRefer-Install'],
          isNull,
          reason: 'identity moved on',
        );
        for (final r in sent) {
          expect(
            (jsonDecode(r.body) as Map).containsKey(engagementStampKey),
            isFalse,
          );
        }
      },
    );
  });
}
