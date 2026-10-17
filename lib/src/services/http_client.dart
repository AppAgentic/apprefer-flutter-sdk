import 'tracking_consent.dart';
import 'event_queue.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../services/logger.dart';
import '../version.dart';
import '../engagement/apprefer_engagement.dart'
    show AppReferEngagement, engagementStampKey;

const String _sdkVersion = appReferVersion;
const int _maxRetries = 3;
const Duration _requestTimeout = Duration(seconds: 10);

class AppReferHttpClient {
  final bool Function() collectionAllowed;
  final String baseUrl;
  final String? fallbackUrl;
  final String apiKey;
  final AppReferLogger _logger;
  final Set<http.Client> _clients = {};
  int _generation = 0;
  int _eventGeneration = 0;
  final Set<http.Client> _eventClients = {};
  void cancelEvents() {
    _eventGeneration++;
    for (final client in _eventClients.toList()) {
      client.close();
    }
    _eventClients.clear();
  }

  void cancel() {
    _generation++;
    cancelEvents();
    for (final client in _clients.toList()) {
      client.close();
    }
    _clients.clear();
  }

  Future<http.Response> _send(
    String method,
    Uri url, {
    required Map<String, String> headers,
    String? body,
    bool event = false,
  }) async {
    if (!collectionAllowed()) throw StateError('Collection disabled');
    final client = http.Client();
    final clients = event ? _eventClients : _clients;
    clients.add(client);
    try {
      return await (method == 'POST'
              ? client.post(url, headers: headers, body: body)
              : client.get(url, headers: headers))
          .timeout(_requestTimeout);
    } finally {
      clients.remove(client);
      client.close();
    }
  }

  Future<int?> event(Map<String, dynamic> body) async =>
      (await eventResponse(body)).status;

  Future<EventResponse> eventResponse(Map<String, dynamic> body) async {
    final epoch = _eventGeneration;
    final hosts = _hosts(await TrackingConsent.current());
    if (epoch != _eventGeneration || !collectionAllowed())
      return const EventResponse(null);
    try {
      final response = await _send(
        'POST',
        Uri.parse('${hosts.first}/api/track/event'),
        event: true,
        // The stamp never leaves the device; the credential goes only while it is current.
        headers: {
          ..._headers,
          ...?AppReferEngagement.instance.headersFor(body[engagementStampKey]),
        },
        body: jsonEncode(Map.of(body)..remove(engagementStampKey)),
      ).timeout(_requestTimeout);
      final header = response.headers['retry-after'];
      final seconds = double.tryParse(header ?? '');
      final date = header == null || seconds != null ? null : _httpDate(header);
      final delay = seconds != null && seconds.isFinite
          ? (seconds * 1000).toInt()
          : date?.difference(DateTime.now()).inMilliseconds ?? 0;
      return EventResponse(
        epoch == _eventGeneration ? response.statusCode : null,
        retryAfter: max(0, delay),
      );
    } catch (_) {
      return const EventResponse(null);
    }
  }

  DateTime? _httpDate(String value) {
    try {
      return HttpDate.parse(value);
    } catch (_) {
      return null;
    }
  }

  // Only the default tracking pair follows consent. Explicit hosts stay pinned.
  bool get _routesTracking =>
      baseUrl == 'https://trk.apprefer.com' &&
      fallbackUrl == 'https://apprefer.com';

  List<String> _hosts(String? consent) {
    final configured = [baseUrl, if (fallbackUrl != null) fallbackUrl!];
    return _routesTracking
        ? TrackingConsent.hosts(consent, configured)
        : configured;
  }

  AppReferHttpClient({
    required this.baseUrl,
    this.collectionAllowed = _alwaysEnabled,
    this.fallbackUrl,
    required this.apiKey,
    required AppReferLogger logger,
  }) : _logger = logger;

