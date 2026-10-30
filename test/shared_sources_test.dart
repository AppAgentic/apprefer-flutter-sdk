import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sources shared by copy with the other SDKs must match the hashes in shared-sources.json; the
/// parent repo's scripts/check-sdk-shared-sources.mjs keeps every copy and manifest equal.
void main() {
  final manifest =
      jsonDecode(File('shared-sources.json').readAsStringSync()) as Map;
  String hash(String text) => sha256.convert(utf8.encode(text)).toString();
  String java(String t) =>
      t.replaceAll('\r\n', '\n').replaceFirst(RegExp(r'^package [^\n]*\n'), '');
  String swift(String t) => t
      .replaceAll('\r\n', '\n')
      .split('\n')
      .where((l) => !l.contains('(copied; keep in sync)'))
      .map((l) => l.replaceFirstMapped(RegExp(r'^(\s*)public '), (m) => m[1]!))
      .join('\n');
  const hint =
      'changed without the shared copies: run node scripts/check-sdk-shared-sources.mjs in the parent repo';

  for (final entry in {
    'protectedBillingState': 'ProtectedBillingState.swift',
    'verifiedBillingStoreContext': 'VerifiedBillingStoreContext.swift',
  }.entries) {
    test('${entry.value} matches the manifest', () {
      expect(hash(swift(File('ios/Classes/${entry.value}').readAsStringSync())), manifest[entry.key], reason: hint);
    });
  }

  test('EngagementRenderer.java matches the manifest', () {
    final text = File(
      'android/src/main/java/com/apprefer/flutter/engagement/EngagementRenderer.java',
    ).readAsStringSync();
    expect(hash(java(text)), manifest['engagementRenderer'], reason: hint);
  });
  test('EngagementPayload.swift matches the manifest', () {
    final text = File('ios/Classes/EngagementPayload.swift').readAsStringSync();
    expect(hash(swift(text)), manifest['engagementPayloadSwift'], reason: hint);
  });
  test('TestimonialMedia.java matches the manifest', () {
    final text = File(
      'android/src/main/java/com/apprefer/flutter/testimonial/TestimonialMedia.java',
    ).readAsStringSync();
    expect(hash(java(text)), manifest['testimonialMediaJava'], reason: hint);
  });
  test('TestimonialMedia.swift matches the manifest', () {
    final text = File('ios/Classes/TestimonialMedia.swift').readAsStringSync();
    expect(hash(swift(text)), manifest['testimonialMediaSwift'], reason: hint);
  });
  test('EngagementSnoozeGuard.swift matches the manifest', () {
    final text = File(
      'ios/Classes/EngagementSnoozeGuard.swift',
    ).readAsStringSync();
    expect(
      hash(swift(text)),
      manifest['engagementSnoozeGuardSwift'],
      reason: hint,
    );
  });
}
