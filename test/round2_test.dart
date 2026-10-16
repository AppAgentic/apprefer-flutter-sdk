import 'dart:async';
import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/services/event_queue.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await AppReferSDK.disposeForTesting();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await AppReferSDK.disposeForTesting();
  });
  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'failed revocations stay saved across restart until session DELETE succeeds',
    () async {
      final slots = <String, String>{
        'support_pk.token': 'A',
        'support_pk.push': 'push-A',
      };
      SupportAPI api(bool ok, List<String> paths) => SupportAPI(
        apiKey: () => 'pk',
        read: (k) async => slots[k],
        write: (k, v) async {
          if (v == null) {
            slots.remove(k);
          } else {
            slots[k] = v;
          }
        },
        keys: () async => slots.keys.toList(),
        client: MockClient((r) async {
          paths.add(r.url.path);
          return http.Response('{}', ok ? 200 : 503);
        }),
      );
      final failed = api(false, []);
      await failed.reset();
      await settle();
      expect(slots['support_pk.token'], isNull);
      expect(jsonDecode(slots['apprefer_revocations']!), hasLength(1));
      final paths = <String>[];
      api(true, paths).resumeRevocations();
      await settle();
      expect(paths.map((p) => p.split('/').last), ['session']);
      expect(jsonDecode(slots['apprefer_revocations']!), isEmpty);
    },
  );
  test(
    'key enumeration and slot errors do not poison reset or later Support calls',
    () async {
      final slots = <String, String>{
        'support_pk.token': 'A',
        'apprefer_revocations': '{corrupt',
      };
      final api = SupportAPI(
        apiKey: () => 'pk',
        read: (k) async => slots[k],
        write: (k, v) async {
          if (k.endsWith('.token') && v == null) throw StateError('slot');
          if (v == null) {
            slots.remove(k);
          } else {
            slots[k] = v;
          }
        },
        keys: () async => throw StateError('locked'),
        profile: () async => {},
        client: MockClient(
          (r) async => http.Response(
            r.method == 'POST' ? '{"session":"B"}' : '{"conversations":[]}',
            200,
          ),
        ),
      );
      await api.reset();
      expect(slots['support_pk.token'], 'A');
      expect(await api.conversations(), isEmpty);
      expect(slots['support_pk.token'], 'B');
    },
  );
  test(
    'pending with unchanged consent resolves on the next configure',
    () async {
      var finalized = false;
      await http.runWithClient(
        () async {
          expect(
            (await AppReferSDK.configureResult(
              const AppReferConfig(apiKey: 'pk_pending'),
            )).status,
            AttributionStatus.pending,
          );
          finalized = true;
          expect(
            (await AppReferSDK.configureResult(
              const AppReferConfig(apiKey: 'pk_pending'),
            )).status,
            AttributionStatus.attributed,
          );
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'attribution': {
                'network': finalized ? 'meta' : 'organic',
                'matchType': 'click',
                'trackingDecisionPending': !finalized,
              },
            }),
            200,
          ),
        ),
      );
    },
  );
  test('AdServices is attributed with a retained pending flag', () async {
    await http.runWithClient(
      () async {
        expect(
          (await AppReferSDK.configureResult(
            const AppReferConfig(apiKey: 'pk_asa'),
          )).status,
          AttributionStatus.attributed,
        );
      },
      () => MockClient(
        (_) async => http.Response(
          '{"attribution":{"network":"apple_search_ads","matchType":"adservices","trackingDecisionPending":true}}',
          200,
        ),
      ),
    );
  });
  test('two configure calls and configureResult share one request', () async {
    final started = Completer<void>(), finish = Completer<http.Response>();
    var calls = 0;
    await http.runWithClient(
      () async {
        final first = AppReferSDK.configure(
          const AppReferConfig(apiKey: 'pk_double'),
        );
        await started.future;
        final second = AppReferSDK.configure(
          const AppReferConfig(apiKey: 'pk_double'),
        );
        final result = AppReferSDK.configureResult(
          const AppReferConfig(apiKey: 'pk_double'),
        );
        finish.complete(
          http.Response(
            '{"attribution":{"network":"meta","matchType":"click"}}',
            200,
          ),
        );
        expect((await first)?.network, 'meta');
        expect((await second)?.network, 'meta');
        expect((await result).status, AttributionStatus.attributed);
        expect(calls, 1);
      },
      () => MockClient((_) async {
        calls++;
        if (!started.isCompleted) started.complete();
        return finish.future;
      }),
    );
  });
  test('replaced transport reports queued for events still saved', () async {
    final started = Completer<void>(), finish = Completer<int>();
    final queue = EventQueue((_) {
      started.complete();
      return finish.future;
    }, () => true);
    final event = queue.enqueue({});
    await started.future;
    queue.replace((_) async => 200, () => true);
    finish.complete(503);
    expect(await event, AppReferEventResult.queued);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(EventQueue.key)!), hasLength(1));
    await queue.clear();
  });
  test('new events serialized after clear survive reset completion', () async {
    final queue = EventQueue((_) async => 503, () => true);
    final clear = queue.clear();
    final event = queue.enqueue({'event_name': 'signed_out'});
    await clear;
    expect(await event, AppReferEventResult.queued);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(EventQueue.key)!), hasLength(1));
    await queue.clear();
  });
  test(
    'foreground refreshes pending attribution without changing consent',
    () async {
      var finalized = false;
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(
            const AppReferConfig(apiKey: 'pk_foreground'),
          );
          finalized = true;
          WidgetsBinding.instance.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await settle();
          expect((await AppReferSDK.getAttribution())?.network, 'meta');
        },
        () => MockClient(
          (_) async => http.Response(
            jsonEncode({
              'attribution': {
                'network': finalized ? 'meta' : 'organic',
                'matchType': 'click',
                'trackingDecisionPending': !finalized,
              },
            }),
            200,
          ),
        ),
      );
    },
  );
  test(
    'gone sessions clear, caps drop and chat polling does not retry',
    () async {
      for (final status in [200, 204, 299, 401, 403, 404]) {
        final slots = <String, String>{
          'apprefer_revocations': jsonEncode([
            {'token': 'old', 'key': 'pk_old', 'push': 'old-push'},
            {
              'token': 'expired',
              'createdAt':
                  DateTime.now().millisecondsSinceEpoch - 401 * 86400000,
            },
            {'token': 'capped', 'attempts': 20},
            {'token': 'last', 'attempts': 19},
          ]),
        };
        var deletes = 0;
        final api = SupportAPI(
          apiKey: () => 'pk',
          profile: () async => {},
          read: (key) async => slots[key],
          write: (key, value) async {
            if (value == null) {
              slots.remove(key);
            } else {
              slots[key] = value;
            }
          },
          client: MockClient((r) async {
            if (r.method == 'DELETE') {
              deletes++;
              expect(r.url.path, '/api/support/v1/session');
              if (r.headers['X-AppRefer-Support-Session'] == 'last')
                return http.Response('{}', 503);
              expect(r.headers['X-AppRefer-Key'], 'pk_old');
              return http.Response('{}', status);
            }
            return http.Response(
              r.method == 'POST' ? '{"session":"B"}' : '{"conversations":[]}',
              200,
            );
          }),
        );
        for (var i = 0; i < 3; i++) {
          await api.conversations();
          await api.thread('chat');
        }
        expect(deletes, 0);
        api.resumeRevocations();
        await settle();
        expect(deletes, 2);
        expect(jsonDecode(slots['apprefer_revocations']!), isEmpty);
        api.resumeRevocations();
        await settle();
        expect(deletes, 2);
      }
    },
  );
  test(
    'overlapping revocations share a pass and empty passes do not write',
    () async {
      final slots = <String, String>{
        'apprefer_revocations': '[{"token":"old"}]',
      };
      final entered = Completer<void>(), release = Completer<void>();
      var calls = 0, writes = 0;
      final api = SupportAPI(
        apiKey: () => 'pk',
        read: (k) async => slots[k],
        write: (k, v) async {
          writes++;
          if (v != null) slots[k] = v;
        },
        client: MockClient((_) async {
          calls++;
          entered.complete();
          await release.future;
          return http.Response('{}', 200);
        }),
      );
      api.resumeRevocations();
      await entered.future;
      for (var i = 0; i < 10; i++) {
        api.resumeRevocations();
      }
      release.complete();
      await settle();
      expect(calls, 1);
      expect(writes, 1);
      api.resumeRevocations();
      await settle();
      expect(writes, 1);
    },
  );
}
