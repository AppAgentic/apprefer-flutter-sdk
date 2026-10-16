/// State shared between `AppReferSDK` and `AppReferBilling` (not exported).
class AppReferRegistry {
  AppReferRegistry._();

  /// The SDK key passed to `AppReferSDK.configure`.
  static String? apiKey;

  /// Set by `AppReferSDK.reset()` until configure runs again: attribution sends
  /// nothing and Support sends no device id, so the next account's Support
  /// session is never linked to the previous account's install.
  static bool stoppedByReset = false;
  static String? explicitSupportKey;
  static String? get supportKey => explicitSupportKey ?? apiKey;
}
