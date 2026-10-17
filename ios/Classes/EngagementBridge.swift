import Flutter
import UIKit
import UserNotifications
import Security

/// Native side of `AppReferSDK.engagement` on iOS: the install credential in the Keychain
/// (service `com.apprefer.engagement`), AppRefer's notification button categories (merged
/// with the app's own), permission readback, and notification responses turned into a small
/// persisted outbox the Dart side drains (each outcome once). Dart re-checks identity before
/// any receipt or navigation; this side also never records a notification for another install
/// or account it knows about, or an expired one.
final class EngagementBridge: NSObject, FlutterPlugin {
    static var shared: EngagementBridge?
    private var channel: FlutterMethodChannel?
    private let defaults = UserDefaults.standard
    private static let eventsKey = "apprefer_engagement_flutter_events"
    private static let handledKey = "apprefer_engagement_flutter_handled"
    private static let identityKey = "apprefer_engagement_flutter_identity"
    private static let labelsKey = "apprefer_engagement_flutter_labels"
    private static let groupKey = "apprefer_engagement_flutter_group"
    /// AppRefer's local snoozes: removed on every identity change, fenced against late adds.
    private lazy var snoozes = EngagementSnoozeGuard(center: LiveEngagementSnoozeCenter(), defaults: defaults,
                                                     seenKey: "apprefer_engagement_flutter_seen_identity")

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.apprefer.sdk/engagement", binaryMessenger: registrar.messenger())
        let bridge = EngagementBridge()
        bridge.channel = channel
        shared = bridge
        registrar.addMethodCallDelegate(bridge, channel: channel)
        // FlutterAppDelegate forwards notification responses to plugins.
        registrar.addApplicationDelegate(bridge)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "secureRead":
            guard let key = call.arguments as? String else { result(FlutterError(code: "bad_args", message: nil, details: nil)); return }
            var query = Self.query(key)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { result(nil) }
            else if status == errSecSuccess, let data = item as? Data { result(String(data: data, encoding: .utf8)) }
            else { result(FlutterError(code: "secure_storage", message: "Keychain unavailable", details: status)) }
        case "secureWrite":
            guard let args = call.arguments as? [String: Any], let key = args["key"] as? String else { result(FlutterError(code: "bad_args", message: nil, details: nil)); return }
            let query = Self.query(key)
            guard let value = args["value"] as? String else { SecItemDelete(query as CFDictionary); result(nil); return }
            let data = Data(value.utf8)
            var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                status = SecItemAdd(add as CFDictionary, nil)
            }
            result(status == errSecSuccess ? nil : FlutterError(code: "secure_storage", message: "Keychain unavailable", details: status))
        case "configureNotifications":
            let args = call.arguments as? [String: Any] ?? [:]
            let labels = args["labels"] as? [String: String] ?? [:]
            defaults.set(labels, forKey: Self.labelsKey)
            defaults.set(args["appGroup"] as? String, forKey: Self.groupKey)
            Self.registerCategories(labels: labels) { result(nil) }
        case "setIdentity":
            let args = call.arguments as? [String: Any] ?? [:]
            let iid = args["installId"] as? String
            let epoch = args["accountEpoch"] as? Int ?? -1
            if let iid { defaults.set(["iid": iid, "epoch": epoch], forKey: Self.identityKey) } else { defaults.removeObject(forKey: Self.identityKey) }
            // A different confirmed install or epoch than before: the old identity's snoozes go.
            snoozes.observe(installId: iid, epoch: epoch)
            // The extension reads the same keys as AppReferNotificationSharedState.
            if let group = (args["appGroup"] as? String) ?? defaults.string(forKey: Self.groupKey), let shared = UserDefaults(suiteName: group) {
                if let iid { shared.set(epoch >= 0 ? ["iid": iid, "epoch": epoch] : ["iid": iid], forKey: "apprefer_engagement_identity") }
                else { shared.removeObject(forKey: "apprefer_engagement_identity") }
            }
            result(nil)
        case "permission":
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let value: String
                switch settings.authorizationStatus {
                case .authorized: value = "granted"
                case .provisional, .ephemeral: value = "provisional"
                case .denied: value = "denied"
                default: value = "unknown"
                }
                DispatchQueue.main.async { result(value) }
            }
        case "timezone": result(TimeZone.current.identifier)
        case "channelEnabled": result(nil)
        case "showNotification": result("not_android")
        case "takeEvents": result(takeEvents())
        case "clearForAccountChange":
            // Called before an identity change is sent: nothing recorded for the old identity
            // waits, its snoozes go, and nothing matches until Dart sets the new identity.
            defaults.removeObject(forKey: Self.eventsKey)
            if var id = defaults.dictionary(forKey: Self.identityKey), id["iid"] != nil { id["epoch"] = -1; defaults.set(id, forKey: Self.identityKey) }
            snoozes.invalidate()
            result(nil)
        default: result(FlutterMethodNotImplemented)
        }
    }

    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.apprefer.engagement", kSecAttrAccount as String: key]
    }

    // MARK: Categories

    static let kinds = ["open", "view", "start", "snooze"]

    /// Every ordered combination of one or two different kinds, buttons `apprefer.action.<index>`.
    static func registerCategories(labels: [String: String], done: @escaping () -> Void) {
        var combos: [[String]] = kinds.map { [$0] }
        for a in kinds { for b in kinds where b != a { combos.append([a, b]) } }
        let ours = combos.map { combo in
            UNNotificationCategory(identifier: "apprefer.eng." + combo.joined(separator: "."),
                                   actions: combo.enumerated().map { UNNotificationAction(identifier: "apprefer.action.\($0.offset)", title: labels[$0.element] ?? $0.element,
                                                                                         options: $0.element == "snooze" ? [] : [.foreground]) },
                                   intentIdentifiers: [], options: [.customDismissAction])
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationCategories { existing in
            center.setNotificationCategories(existing.filter { !$0.identifier.hasPrefix("apprefer.eng.") }.union(ours))
            DispatchQueue.main.async(execute: done)
        }
    }

    // MARK: Responses

    /// True when the response was AppRefer's (hosts with their own notification delegate call this).
    @discardableResult
    func handle(response: UNNotificationResponse) -> Bool {
        let content = response.notification.request.content
        let parsed = AppReferEngagementPayload.parse(userInfo: content.userInfo)
        guard parsed != .notEngagement else { return false }
        guard case .valid(let p) = parsed, !p.isExpired(), matchesIdentity(p) else { return true }
        let snoozed = content.userInfo["apprefer_snoozed"] as? Bool == true
        let shown = snoozed ? p.actions.filter { $0.kind != .snooze } : p.actions
        let category = shown.isEmpty ? nil : "apprefer.eng." + shown.map(\.kind.rawValue).joined(separator: ".")
        switch response.actionIdentifier {
        case UNNotificationDefaultActionIdentifier: record("opened", p, action: nil)
        case UNNotificationDismissActionIdentifier: record("dismissed", p, action: nil)
        default:
            guard response.actionIdentifier.hasPrefix("apprefer.action."), let index = Int(response.actionIdentifier.dropFirst("apprefer.action.".count)),
                  content.categoryIdentifier == category, shown.indices.contains(index) else { return true }
            let action = shown[index]
            if action.kind == .snooze {
                if record("snoozed", p, action: action) { snooze(p, userInfo: content.userInfo, minutes: action.snoozeMinutes ?? 60) }
            } else {
                record("action", p, action: action)
            }
        }
        return true
    }

    /// nil when not AppRefer's; otherwise whether to show it in the foreground.
    func presentation(for notification: UNNotification) -> UNNotificationPresentationOptions? {
        let parsed = AppReferEngagementPayload.parse(userInfo: notification.request.content.userInfo)
        guard parsed != .notEngagement else { return nil }
        guard case .valid(let p) = parsed, !p.isExpired(), matchesIdentity(p) else { return [] }
        record("received", p, action: nil)
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if handle(response: response) { completionHandler() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if let options = presentation(for: notification) { completionHandler(options) }
    }

    /// Before Dart set an identity (cold launch from a tap) the outcome is kept; Dart checks it.
    private func matchesIdentity(_ p: AppReferEngagementPayload) -> Bool {
        guard let id = defaults.dictionary(forKey: Self.identityKey), let iid = id["iid"] as? String else { return true }
        return iid == p.installId && (id["epoch"] as? Int) == p.accountEpoch
    }

    private func snooze(_ p: AppReferEngagementPayload, userInfo: [AnyHashable: Any], minutes: Int) {
        let delay = min(TimeInterval(minutes * 60), p.expiresAt.timeIntervalSinceNow - 60)
        guard delay >= 60 else { return }
        let content = UNMutableNotificationContent()
        content.title = p.title
        if let subtitle = p.subtitle { content.subtitle = subtitle }
        content.body = p.body
        var info: [AnyHashable: Any] = userInfo
        info["apprefer_snoozed"] = true
        content.userInfo = info
        content.sound = .default
        let rest = p.actions.filter { $0.kind != .snooze }
        if !rest.isEmpty { content.categoryIdentifier = "apprefer.eng." + rest.map(\.kind.rawValue).joined(separator: ".") }
        if let ck = p.collapseKey { content.threadIdentifier = ck }
        snoozes.schedule(identifier: EngagementSnoozeGuard.prefix + p.messageId, content: content, after: delay) { [weak self] in
            guard let self else { return false }
            return !p.isExpired() && self.matchesIdentity(p)
        }
    }

    // MARK: Outbox

    @discardableResult
    private func record(_ kind: String, _ p: AppReferEngagementPayload, action: AppReferEngagementPayload.Action?) -> Bool {
        let key = "\(kind):\(p.messageId)" + (kind == "action" ? ":\(action?.id ?? "")" : "")
        var handled = defaults.dictionary(forKey: Self.handledKey) as? [String: Double] ?? [:]
        guard handled[key] == nil else { return false }
        let now = Date().timeIntervalSince1970
        handled[key] = now
        let fresh = handled.filter { now - $0.value < 8 * 86_400 }.sorted { $0.value > $1.value }.prefix(300)
        defaults.set(Dictionary(uniqueKeysWithValues: fresh.map { ($0.key, $0.value) }), forKey: Self.handledKey)
        var event: [String: Any] = ["kind": kind, "messageId": p.messageId, "purpose": p.purpose.rawValue, "installId": p.installId,
                                    "accountEpoch": p.accountEpoch, "receiptToken": p.receiptToken, "at": Int(now * 1000),
                                    "expiresAt": Int(p.expiresAt.timeIntervalSince1970 * 1000)]
        let destination = kind == "opened" ? p.destination : (kind == "action" ? (action?.destination ?? p.destination) : nil)
        if let destination { event["destination"] = destination }
        if let action { event["actionId"] = action.id; event["actionKind"] = action.kind.rawValue }
        var events = defaults.array(forKey: Self.eventsKey) as? [[String: Any]] ?? []
        events.append(event)
        defaults.set(Array(events.suffix(50)), forKey: Self.eventsKey)
        channel?.invokeMethod("eventsAvailable", arguments: nil)
        return true
    }

    private func takeEvents() -> [[String: Any]] {
        var events = defaults.array(forKey: Self.eventsKey) as? [[String: Any]] ?? []
        defaults.removeObject(forKey: Self.eventsKey)
        // "Received" markers the Notification Service Extension left in the App Group.
        if let group = defaults.string(forKey: Self.groupKey), let shared = UserDefaults(suiteName: group),
           let data = shared.data(forKey: "apprefer_engagement_received"),
           let markers = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            shared.removeObject(forKey: "apprefer_engagement_received")
            for m in markers {
                guard let mid = m["messageId"] as? String, let iid = m["installId"] as? String, let epoch = m["accountEpoch"] as? Int,
                      let token = m["receiptToken"] as? String else { continue }
                // JSONEncoder's default Date is seconds since 2001.
                let at = ((m["receivedAt"] as? Double) ?? 0) + 978_307_200
                events.append(["kind": "received", "messageId": mid, "purpose": "", "installId": iid, "accountEpoch": epoch, "receiptToken": token, "at": Int(at * 1000)])
            }
        }
        return events
    }
}

extension AppReferPlugin {
    /// For apps whose own UNUserNotificationCenterDelegate doesn't forward to plugins: true when
    /// the response was AppRefer's lifecycle notification (call the completion handler then).
    @objc public static func handleEngagementResponse(_ response: UNNotificationResponse) -> Bool {
        EngagementBridge.shared?.handle(response: response) ?? false
    }

    /// nil when the notification isn't AppRefer's; otherwise the options to present it with.
    public static func engagementPresentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions? {
        EngagementBridge.shared?.presentation(for: notification)
    }
}
