import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../services/logger.dart';

const String _sdkVersion = '0.1.0';
const int _maxRetries = 3;
const Duration _requestTimeout = Duration(seconds: 10);

class AppReferHttpClient {
  final String backendUrl;
  final String apiKey;
  final AppReferLogger _logger;

  AppReferHttpClient({
    required this.backendUrl,
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
    final url = Uri.parse('$backendUrl$path');
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          final delay = Duration(seconds: pow(2, attempt).toInt());
          _logger.debug('POST $path retry $attempt after ${delay.inSeconds}s');
          await Future.delayed(delay);
        }
        _logger.debug('POST $url');
        final response = await http
            .post(url, headers: _headers, body: jsonEncode(body))
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
    _logger.error('POST $path failed after $_maxRetries attempts');
    return null;
  }

  Future<Map<String, dynamic>?> get(String path) async {
    final url = Uri.parse('$backendUrl$path');
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        if (attempt > 0) {
          final delay = Duration(seconds: pow(2, attempt).toInt());
          _logger.debug('GET $path retry $attempt after ${delay.inSeconds}s');
          await Future.delayed(delay);
        }
        _logger.debug('GET $url');
        final response = await http
            .get(url, headers: _headers)
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
    _logger.error('GET $path failed after $_maxRetries attempts');
    return null;
  }
}
