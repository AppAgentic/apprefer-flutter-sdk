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
       apiKey = apiKey ?? (() => AppReferRegistry.apiKey);
  final bool _injectedClient;
  http.Client client;
  int _generation = 0;
  Future<void> reset() async {
    _generation++;
    client.close();
    if (!_injectedClient) client = http.Client();
    final pending = _session;
    _session = null;
    name = null;
    email = null;
    persona.value = null;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {}
    }
    if (apiKey() == null) return;
    final prefix = 'support_${apiKey()}';
    final old = await read('$prefix.token');
    final push = await read('$prefix.push');
    await write('$prefix.push', null);
    await write('$prefix.token', null);
    await write('$prefix.profile', null);
    if (old != null) {
      if (push != null) {
        try {
          await _raw('DELETE', '/push-token', {'token': push}, old);
        } catch (_) {}
      }
      try {
        await _raw('DELETE', '/session', null, old);
      } catch (_) {
        /* Best effort. */
      }
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
      if (storage.existingDeviceId() != null)
        'deviceId': storage.existingDeviceId(),
      if (storage.getUserId() != null) 'appUserId': storage.getUserId(),
    };
  }

  Future<Map<String, dynamic>> _raw(
    String method,
    String path,
    Map<String, dynamic>? body,
    String? token,
  ) async {
    final epoch = _generation;
    final key = apiKey();
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
      await client.send(request).timeout(const Duration(seconds: 30)),
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
    var token = await read('$prefix.token');
    if (epoch != _generation) throw SupportException(0, 'Support reset');
    if (token == null || await read('$prefix.profile') != fingerprint) {
      final response = await _raw('POST', '/session', p, token);
      token = response['session'] as String? ?? token;
      if (token == null || token.isEmpty)
        throw SupportException(0, 'Invalid support session');
      if (epoch != _generation) throw SupportException(0, 'Support reset');
      await write('$prefix.token', token);
      await write('$prefix.profile', fingerprint);
    }
    return token;
  }

  Future<Map<String, dynamic>> call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final epoch = _generation;
    for (var attempt = 0; ; attempt++) {
      try {
        final token = await _token();
        if (epoch != _generation) throw SupportException(0, 'Support reset');
        return await _raw(method, path, body, token);
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

  Future<List<Map<String, dynamic>>> conversations() async {
    final list = await call('GET', '/conversations');
    persona.value = AppReferSupportPersona.fromJson(list['persona']);
    return List<Map<String, dynamic>>.from(list['conversations']);
  }

  Future<Map<String, dynamic>> thread(String id, {String? after}) async {
    final thread = await call(
      'GET',
      '/conversations/${Uri.encodeComponent(id)}${after == null ? '' : '?after=${Uri.encodeQueryComponent(after)}'}',
    );
    persona.value = AppReferSupportPersona.fromJson(thread['persona']);
    return thread;
  }

  Future<Map<String, dynamic>> start(
    String text,
    List<String> ids,
    Map<String, dynamic> context, {
    required String clientMessageId,
    String? subject,
  }) => call('POST', '/conversations', {
    'text': text,
    if (subject != null && subject.isNotEmpty) 'subject': subject,
    if (ids.isNotEmpty) 'attachmentIds': ids,
    'context': context,
    'clientMessageId': clientMessageId,
  });
  Future<Map<String, dynamic>> send(
    String id,
    String text,
    List<String> ids, {
    required String clientMessageId,
  }) async => Map<String, dynamic>.from(
    (await call('POST', '/conversations/${Uri.encodeComponent(id)}/messages', {
      'text': text,
      'clientMessageId': clientMessageId,
      if (ids.isNotEmpty) 'attachmentIds': ids,
    }))['message'],
  );
  Future<String> upload(Uint8List jpeg) async {
    final slot = await call('POST', '/attachments', {
      'contentType': 'image/jpeg',
      'size': jpeg.length,
      'name': 'screenshot.jpg',
    });
    final epoch = _generation;
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
