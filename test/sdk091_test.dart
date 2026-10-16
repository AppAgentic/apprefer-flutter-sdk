import 'dart:async';
import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/services/event_queue.dart';
import 'package:apprefer/src/services/storage.dart';
import 'package:apprefer/src/services/http_client.dart';
import 'package:apprefer/src/services/logger.dart';
import 'package:apprefer/src/support/support_api.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ClosingClient091 extends http.BaseClient {
  ClosingClient091(this.handler);
  final Future<http.Response> Function(http.Request) handler;
  bool closed = false;
  bool active = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    active = true;
    final bytes = await request.finalize().toBytes();
    final copy = http.Request(request.method, request.url)..bodyBytes = bytes;
    try {
      final response = await handler(copy);
      return http.StreamedResponse(
        Stream.value(response.bodyBytes),
        response.statusCode,
      );
    } finally {
      active = false;
    }
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await AppReferSDK.disposeForTesting();
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    await AppReferSDK.disposeForTesting();
  });
  const config = AppReferConfig(apiKey: 'pk_test');

  test(
    'public events persist identity across account switch restart and retry',
    () async {
      var status = 200;
      final bodies = <Map<String, dynamic>>[];
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(config);
          await AppReferSDK.setUserId('A');
          status = 429;
          expect(
            await AppReferSDK.trackEventResult('signup'),
            AppReferEventResult.queued,
          );
          final prefs = await SharedPreferences.getInstance();
          final saved = jsonDecode(prefs.getString(EventQueue.key)!) as List;
          expect(saved.single['body']['app_user_id'], 'A');
          final id = saved.single['id'];
          await AppReferSDK.setUserId('B');
          await AppReferSDK.disposeForTesting(); // process state cleared, restore original durable queue
          saved.single['next'] = 0;
          await prefs.setString(EventQueue.key, jsonEncode(saved));
          status = 200;
          await AppReferSDK.configure(config);
          final next = EventQueue((body) async {
            bodies.add(body);
            return 200;
          }, () => true);
          await next.flush();
          final signups = bodies
              .where((b) => b['event_name'] == 'signup')
              .toList();
          expect(signups.length, greaterThanOrEqualTo(2));
          expect(
            signups.every((b) => b['app_user_id'] == 'A' && b['eventId'] == id),
            true,
          );
          await next.clear();
        },
        () => MockClient((r) async {
          final body = jsonDecode(r.body) as Map<String, dynamic>;
          if (r.url.path.endsWith('/event')) bodies.add(body);
          return http.Response(
            r.url.path.endsWith('/configure') ? '{"attribution":null}' : '{}',
            status,
          );
        }),
      );
    },
  );

  test('anonymous and internal payloads omit app_user_id', () async {
    final bodies = <Map<String, dynamic>>[];
    await http.runWithClient(
      () async {
        await AppReferSDK.configure(config);
        await AppReferSDK.trackEvent('anonymous');
        await AppReferSDK.setUserId('A');
        await AppReferSDK.trackEvent('_internal');
        expect(
          bodies
              .where((b) => b['event_name'] == 'anonymous')
              .single
              .containsKey('app_user_id'),
          false,
        );
        expect(
          bodies
              .where((b) => (b['event_name'] as String? ?? '').startsWith('_'))
              .every((b) => !b.containsKey('app_user_id')),
          true,
        );
      },
      () => MockClient((r) async {
        bodies.add(jsonDecode(r.body) as Map<String, dynamic>);
        return http.Response('{"attribution":null}', 200);
      }),
    );
  });

  test(
    'disable blocks all entry points and foreground after relaunch until enabled and configured',
    () async {
      var calls = 0;
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(config);
          await AppReferSDK.setCollectionEnabled(false);
          final before = calls;
          await AppReferSDK.trackingConsentDidChange();
          await AppReferSDK.updateConversionValue();
          expect(
            await AppReferSDK.trackEventResult('blocked'),
            AppReferEventResult.dropped,
          );
          await AppReferSDK.reset();
          await AppReferSDK.disposeForTesting();
          expect(
            (await AppReferSDK.configureResult(config)).status,
            AttributionStatus.organic,
          );
          WidgetsBinding.instance.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await Future<void>.delayed(Duration.zero);
          expect(calls, before);
          await AppReferSDK.setCollectionEnabled(true);
          await AppReferSDK.trackEvent('still-no');
          expect(calls, before);
          await AppReferSDK.configure(config);
          await AppReferSDK.trackEvent('resumed');
          expect(calls, greaterThan(before));
        },
        () => MockClient((r) async {
          calls++;
          return http.Response('{"attribution":null}', 200);
        }),
      );
    },
  );

  test('disabled configure with no cache fails and Support works', () async {
    await AppReferSDK.setCollectionEnabled(false);
    expect(
      (await AppReferSDK.configureResult(config)).status,
      AttributionStatus.failed,
    );
    final secure = <String, String>{};
    final paths = <String>[];
    final api = SupportAPI(
      apiKey: () => 'pk_test',
      profile: () async => {},
      read: (key) async => secure[key],
      write: (key, value) async {
        if (value == null) {
          secure.remove(key);
        } else {
          secure[key] = value;
        }
      },
      client: MockClient((r) async {
        paths.add(r.url.path);
        return http.Response(
          r.url.path.endsWith('/session')
              ? '{"session":"support"}'
              : '{"conversations":[]}',
          200,
        );
      }),
    );
    expect(await api.conversations(), isEmpty);
    expect(paths, isNotEmpty);
    expect(paths.every((p) => p.contains('/support/v1/')), true);
  });

  test(
    'late event response cannot repopulate queue after collection disabled',
    () async {
      final entered = Completer<void>();
      final finish = Completer<http.Response>();
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(config);
          final sending = AppReferSDK.trackEventResult('inflight');
          await entered.future;
          await AppReferSDK.setCollectionEnabled(false);
          finish.complete(http.Response('{}', 503));
          expect(await sending, AppReferEventResult.dropped);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString(EventQueue.key), isNull);
        },
        () => MockClient((r) async {
          if (r.url.path.endsWith('/event')) {
            entered.complete();
            return finish.future;
          }
          return http.Response('{"attribution":null}', 200);
        }),
      );
    },
  );

  test(
    'transport gate blocks configure conversion and events including delayed work',
    () async {
      final storage = AppReferStorage();
      await storage.init();
      final client = AppReferHttpClient(
        baseUrl: 'https://apprefer.com',
        apiKey: 'pk',
        logger: AppReferLogger(),
        collectionAllowed: storage.isSdkEnabled,
      );
      storage.pauseCollection();
      var calls = 0;
      await http.runWithClient(
        () async {
          for (final path in [
            '/api/track/configure',
            '/api/track/conversion-value',
            '/api/track/event',
          ]) {
            expect(await client.post(path, {}), isNull);
          }
          expect((await client.eventResponse({})).status, isNull);
          expect(calls, 0);
        },
        () => MockClient((r) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
    },
  );
  for (final kind in ['configure', 'consent', 'conversion']) {
    test(
      'disable closes active $kind transport and ignores late response',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        var blocking = false;
        final entered = Completer<void>();
        final finish = Completer<http.Response>();
        final clients = <ClosingClient091>[];
        final updates = <dynamic>[];
        const channel = MethodChannel('com.apprefer.sdk/adservices');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'updateConversionValue')
                updates.add(call.arguments);
              return null;
            });
        try {
          await http.runWithClient(
            () async {
              if (kind != 'configure') {
                await AppReferSDK.configure(config);
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
              blocking = true;
              final work = kind == 'configure'
                  ? AppReferSDK.configure(config)
                  : kind == 'consent'
                  ? AppReferSDK.trackingConsentDidChange()
                  : AppReferSDK.updateConversionValue();
              await entered.future;
              final active = clients.where((c) => c.active).toList();
              expect(active, isNotEmpty);
              await AppReferSDK.setCollectionEnabled(false);
              expect(active.every((c) => c.closed), true);
              final before = updates.length;
              finish.complete(
                http.Response(
                  '{"fine":10,"coarse":"high","attribution":null}',
                  200,
                ),
              );
              await work;
              expect(updates.length, before);
            },
            () {
              final client = ClosingClient091((request) async {
                if (blocking) {
                  if (!entered.isCompleted) entered.complete();
                  return finish.future;
                }
                return http.Response(
                  '{"attribution":{"network":"organic","trackingDecisionPending":true}}',
                  200,
                );
              });
              clients.add(client);
              return client;
            },
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        }
      },
    );
  }
}
