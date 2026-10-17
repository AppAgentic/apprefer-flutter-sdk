#!/bin/sh
# Compiles the iOS bridge's EngagementSnoozeGuard.swift with its native tests and runs them on
# macOS (no Flutter needed). Part of the release checks: run with `flutter test`.
set -eu
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
cp test/native/EngagementSnoozeGuardTests.swift "$out/main.swift"
xcrun swiftc -swift-version 5 -o "$out/guard-tests" ios/Classes/EngagementSnoozeGuard.swift "$out/main.swift"
"$out/guard-tests"
