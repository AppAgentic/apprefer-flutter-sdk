import Flutter
import UIKit
import AdServices
import AdSupport
import AppTrackingTransparency

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
        case "getIdfa":
            getIdfa(result: result)
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

    private func getIdfa(result: @escaping FlutterResult) {
        if #available(iOS 14, *) {
            let status = ATTrackingManager.trackingAuthorizationStatus
            if status == .authorized {
                let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
                // All-zeros means tracking is effectively disabled
                if idfa == "00000000-0000-0000-0000-000000000000" {
                    result(nil)
                } else {
                    result(idfa)
                }
            } else {
                result(nil)
            }
        } else {
            // Pre-iOS 14: no ATT required
            let idfa = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            if idfa == "00000000-0000-0000-0000-000000000000" {
                result(nil)
            } else {
                result(idfa)
            }
        }
    }
}
