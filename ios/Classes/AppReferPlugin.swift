import Flutter
import UIKit
import StoreKit
#if canImport(AdAttributionKit)
import AdAttributionKit
#endif
import AdServices
import AdSupport
import AppTrackingTransparency

public class AppReferPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        SupportBridge.register(with: registrar)
        let channel = FlutterMethodChannel(
            name: "com.apprefer.sdk/adservices",
            binaryMessenger: registrar.messenger()
        )
        let instance = AppReferPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "updateConversionValue":
            let args = call.arguments as? [String: Any] ?? [:]
            let fine = min(max(args["fine"] as? Int ?? 0, 0), 63)
            let coarse = args["coarse"] as? String ?? "low"
            Task { @MainActor in
                #if canImport(AdAttributionKit)
                if #available(iOS 17.4, *) {
                    let value: AdAttributionKit.CoarseConversionValue = coarse == "high" ? .high : coarse == "medium" ? .medium : .low
                    try? await Postback.updateConversionValue(fine, coarseConversionValue: value, lockPostback: false)
                }
                #endif
                if #available(iOS 16.1, *) {
                    let value: SKAdNetwork.CoarseConversionValue = coarse == "high" ? .high : coarse == "medium" ? .medium : .low
                    try? await SKAdNetwork.updatePostbackConversionValue(fine, coarseValue: value, lockWindow: false)
                } else if #available(iOS 15.4, *) {
                    try? await SKAdNetwork.updatePostbackConversionValue(fine)
                } else {
                    SKAdNetwork.updateConversionValue(fine)
                }
                result(nil)
            }
        case "getTrackingConsent":
            if #available(iOS 14, *) {
                switch ATTrackingManager.trackingAuthorizationStatus {
                case .authorized: result("granted")
                case .denied, .restricted: result("denied")
                case .notDetermined: result("undetermined")
                @unknown default: result("undetermined")
                }
            } else { result("granted") }
        case "getAdServicesToken":
            getAdServicesToken(result: result)
        case "billingCurrentEntitlements":
            if #available(iOS 15.0, *) {
                Task { @MainActor in
                    var purchases: [[String: Any]] = []
                    for await verification in Transaction.currentEntitlements {
                        guard case .verified(let transaction) = verification,
                              transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
                        purchases.append([
                            "id": String(transaction.id),
                            "productId": transaction.productID,
                            "originalId": String(transaction.originalID),
                            "accountToken": transaction.appAccountToken?.uuidString ?? "",
                            "json": String(data: transaction.jsonRepresentation, encoding: .utf8) ?? "",
                            "signedTransaction": verification.jwsRepresentation,
                        ])
                    }
                    result(purchases)
                }
            } else {
                result(FlutterError(code: "storekit_unavailable", message: "StoreKit 2 requires iOS 15", details: nil))
            }
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
