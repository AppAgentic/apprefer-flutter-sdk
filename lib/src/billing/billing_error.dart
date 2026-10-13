/// Why an AppReferBilling call failed.
enum AppReferBillingErrorCode {
  /// `AppReferBilling.configure()` has not been called.
  notConfigured,

  /// No SDK key: pass `apiKey` to `AppReferBilling.configure` or call
  /// `AppReferSDK.configure` first.
  missingApiKey,

  /// AppRefer could not be reached.
  network,

  /// AppRefer answered with an error status ([AppReferBillingException.status]).
  server,

  /// AppRefer answered 2xx with a body the SDK could not read.
  invalidResponse,

  /// The store could not verify the transaction; no access was granted.
  unverifiedTransaction,

  /// App user ids must be 1-256 characters with no whitespace.
  invalidAppUserId,

  /// The store refused or failed the request (purchase sheet could not open,
  /// billing unavailable, purchase error).
  store,
}

/// Thrown by AppReferBilling.
class AppReferBillingException implements Exception {
  final AppReferBillingErrorCode code;
  final String? message;

  /// HTTP status for [AppReferBillingErrorCode.server].
  final int? status;

  const AppReferBillingException(this.code, {this.message, this.status});

  /// Whether the same request may succeed later. Only malformed requests
  /// (400/413/422) and local verification failures are final.
  bool get isRetryable {
    switch (code) {
      case AppReferBillingErrorCode.notConfigured:
      case AppReferBillingErrorCode.missingApiKey:
      case AppReferBillingErrorCode.network:
      case AppReferBillingErrorCode.invalidResponse:
        return true;
      case AppReferBillingErrorCode.server:
        return !const {400, 413, 422}.contains(status);
      case AppReferBillingErrorCode.unverifiedTransaction:
      case AppReferBillingErrorCode.invalidAppUserId:
      case AppReferBillingErrorCode.store:
        return false;
    }
  }

  /// AppRefer is unreachable (stop sending more requests for now).
  bool get isConnectivity {
    switch (code) {
      case AppReferBillingErrorCode.network:
      case AppReferBillingErrorCode.missingApiKey:
      case AppReferBillingErrorCode.notConfigured:
        return true;
      case AppReferBillingErrorCode.server:
        return (status ?? 0) >= 500;
      default:
        return false;
    }
  }

  @override
  String toString() {
    final detail = [
      if (status != null) '$status',
      if (message != null && message!.isNotEmpty) message!,
    ].join(' ');
    return 'AppReferBillingException(${code.name}${detail.isEmpty ? '' : ': $detail'})';
  }
}
