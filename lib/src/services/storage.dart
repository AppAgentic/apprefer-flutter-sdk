import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class AppReferStorage {
  static const _keyDeviceId = 'apprefer_device_id';
  static const _keyFirstRunDate = 'apprefer_first_run_date';
  static const _keyInstallEventSent = 'apprefer_install_event_sent';
  static const _keyMatchRequestAttempted = 'apprefer_match_request_attempted';
  static const _keyAttributionCache = 'apprefer_attribution_cache';
  static const _keySdkEnabled = 'apprefer_sdk_enabled';
  static const _keyLastConfigFetch = 'apprefer_last_config_fetch';
  static const _keyUserId = 'apprefer_user_id';

  late SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // --- Device ID ---

  Future<String> getDeviceId() async {
    String? deviceId = _prefs.getString(_keyDeviceId);
    if (deviceId == null) {
      deviceId = _generateUuidV4();
      await _prefs.setString(_keyDeviceId, deviceId);
    }
    return deviceId;
  }

  Future<void> setDeviceId(String id) async {
    await _prefs.setString(_keyDeviceId, id);
  }

  // --- First Run Date ---

  Future<String> getFirstRunDate() async {
    String? date = _prefs.getString(_keyFirstRunDate);
    if (date == null) {
      date = DateTime.now().toIso8601String();
      await _prefs.setString(_keyFirstRunDate, date);
    }
    return date;
  }

  // --- Install Event ---

  bool isInstallEventSent() {
    return _prefs.getBool(_keyInstallEventSent) ?? false;
  }

  Future<void> setInstallEventSent(bool sent) async {
    await _prefs.setBool(_keyInstallEventSent, sent);
  }

  // --- Match Request ---

  bool isMatchRequestAttempted() {
    return _prefs.getBool(_keyMatchRequestAttempted) ?? false;
  }

  Future<void> setMatchRequestAttempted(bool attempted) async {
    await _prefs.setBool(_keyMatchRequestAttempted, attempted);
  }

  // --- Attribution Cache ---

  String? getAttributionCache() {
    return _prefs.getString(_keyAttributionCache);
  }

  Future<void> setAttributionCache(String json) async {
    await _prefs.setString(_keyAttributionCache, json);
  }

  Future<void> clearAttributionCache() async {
    await _prefs.remove(_keyAttributionCache);
  }

  // --- SDK Enabled ---

  bool isSdkEnabled() {
    return _prefs.getBool(_keySdkEnabled) ?? true;
  }

  Future<void> setSdkEnabled(bool enabled) async {
    await _prefs.setBool(_keySdkEnabled, enabled);
  }

  // --- Last Config Fetch ---

  String? getLastConfigFetch() {
    return _prefs.getString(_keyLastConfigFetch);
  }

  Future<void> setLastConfigFetch(String timestamp) async {
    await _prefs.setString(_keyLastConfigFetch, timestamp);
  }

  // --- User ID ---

  String? getUserId() {
    return _prefs.getString(_keyUserId);
  }

  Future<void> setUserId(String userId) async {
    await _prefs.setString(_keyUserId, userId);
  }

  // --- UUID v4 Generator ---

  static String _generateUuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    // Set version (4) and variant (10xx) bits per RFC 4122
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
