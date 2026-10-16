import 'dart:async';
import 'dart:convert';
import 'package:apprefer/apprefer.dart';
import 'package:apprefer/src/services/event_queue.dart';
import 'package:apprefer/src/services/registry.dart';
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
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

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

/// A preferences store whose writes fail, like a full disk.
class FailingWrites091 extends InMemorySharedPreferencesStore {
  FailingWrites091() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
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

  group('no device id on Support after reset or with collection off', () {
    SupportAPI supportApi(List<Map<String, dynamic>> sessions) {
      final secure = <String, String>{};
      return SupportAPI(
        apiKey: () => 'pk_test',
        read: (key) async => secure[key],
        write: (key, value) async {
          if (value == null) {
            secure.remove(key);
          } else {
            secure[key] = value;
          }
        },
        keys: () async => secure.keys.toList(),
        client: MockClient((r) async {
          final session = r.url.path.endsWith('/session');
          if (session && r.method == 'POST') {
            sessions.add(jsonDecode(r.body) as Map<String, dynamic>);
          }
          return http.Response(
            session ? '{"session":"support-091b"}' : '{"conversations":[]}',
            200,
          );
        }),
      );
    }

    test(
      'reset stops attribution and Support device id until configure',
      () async {
        final paths = <String>[];
        final events = <String>[];
        var status = 200;
        await http.runWithClient(
          () async {
            // A granted analytics: attribution is configured in this process.
            await AppReferSDK.configure(config);
            final prefs = await SharedPreferences.getInstance();
            final device = prefs.getString('apprefer_device_id');
            expect(device, isNotNull);
            expect((await SupportAPI.defaultProfile())['deviceId'], device);
            // A signs out.
            await AppReferSDK.reset();
            await Future<void>.delayed(const Duration(milliseconds: 20));
            final before = paths.length;
            // B signs in, never consents, and only uses Support.
            final sessions = <Map<String, dynamic>>[];
            final api = supportApi(sessions);
            expect(await api.conversations(), isEmpty);
            expect(sessions, hasLength(1));
            expect(sessions.single, isNot(contains('deviceId')));
            // Nothing on the attribution side sends until configure.
            await AppReferSDK.setUserId('B');
            await AppReferSDK.setTrackingConsent(true);
            await AppReferSDK.trackingConsentDidChange();
            await AppReferSDK.updateConversionValue();
            await AppReferSDK.setAdvancedMatching(email: 'b@example.test');
            // Before B consents: dropped, never queued or sent later.
            expect(
              await AppReferSDK.trackEventResult('signed_out'),
              AppReferEventResult.dropped,
            );
            await AppReferSDK.trackEvent('signed_out_fire_and_forget');
            expect(prefs.getString(EventQueue.key), isNull);
            WidgetsBinding.instance.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            await Future<void>.delayed(const Duration(milliseconds: 20));
            expect(paths.length, before);
            // Configure again: new events flow, Support links the install.
            await AppReferSDK.configure(config);
            expect(
              await AppReferSDK.trackEventResult('signed_in'),
              AppReferEventResult.sent,
            );
            expect(events.where((e) => e.startsWith('signed_out')), isEmpty);
            expect((await SupportAPI.defaultProfile())['deviceId'], device);
            await api.conversations();
            expect(sessions.last['deviceId'], device);
            // Collection withdrawn: Support stops sending the device id.
            await AppReferSDK.setCollectionEnabled(false);
            final count = sessions.length;
            await api.conversations();
            expect(sessions, hasLength(count + 1));
            expect(sessions.last, isNot(contains('deviceId')));
          },
          () => MockClient((r) async {
            paths.add(r.url.path);
            if (r.url.path.endsWith('/event')) {
              final body = jsonDecode(r.body) as Map<String, dynamic>;
              events.add(body['event_name'] as String);
            }
            return http.Response('{"attribution":null}', status);
          }),
        );
      },
    );

    test(
      'configure started before reset does not restart attribution',
      () async {
        var calls = 0;
        await http.runWithClient(
          () async {
            await AppReferSDK.configure(config);
            final stale = AppReferSDK.configure(config);
            await AppReferSDK.reset();
            expect(await stale, isNull);
            final before = calls;
            expect(
              await AppReferSDK.trackEventResult('held'),
              AppReferEventResult.dropped,
            );
            expect(calls, before);
            expect(
              (await SupportAPI.defaultProfile()),
              isNot(contains('deviceId')),
            );
          },
          () => MockClient((r) async {
            calls++;
            return http.Response('{"attribution":null}', 200);
          }),
        );
      },
    );

    test('Support-only sends no device id', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('apprefer_device_id', 'existing-install');
      AppReferRegistry.apiKey = null;
      AppReferSDK.support.configure(apiKey: 'pk_support');
      final sessions = <Map<String, dynamic>>[];
      await supportApi(sessions).conversations();
      expect(sessions.single, isNot(contains('deviceId')));
    });
  });

  group('review fixes', () {
    test('enabling while already on is a no-op and keeps the queue', () async {
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(config);
          expect(
            await AppReferSDK.trackEventResult('kept'),
            AppReferEventResult.queued,
          );
          // e.g. a consent tool reporting "granted" on every launch
          await AppReferSDK.setCollectionEnabled(true);
          expect(
            await AppReferSDK.trackEventResult('still-collecting'),
            AppReferEventResult.queued,
          );
          final prefs = await SharedPreferences.getInstance();
          expect(
            jsonDecode(prefs.getString(EventQueue.key)!) as List,
            hasLength(2),
          );
        },
        () => MockClient(
          (r) async => r.url.path.endsWith('/event')
              ? http.Response('{}', 503)
              : http.Response('{"attribution":null}', 200),
        ),
      );
    });

    test('a pause waiting for configure never clears the queue', () async {
      var status = 503;
      final events = <String>[];
      await http.runWithClient(
        () async {
          await AppReferSDK.configure(config);
          await AppReferSDK.trackEventResult('saved');
          final prefs = await SharedPreferences.getInstance();
          final saved = prefs.getString(EventQueue.key);
          // An earlier launch saved "off"; now turned back on: paused until configure.
          await prefs.setBool('apprefer_collection_enabled', false);
          await AppReferSDK.setCollectionEnabled(true);
          expect(
            await AppReferSDK.trackEventResult('paused'),
            AppReferEventResult.dropped,
          );
          expect(prefs.getString(EventQueue.key), saved);
          status = 200;
          final queued = jsonDecode(saved!) as List;
          queued.single['next'] = 0;
          await prefs.setString(EventQueue.key, jsonEncode(queued));
          await AppReferSDK.configure(config);
          await Future<void>.delayed(const Duration(milliseconds: 20));
          expect(events, contains('saved'));
        },
        () => MockClient((r) async {
          if (r.url.path.endsWith('/event')) {
            events.add((jsonDecode(r.body) as Map)['event_name'] as String);
            return http.Response('{}', status);
          }
          return http.Response('{"attribution":null}', 200);
        }),
      );
    });

    test(
      'configure with a user id while collection is off stores the new user',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('apprefer_user_id', 'A');
        await prefs.setString('apprefer_device_id', 'install');
        await AppReferSDK.setCollectionEnabled(false);
        var calls = 0;
        await http.runWithClient(
          () => AppReferSDK.configure(
            const AppReferConfig(apiKey: 'pk_test', userId: 'B'),
          ),
          () => MockClient((r) async {
            calls++;
            return http.Response('{}', 200);
          }),
        );
        expect(prefs.getString('apprefer_user_id'), 'B');
        expect((await SupportAPI.defaultProfile())['appUserId'], 'B');
        expect(calls, 0);
      },
    );

    test(
      'collection off at launch still returns stored device id and attribution',
      () async {
        SharedPreferences.setMockInitialValues({
          'apprefer_collection_enabled': false,
          'apprefer_device_id': 'install',
          'apprefer_attribution_cache':
              '{"network":"meta","matchType":"click"}',
        });
        AppReferRegistry.apiKey = null; // a fresh process
      expect(await AppReferSDK.getDeviceId(), isNull); // before configure
        await AppReferSDK.configure(config);
        expect(await AppReferSDK.getDeviceId(), 'install');
        expect((await AppReferSDK.getAttribution())?.network, 'meta');
      },
    );

    test(
      'setCollectionEnabled never throws and disables even if saving fails',
      () async {
        await http.runWithClient(
          () async {
            await AppReferSDK.configure(config);
            expect(
              await AppReferSDK.trackEventResult('queued'),
              AppReferEventResult.queued,
            );
            SharedPreferencesStorePlatform.instance = FailingWrites091();
            SharedPreferences.resetStatic();
            await AppReferSDK.setCollectionEnabled(false);
            expect(
              await AppReferSDK.trackEventResult('blocked'),
              AppReferEventResult.dropped,
            );
            final prefs = await SharedPreferences.getInstance();
            expect(prefs.getString(EventQueue.key), isNull);
          },
          () => MockClient(
            (r) async => r.url.path.endsWith('/event')
                ? http.Response('{}', 503)
                : http.Response('{"attribution":null}', 200),
          ),
        );
      },
    );
  });
}
