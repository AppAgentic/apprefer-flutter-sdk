import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/services/event_queue.dart';
import 'package:apprefer/src/services/storage.dart';
import 'package:apprefer/src/services/registry.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await AppReferSDK.disposeForTesting();
    SharedPreferences.setMockInitialValues({});
    final secure = <String, String>{};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(supportChannel, (call) async {
          if (call.method == 'keys') return secure.keys.toList();
          if (call.method == 'read') return secure[call.arguments as String];
          if (call.method == 'write') {
            final args = Map<String, dynamic>.from(call.arguments as Map);
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

  test('durable event restarts with stable id and retry backoff', () async {
    int? status = 503;
    final bodies = <Map<String, dynamic>>[];
    Future<int?> send(Map<String, dynamic> body) async {
      bodies.add(body);
      return status;
    }

    final queue = EventQueue(send, () => true);
    expect(
      await queue.enqueue({'event_name': 'offline'}),
      AppReferEventResult.queued,
    );
    final prefs = await SharedPreferences.getInstance();
    final saved = jsonDecode(prefs.getString(EventQueue.key)!) as List;
    final id = saved.single['id'];
    expect(saved.single['attempts'], 1);
    expect(
      saved.single['next'],
      greaterThan(DateTime.now().millisecondsSinceEpoch),
    );
    saved.single['next'] = 0;
    await prefs.setString(EventQueue.key, jsonEncode(saved));
    status = 200;
    final restarted = EventQueue(send, () => true);
    await restarted.flush();
    expect(bodies.map((e) => e['eventId']), [id, id]);
    expect(jsonDecode(prefs.getString(EventQueue.key)!), isEmpty);
    await queue.clear();
    await restarted.clear();
  });

  test('4xx dropped network queued clear and disabled erase disk', () async {
    int? status = 422;
    var enabled = true;
    final queue = EventQueue((_) async => status, () => enabled);
    expect(await queue.enqueue({}), AppReferEventResult.dropped);
    status = null;
    expect(await queue.enqueue({}), AppReferEventResult.queued);
    await queue.clear();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(EventQueue.key), isNull);
    await queue.enqueue({});
    enabled = false;
    await queue.flush();
    expect(prefs.getString(EventQueue.key), isNull);
  });

  test('1000 events maximum and seven day expiry', () async {
    final prefs = await SharedPreferences.getInstance();
    final entries = List.generate(
      1003,
      (i) => {
        'id': '$i',
        'body': {},
        'created': i == 1002 ? 0 : DateTime.now().millisecondsSinceEpoch,
        'attempts': 0,
        'next': DateTime.now().millisecondsSinceEpoch + 100000,
      },
    );
    await prefs.setString(EventQueue.key, jsonEncode(entries));
    final queue = EventQueue((_) async => 200, () => true);
    await queue.flush();
    final saved = jsonDecode(prefs.getString(EventQueue.key)!) as List;
    expect(saved.length, 1000);
    expect(saved.first['id'], '2');
    await queue.clear();
  });

  test(
    'Support-only has no device signals or analytics and reset isolates accounts',
    () async {
      AppReferSDK.support.configure(apiKey: 'pk_support');
      await AppReferSDK.setUserId('A');
      final store = <String, String>{};
      final requests = <http.Request>[];
      var minted = 0;
      final api = SupportAPI(
        client: MockClient((r) async {
          requests.add(r);
          if (r.method == 'DELETE') return http.Response('{}', 200);
          if (r.url.path.endsWith('/session'))
            return http.Response(jsonEncode({'session': 's${++minted}'}), 201);
          return http.Response(
            jsonEncode({
              'conversations': minted == 1
                  ? [
                      {'id': 'A-private'},
                    ]
                  : [],
            }),
            200,
          );
        }),
        apiKey: () => AppReferRegistry.supportKey,
        read: (k) async => store[k],
        write: (k, v) async {
          if (v == null) {
            store.remove(k);
          } else {
            store[k] = v;
          }
        },
      );
      expect(await api.conversations(), hasLength(1));
      expect(jsonDecode(requests.first.body).containsKey('deviceId'), false);
      await api.reset();
      await AppReferSDK.setUserId('B');
      expect(await api.conversations(), isEmpty);
      expect(requests.last.headers['X-AppRefer-Support-Session'], 's2');
      expect(
        requests.every((r) => r.url.path.startsWith('/api/support/v1/')),
        true,
      );
      expect(
        requests.any(
          (r) =>
              r.method == 'DELETE' &&
              r.headers['X-AppRefer-Support-Session'] == 's1',
        ),
        true,
      );
      await api.reset();
    },
  );

  test('typed configure organic versus network failure and unknown', () async {
    await http.runWithClient(
      () async {
        expect(
          (await AppReferSDK.configureResult(
            const AppReferConfig(apiKey: 'pk_test'),
          )).status,
          AttributionStatus.organic,
        );
      },
      () => MockClient((_) async => http.Response('{"attribution":null}', 200)),
    );
    SharedPreferences.setMockInitialValues({});
    await http.runWithClient(() async {
      expect(
        (await AppReferSDK.configureResult(
          const AppReferConfig(apiKey: 'pk_test'),
        )).status,
        AttributionStatus.failed,
      );
    }, () => MockClient((_) async => http.Response('{}', 403)));
  });

  test(
    'reset keeps install attribution and id but clears user and queued events',
    () async {
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(
            const AppReferConfig(apiKey: 'pk_test', userId: 'A'),
          );
          final id = await AppReferSDK.getDeviceId();
          final storage = AppReferStorage();
          await storage.init();
          await AppReferSDK.reset();
          await AppReferSDK.reset();
          expect(storage.getUserId(), isNull);
          expect(await AppReferSDK.getDeviceId(), id);
          expect((await AppReferSDK.getAttribution())?.network, 'meta');
        },
        () => MockClient(
          (_) async => http.Response('{"attribution":{"network":"meta"}}', 200),
        ),
      );
    },
  );
  test('late event response cannot repopulate cleared queue', () async {
    final entered = Completer<void>();
    final finish = Completer<int?>();
    final queue = EventQueue((_) {
      entered.complete();
      return finish.future;
    }, () => true);
    final sending = queue.enqueue({});
    await entered.future;
    await queue.clear();
    finish.complete(503);
    expect(await sending, AppReferEventResult.dropped);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(EventQueue.key), isNull);
  });

  test('network exception is failed, never organic', () async {
    await http.runWithClient(
      () async {
        expect(
          (await AppReferSDK.configureResult(
            const AppReferConfig(apiKey: 'pk_test'),
          )).status,
          AttributionStatus.failed,
        );
      },
      () => MockClient((_) async {
        throw const SocketException('offline');
      }),
    );
  });

  test('Support without either configuration reports not configured', () async {
    final api = SupportAPI(
      apiKey: () => null,
      profile: () async => {},
      read: (_) async => null,
      write: (_, _) async {},
    );
    await expectLater(api.conversations(), throwsA(isA<SupportException>()));
  });
}
