import 'dart:convert';

import 'package:crypto/crypto.dart';

class AppReferHashing {
  static String _sha256Hash(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Hash an email address: lowercase, trim, then SHA256.
  static String hashEmail(String email) {
    return _sha256Hash(email.toLowerCase().trim());
  }

  /// Hash a phone number: strip non-digits, then SHA256.
  static String hashPhone(String phone) {
    final digitsOnly = phone.replaceAll(RegExp(r'[^\d]'), '');
    return _sha256Hash(digitsOnly);
  }

  /// Hash a name: lowercase, trim, then SHA256.
  static String hashName(String name) {
    return _sha256Hash(name.toLowerCase().trim());
  }

  /// Hash a date of birth string: SHA256.
  static String hashDateOfBirth(String dob) {
    return _sha256Hash(dob.trim());
  }
}
