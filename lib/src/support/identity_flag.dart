import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The `AppReferSDK.support.clearIdentity()` flag, kept in the Support secure
/// store next to the session token (iOS Keychain, Android Keystore-encrypted
/// preferences), so it survives or vanishes together with that session, e.g.
/// across an iOS reinstall that keeps the Keychain. A copy left in
/// SharedPreferences by 0.9.2 is moved there on first read. Without the
/// native store (no plugin, e.g. in unit tests) SharedPreferences is used.
class SupportIdentityFlag {
  SupportIdentityFlag._();

  static const key = 'apprefer_support_identity_cleared';
  static const _channel = MethodChannel('com.apprefer.sdk/support');

  /// Whether the identity is cleared. A secure store that can't be read (e.g.
  /// before first unlock) reads as cleared: nothing linking is sent.
  static Future<bool> read(SharedPreferences prefs) async =>
      await readState(prefs) ?? true;

  /// Like [read], but null when the secure store can't be read (or the 0.9.2
  /// copy can't be moved): unknown, so no Support session is minted or
  /// adopted on it.
  static Future<bool?> readState(SharedPreferences prefs) async {
    bool legacy;
    try {
      legacy = prefs.getBool(key) ?? false;
    } catch (_) {
      legacy = prefs.containsKey(key);
    }
    final String? stored;
    try {
      stored = await _channel.invokeMethod<String>('read', key);
    } on MissingPluginException {
      return legacy;
    } catch (_) {
      return null;
    }
    if (!legacy) return stored == '1';
    if (stored != '1') {
      try {
        await _channel.invokeMethod<void>('write', {'key': key, 'value': '1'});
      } catch (_) {
        // Copy failed: the SharedPreferences value stays and is read again.
        return true;
      }
    }
    await prefs.remove(key);
    return true;
  }

  /// Sets the flag. If the secure store can't save it, SharedPreferences
  /// keeps it (and the next read moves it).
  static Future<void> set(SharedPreferences prefs) async {
    try {
      await _channel.invokeMethod<void>('write', {'key': key, 'value': '1'});
      await prefs.remove(key);
    } catch (_) {
      await prefs.setBool(key, true);
    }
  }

  /// Ends the clear. Throws when the secure copy can't be removed; the flag
  /// then stays set (fail closed) and the caller must not act as if it ended.
  static Future<void> clear(SharedPreferences prefs) async {
    try {
      await _channel.invokeMethod<void>('write', {'key': key, 'value': null});
    } on MissingPluginException {
      // No secure store: SharedPreferences only.
    }
    await prefs.remove(key);
  }
}
