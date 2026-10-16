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
    'failed revocations stay saved across restart until both DELETEs succeed',
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
      expect(paths.map((p) => p.split('/').last), ['push-token', 'session']);
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
}
