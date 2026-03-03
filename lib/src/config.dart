class AppReferConfig {
  /// Your tracking domain (e.g., https://trk.yourdomain.com)
  final String backendUrl;

  /// App identifier
  final String appId;

  /// Optional: set identity at init time
  final String? userId;

  /// Enable debug logging (default: false)
  final bool debug;

  /// 0=none, 1=errors, 2=warnings, 3=verbose (default: 1)
  final int logLevel;

  const AppReferConfig({
    required this.backendUrl,
    required this.appId,
    this.userId,
    this.debug = false,
    this.logLevel = 1,
  });
}
