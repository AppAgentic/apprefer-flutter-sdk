class AppReferConfig {
  /// App identifier from the AppRefer dashboard
  final String appId;

  /// Optional: set identity at init time
  final String? userId;

  /// Enable debug logging (default: false)
  final bool debug;

  /// 0=none, 1=errors, 2=warnings, 3=verbose (default: 1)
  final int logLevel;

  const AppReferConfig({
    required this.appId,
    this.userId,
    this.debug = false,
    this.logLevel = 1,
  });

  /// The AppRefer backend URL.
  static const String backendUrl = 'https://apprefer.com';
}
