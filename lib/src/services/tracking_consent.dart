import 'dart:io';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ATT is read without ever prompting. Android remains legacy until set.
class TrackingConsent {
  static const consentKey = 'apprefer_tracking_consent';
  static const reportedKey = 'apprefer_reported_tracking_consent';
  static const _channel = MethodChannel('com.apprefer.sdk/adservices');

  static String mapStatus(Object? status) {
    if (status == 'authorized' || status == 'granted' || status == 3)
      return 'granted';
    if (status == 'restricted' ||
        status == 'denied' ||
        status == 1 ||
        status == 2)
      return 'denied';
    return 'undetermined';
  }

  static Future<String?> current() async {
    if (Platform.isIOS) {
      try {
        return mapStatus(
          await _channel.invokeMethod<String>('getTrackingConsent'),
        );
      } catch (_) {
        return 'undetermined';
      }
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(consentKey);
  }

  static Future<void> set(bool? granted) async {
    if (Platform.isIOS) return;
    final prefs = await SharedPreferences.getInstance();
    if (granted == null) {
      await prefs.remove(consentKey);
    } else {
      await prefs.setString(consentKey, granted ? 'granted' : 'denied');
    }
  }

  static List<String> hosts(String? consent, List<String> legacy) =>
      consent == null
      ? legacy
      : [
          consent == 'granted'
              ? 'https://trk.apprefer.com'
              : 'https://apprefer.com',
        ];

  static bool allowed(String? consent) =>
      consent == null || consent == 'granted';
}
