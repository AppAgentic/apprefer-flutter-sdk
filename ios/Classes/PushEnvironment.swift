import Foundation

/// The APNs environment this build's device tokens belong to, read from how the app is
/// signed, never from DEBUG (same rules as the native iOS SDK's `PushEnvironmentDetector`):
/// Simulator = "sandbox"; embedded.mobileprovision `Entitlements` › `aps-environment`
/// `development` = "sandbox", `production` = "production"; no profile (App Store,
/// TestFlight), an unreadable, oversized or malformed one = "production".
/// Only public Foundation APIs: the embedded XML plist is located by its markers and parsed
/// with `PropertyListSerialization`.
enum PushEnvironmentDetector {
    static let maxProfileBytes = 2 * 1024 * 1024

    static func environment(profile: Data?, isSimulator: Bool) -> String {
        if isSimulator { return "sandbox" }
        guard let profile, let aps = apsEnvironment(inProfile: profile) else { return "production" }
        return aps == "development" ? "sandbox" : "production"
    }

    static func apsEnvironment(inProfile data: Data) -> String? {
        guard !data.isEmpty, data.count <= maxProfileBytes,
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.upperBound..<data.endIndex)
        else { return nil }
        let xml = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let plist = (try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil)) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String,
              aps == "development" || aps == "production" else { return nil }
        return aps
    }

    static func embeddedProfile(bundle: Bundle = .main) -> Data? {
        let url = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= maxProfileBytes else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// Read once per process.
    static let detected: String = environment(profile: embeddedProfile(), isSimulator: isSimulator)
}
