// Native tests for EngagementSnoozeGuard.swift (the iOS bridge's local snoozes). Compiled with the
// guard itself and run on macOS by the test-native-ios script; no Flutter or React Native needed.
import Foundation
import UserNotifications

final class FakeCenter: EngagementSnoozeCenter {
    var pending: [String] = []
    var delivered: [String] = []
    var holdAdds = false
    var held: [(String, (Error?) -> Void)] = []
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        if holdAdds { held.append((request.identifier, completion)); return }
        pending.append(request.identifier); completion(nil)
    }
    /// The system add lands now (the request becomes pending, then the completion runs).
    func release() { let h = held; held = []; for (id, done) in h { pending.append(id); done(nil) } }
    func identifiers(_ done: @escaping ([String], [String]) -> Void) { done(pending, delivered) }
    func remove(_ identifiers: [String]) { pending.removeAll { identifiers.contains($0) }; delivered.removeAll { identifiers.contains($0) } }
}

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) { if !ok { failures += 1; print("FAIL line \(line): \(what)") } }
func fresh() -> (FakeCenter, UserDefaults) {
    let suite = "snooze-guard-\(UUID().uuidString)"
    return (FakeCenter(), UserDefaults(suiteName: suite)!)
}
let content = UNMutableNotificationContent()
let host = ["host.reminder", "apprefer.support.local"]

// An identity change removes AppRefer's snoozes, pending and shown, and nothing else.
do {
    let (center, defaults) = fresh()
    let guardA = EngagementSnoozeGuard(center: center, defaults: defaults, seenKey: "seen", deliver: { $0() })
    guardA.observe(installId: "ei_a", epoch: 1)
    center.pending = host; center.delivered = ["apprefer.eng.snooze.shown"]
    guardA.schedule(identifier: "apprefer.eng.snooze.m1", content: content, after: 60) { true }
    check(center.pending.contains("apprefer.eng.snooze.m1"), "scheduled")
    guardA.observe(installId: "ei_a", epoch: 2) // signed in as B
    check(center.pending == host, "only AppRefer snoozes removed, got \(center.pending)")
    check(center.delivered.isEmpty, "a shown snooze is removed too")
}

// Offline (unknown), mid change (-1) and the same identity again cancel nothing.
do {
    let (center, defaults) = fresh()
    let g = EngagementSnoozeGuard(center: center, defaults: defaults, seenKey: "seen", deliver: { $0() })
    g.observe(installId: "ei_a", epoch: 3)
    g.schedule(identifier: "apprefer.eng.snooze.m1", content: content, after: 60) { true }
    g.observe(installId: nil, epoch: -1)
    g.observe(installId: "ei_a", epoch: -1)
    g.observe(installId: "ei_a", epoch: 3)
    check(center.pending == ["apprefer.eng.snooze.m1"], "kept across offline / mid change / same identity")
}

// A cold start that learns another epoch (persisted last identity) removes the old snoozes.
do {
    let (center, defaults) = fresh()
    EngagementSnoozeGuard(center: center, defaults: defaults, seenKey: "seen", deliver: { $0() }).observe(installId: "ei_a", epoch: 1)
    center.pending = ["apprefer.eng.snooze.fromA"]
    let afterRestart = EngagementSnoozeGuard(center: center, defaults: defaults, seenKey: "seen", deliver: { $0() })
    afterRestart.observe(installId: "ei_a", epoch: 2)
    check(center.pending.isEmpty, "a change made while the app wasn't running")
    center.pending = ["apprefer.eng.snooze.fromOld"]
    afterRestart.observe(installId: "ei_b", epoch: 0) // replaced install
    check(center.pending.isEmpty, "another install")
}

// The system add is still in flight when the identity changes: removed once it lands.
do {
    let (center, defaults) = fresh()
    let g = EngagementSnoozeGuard(center: center, defaults: defaults, seenKey: "seen", deliver: { $0() })
    g.observe(installId: "ei_a", epoch: 1)
    center.holdAdds = true
    g.schedule(identifier: "apprefer.eng.snooze.late", content: content, after: 60) { true }
    g.invalidate() // logout: finds nothing yet
    check(center.pending.isEmpty, "nothing to remove yet")
    center.release()
    check(center.pending.isEmpty, "the late add is removed by its fence, got \(center.pending)")
}

// The identity moved before the observer ran: not current after the add, so removed.
do {
    let (center, defaults) = fresh()
    let g = EngagementSnoozeGuard(center: center, defaults: defaults, seenKey: "seen", deliver: { $0() })
    var current = true
    center.holdAdds = true
    g.schedule(identifier: "apprefer.eng.snooze.moved", content: content, after: 60) { current }
    current = false
    center.release()
    check(center.pending.isEmpty, "removed after the add")
    // Not current at all: never scheduled.
    center.holdAdds = false
    g.schedule(identifier: "apprefer.eng.snooze.never", content: content, after: 60) { false }
    check(center.pending.isEmpty, "never added")
    // Only AppRefer's own identifiers are ever scheduled through it.
    g.schedule(identifier: "host.reminder", content: content, after: 60) { true }
    check(center.pending.isEmpty, "not a snooze identifier")
}

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("EngagementSnoozeGuard native tests passed (5 groups)")
