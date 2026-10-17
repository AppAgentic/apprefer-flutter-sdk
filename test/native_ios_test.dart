@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The iOS bridge's local-snooze guard is native Swift: on macOS `flutter test` also compiles it
/// with its native tests (test/native) and runs them.
void main() {
  test(
    'EngagementSnoozeGuard native tests (iOS bridge)',
    () async {
      final r = await Process.run('sh', ['tool/test-native-ios.sh']);
      expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
      expect('${r.stdout}', contains('native tests passed'));
    },
    skip: Platform.isMacOS ? false : 'needs macOS with Xcode',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
