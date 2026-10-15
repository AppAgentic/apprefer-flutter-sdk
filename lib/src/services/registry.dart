/// State shared between `AppReferSDK` and `AppReferBilling` (not exported).
class AppReferRegistry {
  AppReferRegistry._();

  /// The SDK key passed to `AppReferSDK.configure`.
  static String? apiKey;
}
