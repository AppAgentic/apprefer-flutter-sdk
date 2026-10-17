import Foundation
import UserNotifications

/// The notification center calls the snooze guard needs (the live one is the app's
/// `UNUserNotificationCenter`; tests use a fake).
protocol EngagementSnoozeCenter: AnyObject {
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
    func identifiers(_ done: @escaping (_ pending: [String], _ delivered: [String]) -> Void)
    func remove(_ identifiers: [String])
}

/// AppRefer's local snoozes on iOS for the Flutter and React Native bridges (shared by copy with
/// the other bridge; the parent repo's scripts/check-sdk-shared-sources.mjs keeps them equal).
///
/// A snooze re-shows a notification for one install and account. Any identity change (sign-in,
/// logout, reset, deletion, a key switch, an epoch the server moved, also one learned at a cold
/// start) removes every pending or already shown AppRefer snooze (`apprefer.eng.snooze.*`); the
/// app's and Support's own notifications are never touched. A snooze whose system add is still in
/// flight when the identity changes is removed as soon as the add completes (fence), and one for
/// an identity that is no longer current is never scheduled.
final class EngagementSnoozeGuard {
    static let prefix = "apprefer.eng.snooze."
    private let center: EngagementSnoozeCenter
    private let defaults: UserDefaults
    private let seenKey: String
    /// Where the add completion is handled (main queue in the app; tests run it inline).
    private let deliver: (@escaping () -> Void) -> Void
    private let lock = NSLock()
    private var generation = 0

    init(center: EngagementSnoozeCenter, defaults: UserDefaults, seenKey: String,
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.center = center; self.defaults = defaults; self.seenKey = seenKey; self.deliver = deliver
    }

    /// The identity the SDK confirmed (epoch -1 = mid change, nil = unknown, e.g. offline). A
    /// different install, or a different confirmed epoch, than the last confirmed one is an
    /// identity change. Persisted, so a change learned at a cold start counts too.
    func observe(installId: String?, epoch: Int) {
        guard let installId else { return }
        let seen = defaults.dictionary(forKey: seenKey)
        let seenIid = seen?["iid"] as? String
        let seenEpoch = seen?["epoch"] as? Int ?? -1
        let changed = seenIid != nil && (seenIid != installId || (epoch >= 0 && seenEpoch >= 0 && seenEpoch != epoch))
        defaults.set(["iid": installId, "epoch": epoch >= 0 ? epoch : seenEpoch], forKey: seenKey)
        if changed { invalidate() }
    }

    /// The identity is changing or changed: every AppRefer snooze goes, pending or shown.
    func invalidate() {
        lock.lock(); generation += 1; lock.unlock()
        let center = self.center
        center.identifiers { pending, delivered in
            center.remove(Array(Set((pending + delivered).filter { $0.hasPrefix(Self.prefix) })))
        }
    }

    /// Schedules the re-show while `stillCurrent()` holds, and removes it again if the identity
    /// changed while the system add ran.
    func schedule(identifier: String, content: UNNotificationContent, after seconds: TimeInterval, stillCurrent: @escaping () -> Bool) {
        guard identifier.hasPrefix(Self.prefix), stillCurrent() else { return }
        lock.lock(); let fence = generation; lock.unlock()
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false))
        center.add(request) { [weak self] _ in
            self?.deliver {
                guard let self else { return }
                self.lock.lock(); let moved = self.generation != fence; self.lock.unlock()
                if moved || !stillCurrent() { self.center.remove([identifier]) }
            }
        }
    }
}

/// The app's notification center.
final class LiveEngagementSnoozeCenter: EngagementSnoozeCenter {
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
    }
    func identifiers(_ done: @escaping ([String], [String]) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { pending in
            center.getDeliveredNotifications { delivered in done(pending.map(\.identifier), delivered.map(\.request.identifier)) }
        }
    }
    func remove(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