  static bool _alwaysEnabled() => true;

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'X-SDK-Version': _sdkVersion,
    'X-AppRefer-Key': apiKey,
  };

  Future<Map<String, dynamic>?> post(
    String path,
    Map<String, dynamic> body, {
    String? consent,
    bool consentSnapshot = false,
  }) async {
    final epoch = _generation;
    final current = consentSnapshot ? consent : await TrackingConsent.current();
    if (body['event_name'] == '_advanced_matching' &&
        !TrackingConsent.allowed(current))
      return null;
    if (epoch != _generation || !collectionAllowed()) return null;
    final hosts = _hosts(current);
    final result = await _postWithRetries(hosts.first, path, body);
    if (epoch != _generation || !collectionAllowed()) return null;
    if (result != null) return result;

    // Fallback: single attempt on fallback URL
    if (hosts.length > 1) {
      _logger.debug('Falling back to $fallbackUrl for POST $path');
      return _postOnce(hosts[1], path, body);
    }

    return null;
  }

  Future<Map<String, dynamic>?> _postWithRetries(
    String url,
    String path,
    Map<String, dynamic> body,
  ) async {
    final epoch = _generation;
    final target = Uri.parse('$url$path');
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          final delay = Duration(seconds: pow(2, attempt).toInt());
          _logger.debug('POST $path retry $attempt after ${delay.inSeconds}s');
          await Future.delayed(delay);
        }
        if (epoch != _generation || !collectionAllowed()) return null;
        _logger.debug('POST $target');
        final response = await _send(
          'POST',
          target,
          headers: _headers,
          body: jsonEncode(body),
        ).timeout(_requestTimeout);

        if (epoch != _generation || !collectionAllowed()) return null;
        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (response.body.isEmpty) return {};
          return jsonDecode(response.body) as Map<String, dynamic>;
        }

        // Don't retry 4xx errors (client error, won't change on retry)
        if (response.statusCode >= 400 && response.statusCode < 500) {
          _logger.error(
            'POST $path failed: ${response.statusCode} ${response.body}',
          );
          return null;
        }

        // 5xx: retry
        _logger.error(
          'POST $path server error: ${response.statusCode} (attempt ${attempt + 1}/$_maxRetries)',
        );
      } on SocketException catch (e) {
        _logger.error(
          'POST $path network error (attempt ${attempt + 1}/$_maxRetries): $e',
        );
      } on TimeoutException catch (_) {
        _logger.error(
          'POST $path timeout (attempt ${attempt + 1}/$_maxRetries)',
        );
      } catch (e) {
        _logger.error('POST $path exception: $e');
        return null; // Unknown error, don't retry
      }
    }
    _logger.error('POST $path failed after $_maxRetries attempts on $url');
    return null;
  }

  Future<Map<String, dynamic>?> _postOnce(
    String url,
    String path,
    Map<String, dynamic> body,
  ) async {
    final epoch = _generation;
    final target = Uri.parse('$url$path');
    try {
      _logger.debug('POST $target (fallback)');
      final response = await _send(
        'POST',
        target,
        headers: _headers,
        body: jsonEncode(body),
      ).timeout(_requestTimeout);

      if (epoch != _generation || !collectionAllowed()) return null;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (response.body.isEmpty) return {};
        return jsonDecode(response.body) as Map<String, dynamic>;
      }

      _logger.error(
        'POST $path fallback failed: ${response.statusCode} ${response.body}',
      );
    } on SocketException catch (e) {
      _logger.error('POST $path fallback network error: $e');
    } on TimeoutException catch (_) {
      _logger.error('POST $path fallback timeout');
    } catch (e) {
      _logger.error('POST $path fallback exception: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> get(String path) async {
    final epoch = _generation;
    final hosts = _hosts(await TrackingConsent.current());
    final result = await _getWithRetries(hosts.first, path);
    if (epoch != _generation || !collectionAllowed()) return null;
    if (result != null) return result;

    // Fallback: single attempt on fallback URL
    if (hosts.length > 1) {
      _logger.debug('Falling back to $fallbackUrl for GET $path');
      return _getOnce(hosts[1], path);
    }

    return null;
  }

  Future<Map<String, dynamic>?> _getWithRetries(String url, String path) async {
    final epoch = _generation;
    final target = Uri.parse('$url$path');
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          final delay = Duration(seconds: pow(2, attempt).toInt());
          _logger.debug('GET $path retry $attempt after ${delay.inSeconds}s');
          await Future.delayed(delay);
        }
        if (epoch != _generation || !collectionAllowed()) return null;
        _logger.debug('GET $target');
        final response = await _send(
          'GET',
          target,
          headers: _headers,
        ).timeout(_requestTimeout);

        if (epoch != _generation || !collectionAllowed()) return null;
        if (response.statusCode >= 200 && response.statusCode < 300) {
          if (response.body.isEmpty) return {};
          return jsonDecode(response.body) as Map<String, dynamic>;
        }

        if (response.statusCode >= 400 && response.statusCode < 500) {
          _logger.error(
            'GET $path failed: ${response.statusCode} ${response.body}',
          );
          return null;
        }

        _logger.error(
          'GET $path server error: ${response.statusCode} (attempt ${attempt + 1}/$_maxRetries)',
        );
      } on SocketException catch (e) {
        _logger.error(
          'GET $path network error (attempt ${attempt + 1}/$_maxRetries): $e',
        );
      } on TimeoutException catch (_) {
        _logger.error(
          'GET $path timeout (attempt ${attempt + 1}/$_maxRetries)',
        );
      } catch (e) {
        _logger.error('GET $path exception: $e');
        return null;
      }
    }
    _logger.error('GET $path failed after $_maxRetries attempts on $url');
    return null;
  }

  Future<Map<String, dynamic>?> _getOnce(String url, String path) async {
    final epoch = _generation;
    final target = Uri.parse('$url$path');
    try {
      _logger.debug('GET $target (fallback)');
      final response = await _send(
        'GET',
        target,
        headers: _headers,
      ).timeout(_requestTimeout);

      if (epoch != _generation || !collectionAllowed()) return null;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (response.body.isEmpty) return {};
        return jsonDecode(response.body) as Map<String, dynamic>;
      }

      _logger.error(
        'GET $path fallback failed: ${response.statusCode} ${response.body}',
      );
    } on SocketException catch (e) {
      _logger.error('GET $path fallback network error: $e');
    } on TimeoutException catch (_) {
      _logger.error('GET $path fallback timeout');
    } catch (e) {
      _logger.error('GET $path fallback exception: $e');
    }
    return null;
  }
}
