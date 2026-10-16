import Flutter
import UIKit
import PhotosUI
import Security

final class SupportBridge: NSObject, FlutterPlugin, PHPickerViewControllerDelegate {
    private var reply: FlutterResult?
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.apprefer.sdk/support", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SupportBridge(), channel: channel)
    }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "keys":
            var query = self.query("")
            query.removeValue(forKey: kSecAttrAccount as String)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            var found: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &found)
            if status == errSecItemNotFound { result([String]()) }
            else if status == errSecSuccess { result((found as? [[String: Any]] ?? []).compactMap { $0[kSecAttrAccount as String] as? String }) }
            else { result(FlutterError(code: "secure_storage", message: "Unable to list support sessions", details: status)) }
        case "read":
            let key = call.arguments as! String
            var query = self.query(key)
            query[kSecReturnData as String] = true
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { result(nil) }
            else if status == errSecSuccess, let data = item as? Data { result(String(data: data, encoding: .utf8)) }
            else { result(FlutterError(code: "secure_storage", message: "Unable to read support session", details: status)) }
        case "write":
            let args = call.arguments as! [String: Any]
            let query = self.query(args["key"] as! String)
            let value = args["value"] as? String
            if let value {
                let data = Data(value.utf8)
                var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
                if status == errSecItemNotFound {
                    var add = query; add[kSecValueData as String] = data
                    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                    status = SecItemAdd(add as CFDictionary, nil)
                }
                result(status == errSecSuccess ? nil : FlutterError(code: "secure_storage", message: "Unable to save support session", details: status))
            } else { SecItemDelete(query as CFDictionary); result(nil) }
        case "notificationChannel": result(nil)
        case "openUrl":
            // Help article links: only http(s) and mailto, opened outside the app.
            guard let string = call.arguments as? String, let url = URL(string: string),
                  let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { result(false); return }
            UIApplication.shared.open(url, options: [:]) { result($0) }
        case "appIcon":
            // The launcher icon for the help home; nil falls back to initials.
            guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
                  let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
                  let name = (primary["CFBundleIconFiles"] as? [String])?.last,
                  let png = UIImage(named: name)?.pngData() else { result(nil); return }
            result(FlutterStandardTypedData(bytes: png))
        case "pick":
            guard reply == nil else { result(FlutterError(code: "picker_busy", message: "Photo picker already open", details: nil)); return }
            var config = PHPickerConfiguration(); config.filter = .images; config.selectionLimit = max(1, min(4, call.arguments as? Int ?? 4))
            let picker = PHPickerViewController(configuration: config); picker.delegate = self
            var top = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
            while let next = top?.presentedViewController { top = next }
            guard let host = top else { result(FlutterError(code: "no_activity", message: "No presentation window", details: nil)); return }
            reply = result; host.present(picker, animated: true)
        default: result(FlutterMethodNotImplemented)
        }
    }
    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.apprefer.support", kSecAttrAccount as String: key]
    }
    static func jpeg(_ image: UIImage) -> Data {
        var scale = min(1, 1600 / max(image.size.width, image.size.height))
        while true {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let size = CGSize(width: max(1, (image.size.width * scale).rounded()), height: max(1, (image.size.height * scale).rounded()))
            let resized = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size)); image.draw(in: CGRect(origin: .zero, size: size))
            }
            for quality in stride(from: 0.8, through: 0.2, by: -0.15) {
                if let data = resized.jpegData(compressionQuality: quality), data.count <= 700000 { return data }
            }
            scale *= 0.75
        }
    }
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let group = DispatchGroup(); let lock = NSLock(); var data: [Int: FlutterStandardTypedData] = [:]
        for (index, item) in results.enumerated() {
            group.enter()
            item.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                defer { group.leave() }
                if let image = object as? UIImage {
                    let jpeg = FlutterStandardTypedData(bytes: Self.jpeg(image))
                    lock.lock(); data[index] = jpeg; lock.unlock()
                }
            }
        }
        group.notify(queue: .main) { self.reply?(data.keys.sorted().compactMap { data[$0] }); self.reply = nil }
    }
}
