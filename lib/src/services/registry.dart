import 'storage.dart';

/// State shared between `AppReferSDK` and `AppReferBilling` (not exported).
class AppReferRegistry {
  AppReferRegistry._();

  /// The SDK key passed to `AppReferSDK.configure`.
  static String? apiKey;

  /// Set by `AppReferSDK.reset()` until configure runs again: attribution sends
  /// nothing and Support sends no device id, so the next account's Support
  /// session is never linked to the previous account's install.
  static bool stoppedByReset = false;

  /// Advances on every `AppReferSDK.reset()` (the account epoch). Billing
  /// sends the install device id only for the user it was given after the
  /// last reset, so an account active before it is never linked.
  static int accountEpoch = 0;

  /// `setCollectionEnabled(false)` in this process, even if saving it failed.
  static bool collectionBlocked = false;

  /// setCollectionEnabled ran in this process and configure hasn't run since.
  static bool collectionAwaitingConfigure = false;

  /// True while Support and Billing may link requests to this install: only
  /// after configure in this process, never after reset() (until configure
  /// runs again) or while collection is off (saved, unsaved, or turned back
  /// on but not configured yet). Support-only and Billing-only apps never link.
  static bool installLinkAllowed(AppReferStorage storage) =>
      apiKey != null &&
      !stoppedByReset &&
      !collectionBlocked &&
      !collectionAwaitingConfigure &&
      storage.collectionAllowed();

  static Future<bool> linkAllowed() async {
    final storage = AppReferStorage();
    await storage.init();
    return installLinkAllowed(storage);
  }

  /// The install device id Support and Billing may send, or null.
  static Future<String?> linkableDeviceId() async {
    final storage = AppReferStorage();
    await storage.init();
    return installLinkAllowed(storage) ? storage.existingDeviceId() : null;
  }

  static String? explicitSupportKey;
  static String? get supportKey => explicitSupportKey ?? apiKey;
}
