import 'package:flutter/foundation.dart';
import 'dart:math';
import 'package:flutter/services.dart';
import 'http_client.dart';
import 'storage.dart';

/// First-party conversion values. Android deliberately does nothing.
class ConversionValue {
  final AppReferStorage storage;
  final AppReferHttpClient client;
  final bool Function() isIOS;
  final DateTime Function() now;
  final Future<void> Function(int, String) update;
  bool _inFlight = false;
  static const trialEvents = {
    'startTrial',
    'trial_started',
    'StartTrial',
    'start_trial',
  };
  static const _coarse = ['low', 'medium', 'high'];

  ConversionValue({
    required this.storage,
    required this.client,
    bool Function()? isIOS,
    DateTime Function()? now,
    Future<void> Function(int, String)? update,
  }) : isIOS = isIOS ?? (() => defaultTargetPlatform == TargetPlatform.iOS),
       now = now ?? DateTime.now,
       update = update ?? _nativeUpdate;

  static Future<void> _nativeUpdate(int fine, String coarse) async {
    try {
      await const MethodChannel(
        'com.apprefer.sdk/adservices',
      ).invokeMethod<void>('updateConversionValue', {
        'fine': fine,
        'coarse': coarse,
      });
    } catch (_) {
      /* Attribution must never interrupt the app. */
    }
  }

  Future<void> refresh({bool force = false}) async {
    if (!isIOS() || !storage.isSdkEnabled() || _inFlight) return;
    _inFlight = true;
    try {
      final firstRun = DateTime.tryParse(await storage.getFirstRunDate());
      if (firstRun != null &&
          now().difference(firstRun) > const Duration(days: 35))
        return;
      var value = storage.conversionValue();
      if (value == null) {
        await update(0, 'low');
        await storage.setConversionValue(0, 'low');
        value = (fine: 0, coarse: 'low');
      }
      final checked = storage.conversionCheckedAt();
      if (!force &&
          checked != null &&
          now().difference(checked) < const Duration(minutes: 10))
        return;
      final response = await client.post('/api/track/conversion-value', {
        'device_id': await storage.getDeviceId(),
      });
      final fine = response?['fine'];
      final coarse = response?['coarse'];
      if (fine is! int || fine < 0 || fine > 63 || !_coarse.contains(coarse))
        return;
      if (!storage.isSdkEnabled()) return;
      await storage.setConversionCheckedAt(now());
      final nextFine = max(value.fine, fine);
      final nextCoarse =
          _coarse[max(
            _coarse.indexOf(value.coarse),
            _coarse.indexOf(coarse as String),
          )];
      if (nextFine == value.fine && nextCoarse == value.coarse) return;
      await update(nextFine, nextCoarse);
      await storage.setConversionValue(nextFine, nextCoarse);
    } catch (_) {
      /* Best effort; retry on a later trigger. */
    } finally {
      _inFlight = false;
    }
  }
}
