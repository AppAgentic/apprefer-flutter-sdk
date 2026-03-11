import Flutter
import UIKit
import AdServices

public class AppReferPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.apprefer.sdk/adservices",
            binaryMessenger: registrar.messenger()
        )
        let instance = AppReferPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getAdServicesToken":
            getAdServicesToken(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func getAdServicesToken(result: @escaping FlutterResult) {
        if #available(iOS 14.3, *) {
            do {
                let token = try AAAttribution.attributionToken()
                result(token)
            } catch {
                result(nil)
            }
        } else {
            result(nil)
        }
    }
}
