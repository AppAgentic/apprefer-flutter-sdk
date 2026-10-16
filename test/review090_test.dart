import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/services/event_queue.dart';
import 'package:apprefer/src/services/registry.dart';
import 'package:apprefer/src/services/http_client.dart';
import 'package:apprefer/src/services/logger.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Map<String, String> secure;
  setUp(() async {
    await AppReferSDK.disposeForTesting();
    SharedPreferences.setMockInitialValues({});
    secure = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(supportChannel, (call) async {
          if (call.method == 'keys') return secure.keys.toList();
          if (call.method == 'read') return secure[call.arguments as String];
          if (call.method == 'write') {
            final args = call.arguments as Map;
            if (args['value'] == null) {
              secure.remove(args['key']);
            } else {
              secure[args['key'] as String] = args['value'] as String;
            }
          }
          return null;
        });
  });
  tearDown(() async {
    await AppReferSDK.clearPendingEvents();
  });
  List<Map<String, dynamic>> entries() => List.generate(
    3,
    (i) => {
      'id': '$i',
      'body': <String, dynamic>{},
      'created': DateTime.now().millisecondsSinceEpoch,
      'next': 0,
      'attempts': 0,
    },
  );

  test(
    'public reset before configure erases every support key namespace and account state',
    () async {
      expect(AppReferRegistry.apiKey, isNull);
      for (final key in ['pk_A', 'pk_old']) {
        secure['support_$key.token'] = 'A secret';
        secure['support_$key.profile'] = 'A profile';
        secure['support_$key.push'] = 'A push';
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('apprefer_user_id', 'A');
      await prefs.setString(EventQueue.key, 'A events');
      await http.runWithClient(() async {
        await AppReferSDK.reset();
        expect(secure.keys.where((k) => k.startsWith('support_')), isEmpty);
        expect(prefs.getString('apprefer_user_id'), isNull);
        expect(prefs.getString(EventQueue.key), isNull);
        await Future<void>.delayed(Duration.zero);
      }, () => MockClient((_) async => http.Response('{}', 200)));
    },
  );

  test(
    'pending ATT survives cached configure and is not confirmed offline',
    () async {
      await http.runWithClient(
        () async {
          expect(
            (await AppReferSDK.configureResult(
              const AppReferConfig(apiKey: 'pk_test'),
            )).status,
            AttributionStatus.pending,
          );
          expect(
            (await AppReferSDK.configureResult(
              const AppReferConfig(apiKey: 'pk_test'),
            )).status,
            AttributionStatus.pending,
          );
        },
        () => MockClient(
          (_) async => http.Response(
            '{"attribution":{"network":"organic","trackingDecisionPending":true}}',
            200,
          ),
        ),
      );
    },
  );

  test('offline consent report preserves confirmed Meta cache', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('apprefer_match_request_attempted', true);
    await prefs.setString(
      'apprefer_attribution_cache',
      '{"network":"meta","match_type":"click_id"}',
    );
    await http.runWithClient(() async {
      expect(
        (await AppReferSDK.configureResult(
          const AppReferConfig(apiKey: 'pk_test'),
        )).status,
        AttributionStatus.attributed,
      );
    }, () => MockClient((_) async => http.Response('{}', 403)));
  });

  for (final status in [408, 429, 503]) {
    test('$status pauses backlog and honors Retry-After', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(EventQueue.key, jsonEncode(entries()));
      var calls = 0;
      final queue = EventQueue((_) async {
        calls++;
        return EventResponse(status, retryAfter: 60000);
      }, () => true);
      await queue.flush();
      expect(calls, 1);
      final saved = jsonDecode(prefs.getString(EventQueue.key)!) as List;
      expect(saved.length, 3);
      expect(
        saved.every(
          (e) =>
              (e['next'] as num) >
              DateTime.now().millisecondsSinceEpoch + 59000,
        ),
        true,
      );
      await queue.clear();
    });
  }

  test('awaited event only waits for its own request', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(EventQueue.key, jsonEncode(entries()));
    var calls = 0;
    final queue = EventQueue((_) async {
      calls++;
      return 200;
    }, () => true);
    expect(await queue.enqueue({}), AppReferEventResult.sent);
    expect(calls, 1);
    await queue.clear();
  });

  test(
    'clear releases old drain and replacement cannot lose B writes',
    () async {
      final entered = Completer<void>(), finish = Completer<int?>();
      final queue = EventQueue((_) {
        entered.complete();
        return finish.future;
      }, () => true);
      final a = queue.enqueue({'user': 'A'});
      await entered.future;
      await queue.clear();
      queue.replace((_) async => 200, () => true);
      expect(await queue.enqueue({'user': 'B'}), AppReferEventResult.sent);
      finish.complete(503);
      expect(await a, AppReferEventResult.dropped);
      final prefs = await SharedPreferences.getInstance();
      expect(jsonDecode(prefs.getString(EventQueue.key)!), isEmpty);
      await queue.clear();
    },
  );

  test(
    'live queue survives public reconfigure without a duplicate send',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('apprefer_match_request_attempted', true);
      await prefs.setString(
        EventQueue.key,
        jsonEncode(entries().take(1).toList()),
      );
      final entered = Completer<void>(), finish = Completer<http.Response>();
      var attempts = 0;
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(const AppReferConfig(apiKey: 'pk_first'));
          await entered.future;
          await AppReferSDK.configure(
            const AppReferConfig(apiKey: 'pk_second'),
          );
          // The replacement retries the durable event; the retired response is ignored.
          finish.complete(http.Response('{}', 503));
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(attempts, 2);
          final saved = jsonDecode(prefs.getString(EventQueue.key)!) as List;
          expect(
            saved.single['attempts'],
            1,
          ); // The retired attempt cannot update the shared queue.
          await AppReferSDK.clearPendingEvents();
        },
        () => MockClient((request) async {
          if (request.url.path.endsWith('/event')) {
            attempts++;
            if (!entered.isCompleted) {
              entered.complete();
              return finish.future;
            }
            return http.Response('{}', 503);
          }
          return http.Response('{}', 200);
        }),
      );
    },
  );

  test(
    'corrupt queue is quarantined and unsupported event properties drop without throwing',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(EventQueue.key, '{broken');
      final queue = EventQueue((_) async => 200, () => true);
      expect(await queue.enqueue({}), AppReferEventResult.sent);
      expect(prefs.getString('${EventQueue.key}.corrupt'), '{broken');
      expect(
        await queue.enqueue({'date': DateTime.now()}),
        AppReferEventResult.dropped,
      );
      await queue.clear();
    },
  );

  test('compose awaiting media cannot upload or send after reset', () async {
    var calls = 0;
    final api = SupportAPI(
      client: MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      }),
      read: (k) async => secure[k],
      write: (k, v) async {
        if (v == null) {
          secure.remove(k);
        } else {
          secure[k] = v;
        }
      },
      keys: () async => secure.keys.toList(),
      apiKey: () => 'pk_support',
    );
    final epoch = api.actionGeneration;
    final media = Completer<Uint8List>();
    final action = () async {
      final image = await media.future;
      await api.upload(image, generation: epoch);
      await api.start(
        'A',
        [],
        {},
        clientMessageId: '12345678',
        generation: epoch,
      );
    }();
    final rejected = expectLater(action, throwsA(isA<SupportException>()));
    await api.reset();
    media.complete(Uint8List(0));
    await rejected;
    expect(calls, 0);
    await expectLater(
      api.send(
        'A-thread',
        'A',
        [],
        clientMessageId: '12345678',
        generation: epoch,
      ),
      throwsA(isA<SupportException>()),
    );
  });

  test(
    'Support-only has no device id and full configure preserves explicit Support key',
    () async {
      AppReferSDK.support.configure(apiKey: 'pk_support');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('apprefer_device_id', 'existing-install');
      AppReferRegistry.apiKey = null;
      expect(await SupportAPI.defaultProfile(), isNot(contains('deviceId')));
      await prefs.setBool('apprefer_match_request_attempted', true);
      await http.runWithClient(() async {
        await AppReferSDK.configure(const AppReferConfig(apiKey: 'pk_full'));
      }, () => MockClient((_) async => http.Response('{}', 200)));
      expect(AppReferRegistry.supportKey, 'pk_support');
      expect(AppReferRegistry.apiKey, 'pk_full');
    },
  );
  test(
    'event cancellation preserves configure and transport parses Retry-After',
    () async {
      final client = AppReferHttpClient(
        baseUrl: 'https://primary.test',
        apiKey: 'pk_test',
        logger: AppReferLogger(debug: false),
      );
      final started = Completer<void>(), finish = Completer<http.Response>();
      await http.runWithClient(
        () async {
          final pending = client.post(
            '/api/track/configure',
            {},
            consentSnapshot: true,
            consent: 'granted',
          );
          await started.future;
          client.cancelEvents();
          finish.complete(http.Response('{"ok":true}', 200));
          expect(await pending, {'ok': true});
        },
        () => MockClient((_) {
          started.complete();
          return finish.future;
        }),
      );
      await http.runWithClient(
        () async {
          final result = await client.eventResponse({});
          expect(result.status, 429);
          expect(result.retryAfter, 90000);
        },
        () => MockClient(
          (_) async => http.Response('{}', 429, headers: {'retry-after': '90'}),
        ),
      );
    },
  );

  test(
    'public trackEvent accepts unsupported properties without throwing',
    () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('apprefer_match_request_attempted', true);
      await http.runWithClient(() async {
        await AppReferSDK.configure(const AppReferConfig(apiKey: 'pk_test'));
        expect(
          await AppReferSDK.trackEventResult(
            'bad',
            properties: {'date': DateTime.now()},
          ),
          AppReferEventResult.dropped,
        );
        await AppReferSDK.trackEvent(
          'bad',
          properties: {'date': DateTime.now()},
        );
      }, () => MockClient((_) async => http.Response('{}', 200)));
    },
  );
  test('configure racing public reset cannot restore user A', () async {
    await http.runWithClient(() async {
      final configure = AppReferSDK.configure(
        const AppReferConfig(apiKey: 'pk_test', userId: 'A'),
      );
      await AppReferSDK.reset();
      await configure;
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('apprefer_user_id'), isNull);
    }, () => MockClient((_) async => http.Response('{}', 200)));
  });
}
