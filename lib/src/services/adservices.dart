import 'dart:io';

import 'package:flutter/services.dart';

import 'logger.dart';

class AppReferAdServices {
  static const _channel = MethodChannel('com.apprefer.sdk/adservices');
  final AppReferLogger _logger;

  AppReferAdServices({required AppReferLogger logger}) : _logger = logger;

  /// Returns the AdServices attribution token on iOS 14.3+.
  /// Returns null on Android or if the token is unavailable.
  Future<String?> getAdServicesToken() async {
    if (!Platform.isIOS) return null;

    try {
      final token = await _channel.invokeMethod<String>('getAdServicesToken');
      if (token != null) {
        _logger.info('AdServices token retrieved');
      }
      return token;
    } on PlatformException catch (e) {
      _logger.warn('AdServices token unavailable: ${e.message}');
      return null;
    } catch (e) {
      _logger.error('AdServices error: $e');
      return null;
    }
  }
}
