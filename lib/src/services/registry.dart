/// State shared between `AppReferSDK` and `AppReferBilling` (not exported).
class AppReferRegistry {
  AppReferRegistry._();

  /// The SDK key passed to `AppReferSDK.configure`.
  static String? apiKey;
  static String? explicitSupportKey;
  static String? get supportKey => explicitSupportKey ?? apiKey;
}
