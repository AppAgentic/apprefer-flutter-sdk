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

  /// Returns the IDFA on iOS if ATT is authorized.
  /// Returns null on Android, if ATT is not authorized, or if tracking is disabled.
  Future<String?> getIdfa() async {
    if (!Platform.isIOS) return null;

    try {
      final idfa = await _channel.invokeMethod<String>('getIdfa');
      if (idfa != null) {
        _logger.info('IDFA retrieved');
      }
      return idfa;
    } catch (e) {
      _logger.debug('IDFA unavailable: $e');
      return null;
    }
  }

  /// Returns the Google Advertising ID on Android if tracking is not limited.
  /// Returns null on iOS or if ad tracking is disabled.
  Future<String?> getGaid() async {
    if (!Platform.isAndroid) return null;

    try {
      final gaid = await _channel.invokeMethod<String>('getGaid');
      if (gaid != null) {
        _logger.info('GAID retrieved');
      }
      return gaid;
    } catch (e) {
      _logger.debug('GAID unavailable: $e');
      return null;
    }
  }
}
