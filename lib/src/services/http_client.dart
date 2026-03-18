import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../services/logger.dart';
import '../version.dart';

const String _sdkVersion = appReferVersion;
const int _maxRetries = 3;
const Duration _requestTimeout = Duration(seconds: 10);

class AppReferHttpClient {
  final String baseUrl;
  final String? fallbackUrl;
  final String apiKey;
  final AppReferLogger _logger;

  AppReferHttpClient({
    required this.baseUrl,
    this.fallbackUrl,
    required this.apiKey,
    required AppReferLogger logger,
  }) : _logger = logger;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'X-SDK-Version': _sdkVersion,
        'X-AppRefer-Key': apiKey,
      };

  Future<Map<String, dynamic>?> post(
    String path,
    Map<String, dynamic> body,
  ) async {
    // Try primary URL with retries
    final result = await _postWithRetries(baseUrl, path, body);
    if (result != null) return result;

    // Fallback: single attempt on fallback URL
    if (fallbackUrl != null) {
      _logger.debug('Falling back to $fallbackUrl for POST $path');
      return _postOnce(fallbackUrl!, path, body);
    }

    return null;
  }

  Future<Map<String, dynamic>?> _postWithRetries(
    String url,
    String path,
    Map<String, dynamic> body,
  ) async {
    final target = Uri.parse('$url$path');
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          final delay = Duration(seconds: pow(2, attempt).toInt());
          _logger.debug('POST $path retry $attempt after ${delay.inSeconds}s');
          await Future.delayed(delay);
        }
        _logger.debug('POST $target');
        final response = await http
            .post(target, headers: _headers, body: jsonEncode(body))
            .timeout(_requestTimeout);

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
    final target = Uri.parse('$url$path');
    try {
      _logger.debug('POST $target (fallback)');
      final response = await http
          .post(target, headers: _headers, body: jsonEncode(body))
          .timeout(_requestTimeout);

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
    // Try primary URL with retries
    final result = await _getWithRetries(baseUrl, path);
    if (result != null) return result;

    // Fallback: single attempt on fallback URL
    if (fallbackUrl != null) {
      _logger.debug('Falling back to $fallbackUrl for GET $path');
      return _getOnce(fallbackUrl!, path);
    }

    return null;
  }

  Future<Map<String, dynamic>?> _getWithRetries(
    String url,
    String path,
  ) async {
    final target = Uri.parse('$url$path');
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          final delay = Duration(seconds: pow(2, attempt).toInt());
          _logger.debug('GET $path retry $attempt after ${delay.inSeconds}s');
          await Future.delayed(delay);
        }
        _logger.debug('GET $target');
        final response = await http
            .get(target, headers: _headers)
            .timeout(_requestTimeout);

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

  Future<Map<String, dynamic>?> _getOnce(
    String url,
    String path,
  ) async {
    final target = Uri.parse('$url$path');
    try {
      _logger.debug('GET $target (fallback)');
      final response = await http
          .get(target, headers: _headers)
          .timeout(_requestTimeout);

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
