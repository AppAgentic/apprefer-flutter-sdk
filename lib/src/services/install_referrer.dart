import 'dart:io';

import 'package:flutter/services.dart';

import 'logger.dart';

class AppReferInstallReferrer {
  static const _channel = MethodChannel('com.apprefer.sdk/install_referrer');
  final AppReferLogger _logger;

  AppReferInstallReferrer({required AppReferLogger logger}) : _logger = logger;

  /// Reads the Google Play Install Referrer on Android.
  /// Returns null on iOS or if referrer is unavailable.
  Future<Map<String, dynamic>?> getInstallReferrer() async {
    if (!Platform.isAndroid) return null;

    try {
      final result = await _channel.invokeMethod<Map>('getInstallReferrer');
      if (result == null) {
        _logger.info('Install Referrer: not available');
        return null;
      }
      final referrerMap = Map<String, dynamic>.from(result);
      _logger.info('Install Referrer retrieved: ${referrerMap['installReferrer']}');
      return referrerMap;
    } on PlatformException catch (e) {
      _logger.warn('Install Referrer unavailable: ${e.message}');
      return null;
    } catch (e) {
      _logger.error('Install Referrer error: $e');
      return null;
    }
  }

  /// Extracts the ar_click_id from the raw referrer string if present.
  static String? extractClickId(String? referrerString) {
    if (referrerString == null || referrerString.isEmpty) return null;
    try {
      final decoded = Uri.decodeComponent(referrerString);
      final params = Uri.splitQueryString(decoded);
      return params['ar_click_id'];
    } catch (_) {
      final match = RegExp(r'ar_click_id=([^&]+)').firstMatch(referrerString);
      return match?.group(1);
    }
  }
}
