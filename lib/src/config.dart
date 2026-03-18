class AppReferConfig {
  /// SDK key from the AppRefer dashboard (starts with `pk_`)
  final String apiKey;

  /// Optional: set identity at init time
  final String? userId;

  /// Enable debug logging (default: false)
  final bool debug;

  /// 0=none, 1=errors, 2=warnings, 3=verbose (default: 1)
  final int logLevel;

  const AppReferConfig({
    required this.apiKey,
    this.userId,
    this.debug = false,
    this.logLevel = 1,
  });

  /// Primary tracking URL (low-latency edge).
  static const String trackingUrl = 'https://trk.apprefer.com';

  /// Fallback URL used when the tracking URL is unreachable.
  static const String fallbackUrl = 'https://apprefer.com';
}
