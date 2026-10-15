import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
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

/// Customer-side API. Transport and token store can be injected in tests.
class SupportAPI {
  SupportAPI({
    http.Client? client,
    this.baseUrl = 'https://apprefer.com',
    Future<String?> Function(String)? read,
    Future<void> Function(String, String?)? write,
    Future<Map<String, dynamic>> Function()? profile,
    String? Function()? apiKey,
  }) : client = client ?? http.Client(),
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
  final http.Client client;
  final String baseUrl;
  final Future<String?> Function(String) read;
  final Future<void> Function(String, String?) write;
  final Future<Map<String, dynamic>> Function() profile;
  final String? Function() apiKey;
  String? name, email;
  Future<String>? _session;
  static Future<Map<String, dynamic>> defaultProfile() async {
    final storage = AppReferStorage();
    await storage.init();
    return {
      'deviceId': await storage.getDeviceId(),
      if (storage.getUserId() != null) 'appUserId': storage.getUserId(),
    };
  }

  Future<Map<String, dynamic>> _raw(
    String method,
    String path,
    Map<String, dynamic>? body,
    String? token,
  ) async {
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

  Future<String> _token() =>
      _session ??= _ensure().whenComplete(() => _session = null);
  Future<String> _ensure() async {
    final prefix = 'support_${apiKey()}';
    final p = await profile();
    p.addAll({
      if (name != null) 'name': name,
      if (email != null) 'email': email,
    });
    final fingerprint = jsonEncode(p);
    var token = await read('$prefix.token');
    if (token == null || await read('$prefix.profile') != fingerprint) {
      final response = await _raw('POST', '/session', p, token);
      token = response['session'] as String? ?? token;
      if (token == null || token.isEmpty)
        throw SupportException(0, 'Invalid support session');
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
    for (var attempt = 0; ; attempt++) {
      try {
        return await _raw(method, path, body, await _token());
      } on SupportException catch (e) {
        if (attempt != 0 ||
            e.status != 401 ||
            !e.message.toLowerCase().contains('support session'))
          rethrow;
        await write('support_${apiKey()}.token', null);
      }
    }
  }

  Future<List<Map<String, dynamic>>> conversations() async =>
      List<Map<String, dynamic>>.from(
        (await call('GET', '/conversations'))['conversations'],
      );
  Future<Map<String, dynamic>> thread(String id, {String? after}) => call(
    'GET',
    '/conversations/${Uri.encodeComponent(id)}${after == null ? '' : '?after=${Uri.encodeQueryComponent(after)}'}',
  );
  Future<Map<String, dynamic>> start(
    String text,
    List<String> ids,
    Map<String, dynamic> context, {
    required String clientMessageId,
  }) => call('POST', '/conversations', {
    'text': text,
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
    final response = await client
        .put(
          Uri.parse(slot['uploadUrl'] as String),
          headers: Map<String, String>.from(slot['headers']),
          body: jpeg,
        )
        .timeout(const Duration(seconds: 60));
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw SupportException(
        response.statusCode,
        'The screenshot did not upload. Try again.',
      );
    return slot['attachmentId'] as String;
  }
}
