import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../services/registry.dart';
import '../services/storage.dart';

String newSupportMessageId() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

const supportChannel = MethodChannel('com.apprefer.sdk/support');

class SupportException implements Exception {
  final int status;
  final String message;
  SupportException(this.status, this.message);
  @override
  String toString() => message;
}

/// The app's AI support assistant, set in AppRefer. Every message from it is tagged "AI".
@immutable
class AppReferSupportPersona {
  const AppReferSupportPersona({
    required this.name,
    this.avatarUrl,
    this.handoffTo,
  });
  final String name;
  final String? avatarUrl;

  /// Who it passes conversations to ("Jay"); null means the team.
  final String? handoffTo;

  /// Null when the key is missing (older servers), null, or has no name.
  static AppReferSupportPersona? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final avatar = json['avatarUrl'], to = json['handoffTo'];
    return AppReferSupportPersona(
      name: name.trim(),
      avatarUrl: avatar is String && avatar.isNotEmpty ? avatar : null,
      handoffTo: to is String && to.trim().isNotEmpty ? to.trim() : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppReferSupportPersona &&
      other.name == name &&
      other.avatarUrl == avatarUrl &&
      other.handoffTo == handoffTo;
  @override
  int get hashCode => Object.hash(name, avatarUrl, handoffTo);
}

/// The AI assistant's note that it passed the conversation to a person.
bool supportIsHandoff(Map<String, dynamic>? message) =>
    message?['handoff'] == true;

/// Customer-side API. Transport and token store can be injected in tests.
class SupportAPI {
  SupportAPI({
    http.Client? client,
    this.baseUrl = 'https://apprefer.com',
    Future<String?> Function(String)? read,
    Future<void> Function(String, String?)? write,
    Future<Map<String, dynamic>> Function()? profile,
    String? Function()? apiKey,
    Future<List<String>> Function()? keys,
  }) : _injectedClient = client != null,
       client = client ?? http.Client(),
       read =
           read ?? ((key) => supportChannel.invokeMethod<String>('read', key)),
       write =
           write ??
           ((key, value) => supportChannel.invokeMethod<void>('write', {
             'key': key,
             'value': value,
           })),
       profile = profile ?? defaultProfile,
       apiKey = apiKey ?? (() => AppReferRegistry.supportKey),
       keys =
           keys ??
           (() async =>
               await supportChannel.invokeListMethod<String>('keys') ?? []);
  final bool _injectedClient;
  http.Client client;
  int _generation = 0;
  int get actionGeneration => _generation;
  final Future<List<String>> Function() keys;
  Future<void> _storageWork = Future.value();
  Future<void> _resetting = Future.value();
  final _invalidatedSlots = <String>{};
  Future<T> _store<T>(Future<T> Function() action) {
    final result = _storageWork.then((_) => action());
    _storageWork = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<void> reset() {
    _generation++;
    client.close();
    if (!_injectedClient) client = http.Client();
    _session = null;
    name = null;
    email = null;
    final currentKey = apiKey();
    _resetting = _store(() async {
      final cleared = <String>{};
      Future<void> clear(List<String> slots) async {
        for (final slot in slots) {
          if (!slot.startsWith('support_') || cleared.contains(slot)) continue;
          if (slot.endsWith('.token')) {
            _invalidatedSlots.add(slot);
            final token = await _safeRead(slot);
            final prefix = slot.substring(0, slot.length - 6);
            final push = await _safeRead('$prefix.push');
            if (token != null)
              _deferredRevocations.add({
                'token': token,
                'key': prefix.substring(8),
                if (push != null) 'push': push,
              });
            await _saveRevocations();
          }
          try {
            await write(slot, null);
          } catch (_) {}
          cleared.add(slot);
        }
      }

      if (currentKey != null)
        await clear([
          'support_$currentKey.token',
          'support_$currentKey.profile',
          'support_$currentKey.push',
        ]);
      try {
        await clear(await keys());
      } catch (_) {}
      await _saveRevocations();
    }).catchError((Object _) {});
    return _resetting.then((_) {
      persona.value = null;
      resumeRevocations();
    });
  }

  final _deferredRevocations = <Map<String, dynamic>>[];
  Future<String?> _safeRead(String slot) async {
    try {
      return await read(slot);
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _parseRevocations(String? raw) {
    try {
      final value = jsonDecode(raw ?? '[]');
      if (value is! List) return [];
      return value
          .whereType<Map>()
          .where(
            (v) =>
                v['token'] is String &&
                (v['key'] == null || v['key'] is String) &&
                (v['push'] == null || v['push'] is String),
          )
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _savedRevocations() async {
    final result = _parseRevocations(await read('apprefer_revocations'));
    for (final item in _deferredRevocations) {
      if (!result.any(
        (v) => v['token'] == item['token'] && v['key'] == item['key'],
      ))
        result.add(item);
    }
    return result;
  }

  Future<void> _saveRevocations() async {
    try {
      await write(
        'apprefer_revocations',
        jsonEncode(await _savedRevocations()),
      );
    } catch (_) {}
  }

  void resumeRevocations() {
    unawaited(_revokePending().catchError((Object _) {}));
  }

  Future<void>? _revoking;
  Future<void> _revokePending() =>
      _revoking ??= _runRevocations().whenComplete(() => _revoking = null);
  Future<void> _runRevocations() async {
    final pending = await _store(() async {
      final items = await _savedRevocations();
      await write('apprefer_revocations', jsonEncode(items));
      return items;
    });
    for (final item in pending) {
      final key = item['key'] as String? ?? apiKey();
      if (key == null) continue;
      var succeeded = true;
      for (final path in [
        if (item['push'] != null) '/push-token',
        '/session',
      ]) {
        try {
          await _raw(
            'DELETE',
            path,
            path == '/push-token' ? {'token': item['push']} : null,
            item['token'] as String,
            keyOverride: key,
            timeout: const Duration(seconds: 5),
          );
        } catch (_) {
          succeeded = false;
        }
      }
      if (!succeeded) continue;
      await _store(() async {
        final current = await _savedRevocations();
        current.removeWhere(
          (v) => v['token'] == item['token'] && v['key'] == item['key'],
        );
        await write('apprefer_revocations', jsonEncode(current));
        _deferredRevocations.removeWhere(
          (v) => v['token'] == item['token'] && v['key'] == item['key'],
        );
      });
    }
  }

  final String baseUrl;
  final Future<String?> Function(String) read;
  final Future<void> Function(String, String?) write;
  final Future<Map<String, dynamic>> Function() profile;
  final String? Function() apiKey;
  String? name, email;
  Future<String>? _session;

  /// The app's AI assistant from the latest list or conversation read (null
  /// when the app has none). The help screens listen to it.
  final ValueNotifier<AppReferSupportPersona?> persona = ValueNotifier(null);
  static Future<Map<String, dynamic>> defaultProfile() async {
    final storage = AppReferStorage();
    await storage.init();
    return {
      if (AppReferRegistry.apiKey != null && storage.existingDeviceId() != null)
        'deviceId': storage.existingDeviceId(),
      if (storage.getUserId() != null) 'appUserId': storage.getUserId(),
    };
  }

  Future<Map<String, dynamic>> _raw(
    String method,
    String path,
    Map<String, dynamic>? body,
    String? token, {
    String? keyOverride,
    int? expectedGeneration,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final epoch = expectedGeneration ?? _generation;
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    final key = keyOverride ?? apiKey();
    if (key == null)
      throw SupportException(0, 'Configure AppRefer before opening support.');
    final request = http.Request(
      method,
      Uri.parse('$baseUrl/api/support/v1$path'),
    );
    request.headers['X-AppRefer-Key'] = key;
    if (token != null) request.headers['X-AppRefer-Support-Session'] = token;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await http.Response.fromStream(
      await client.send(request).timeout(timeout),
    );
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    Map<String, dynamic> data = {};
    try {
      if (response.body.isNotEmpty)
        data = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      /* HTTP error below */
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SupportException(
        response.statusCode,
        '${data['error'] ?? data['message'] ?? 'Unable to connect (${response.statusCode})'}',
      );
    }
    return data;
  }

  Future<void> ensureSession() async {
    await call('GET', '/conversations');
  }

  Future<String> _token() {
    final epoch = _generation;
    return _session ??= _ensure().whenComplete(() {
      if (epoch == _generation) _session = null;
    });
  }

  Future<String> _ensure() async {
    final epoch = _generation;
    final prefix = 'support_${apiKey()}';
    final p = await profile();
    p.addAll({
      if (name != null) 'name': name,
      if (email != null) 'email': email,
    });
    final fingerprint = jsonEncode(p);
    await _resetting;
    var token = await _store(() => read('$prefix.token'));
    final pending = await _savedRevocations();
    if (_invalidatedSlots.contains('$prefix.token') ||
        pending.any((item) => item['token'] == token))
      token = null;
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    if (token == null || await read('$prefix.profile') != fingerprint) {
      final response = await _raw(
        'POST',
        '/session',
        p,
        token,
        expectedGeneration: epoch,
      );
      token = response['session'] as String? ?? token;
      if (token == null || token.isEmpty)
        throw SupportException(0, 'Invalid support session');
      if (epoch != _generation) throw SupportException(0, 'Support reset');
      await _store(() async {
        if (epoch != _generation) throw SupportException(0, 'Support reset');
        await write('$prefix.token', token);
        _invalidatedSlots.remove('$prefix.token');
        await write('$prefix.profile', fingerprint);
      });
    }
    return token;
  }

  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
    int? expectedGeneration,
  ]) async {
    final epoch = expectedGeneration ?? _generation;
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    await _resetting;
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    unawaited(_revokePending().catchError((Object _) {}));
    for (var attempt = 0; ; attempt++) {
      try {
        final token = await _token();
        if (epoch != _generation) throw SupportException(0, 'Support reset');
        return await _raw(method, path, body, token, expectedGeneration: epoch);
      } on SupportException catch (e) {
        if (epoch != _generation) rethrow;
        if (attempt != 0 ||
            e.status != 401 ||
            !e.message.toLowerCase().contains('support session'))
          rethrow;
        await write('support_${apiKey()}.token', null);
      }
    }
  }

  Future<void> persistPushToken(String? token, int epoch) => _store(() async {
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    await write('support_${apiKey()}.push', token);
  });

  Future<List<Map<String, dynamic>>> conversations() async {
    final epoch = _generation;
    final list = await call('GET', '/conversations');
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    persona.value = AppReferSupportPersona.fromJson(list['persona']);
    return List<Map<String, dynamic>>.from(list['conversations']);
  }

  Future<Map<String, dynamic>> thread(String id, {String? after}) async {
    final epoch = _generation;
    final thread = await call(
      'GET',
      '/conversations/${Uri.encodeComponent(id)}${after == null ? '' : '?after=${Uri.encodeQueryComponent(after)}'}',
    );
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    persona.value = AppReferSupportPersona.fromJson(thread['persona']);
    return thread;
  }

  Future<Map<String, dynamic>> start(
    String text,
    List<String> ids,
    Map<String, dynamic> context, {
    required String clientMessageId,
    String? subject,
    int? generation,
  }) => call('POST', '/conversations', {
    'text': text,
    if (subject != null && subject.isNotEmpty) 'subject': subject,
    if (ids.isNotEmpty) 'attachmentIds': ids,
    'context': context,
    'clientMessageId': clientMessageId,
  }, generation);
  Future<Map<String, dynamic>> send(
    String id,
    String text,
    List<String> ids, {
    required String clientMessageId,
    int? generation,
  }) async => Map<String, dynamic>.from(
    (await call('POST', '/conversations/${Uri.encodeComponent(id)}/messages', {
      'text': text,
      'clientMessageId': clientMessageId,
      if (ids.isNotEmpty) 'attachmentIds': ids,
    }, generation))['message'],
  );
  Future<String> upload(Uint8List jpeg, {int? generation}) async {
    final epoch = generation ?? _generation;
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    final slot = await call('POST', '/attachments', {
      'contentType': 'image/jpeg',
      'size': jpeg.length,
      'name': 'screenshot.jpg',
    }, epoch);
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    final response = await client
        .put(
          Uri.parse(slot['uploadUrl'] as String),
          headers: Map<String, String>.from(slot['headers']),
          body: jpeg,
        )
        .timeout(const Duration(seconds: 60));
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw SupportException(
        response.statusCode,
        'The screenshot did not upload. Try again.',
      );
    return slot['attachmentId'] as String;
  }
}
