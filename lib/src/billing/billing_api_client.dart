import '../services/tracking_consent.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:http/http.dart' as http;

import '../version.dart';
import 'billing_error.dart';
import 'customer_info.dart';
import 'offerings.dart';

/// One `/api/billing/v1/*` call.
sealed class BillingEndpoint {
  const BillingEndpoint();
}

class GetOfferings extends BillingEndpoint {
  final Map<String, dynamic> body;
  const GetOfferings(this.body);
}

class CreateCustomer extends BillingEndpoint {
  final String appUserId;
  final String? appreferId;
  final Map<String, String> attributes;
  const CreateCustomer(this.appUserId, this.appreferId, this.attributes);
}

class GetCustomer extends BillingEndpoint {
  final String appUserId;
  const GetCustomer(this.appUserId);
}

/// POST /purchases. [storeFields] holds the store-specific body: iOS
/// `{store: app_store, signedTransaction}`, Android `{store: play_store,
/// purchaseToken, productId, productType}`.
class RecordPurchase extends BillingEndpoint {
  final String appUserId;
  final String? appreferId;
  final Map<String, String> storeFields;
  final Map<String, String> attributes;

  /// True only for Restore Purchases: it lets the server move a purchase that
  /// already belongs to another app user to this one. Purchases and store
  /// updates (renewals included) never set it.
  final bool restore;
  final PresentedOfferingContext? presentedOfferingContext;
  final String? bucketId;
  const RecordPurchase(
    this.appUserId,
    this.appreferId,
    this.storeFields,
    this.attributes, {
    this.restore = false,
    this.presentedOfferingContext,
    this.bucketId,
  });
}

class Identify extends BillingEndpoint {
  final String anonymousId;
  final String appUserId;

  /// False while the install may not be linked (collection off, after reset
  /// until configure, Billing-only): the server then merges the purchases
  /// without copying the anonymous customer's attribution link.
  final bool link;
  const Identify(this.anonymousId, this.appUserId, {this.link = true});
}

/// Client for `/api/billing/v1/*`. Tries the tracking host first, then the main
/// host, like the attribution client.
class BillingApiClient {
  final List<String> baseUrls;
  final String? Function() apiKey;
  final http.Client _client;
  final Duration timeout;

  /// 100 ms polls while waiting for the SDK key.
  final int keyWaitAttempts;

  /// False while the install may not be linked (collection off, after reset
  /// until configure): requests then never use the tracking host.
  final Future<bool> Function()? linkAllowed;

  BillingApiClient({
    required List<String> baseUrls,
    required this.apiKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
    this.keyWaitAttempts = 30,
    this.linkAllowed,
  }) : baseUrls = baseUrls.toSet().toList(),
       _client = client ?? http.Client();

  static http.Request makeRequest(
    BillingEndpoint endpoint,
    String baseUrl,
    String apiKey,
  ) {
    final String path;
    var method = 'POST';
    Map<String, String>? query;
    Map<String, dynamic>? body;

    switch (endpoint) {
      case GetOfferings(:final body):
        path = '/api/billing/v1/offerings';
        // Assigned below using the outer request body.
        return _offeringsRequest(baseUrl, apiKey, body);
      case CreateCustomer(
        :final appUserId,
        :final appreferId,
        :final attributes,
      ):
        path = '/api/billing/v1/customers';
        body = {
          'appUserId': appUserId,
          if (appreferId != null) 'appreferId': appreferId,
          if (attributes.isNotEmpty) 'attributes': attributes,
        };
      case GetCustomer(:final appUserId):
        path = '/api/billing/v1/customers';
        method = 'GET';
        query = {'appUserId': appUserId};
      case RecordPurchase(
        :final appUserId,
        :final appreferId,
        :final storeFields,
        :final attributes,
        :final restore,
        :final presentedOfferingContext,
        :final bucketId,
      ):
        path = '/api/billing/v1/purchases';
        body = {
          'appUserId': appUserId,
          ...storeFields,
          if (appreferId != null) 'appreferId': appreferId,
          if (attributes.isNotEmpty) 'attributes': attributes,
          if (restore) 'restore': true,
          if (presentedOfferingContext != null)
            'presentedOfferingContext': presentedOfferingContext.toJson(),
          if (bucketId != null) 'bucketId': bucketId,
        };
      case Identify(:final anonymousId, :final appUserId, :final link):
        path = '/api/billing/v1/identify';
        body = {
          'anonymousId': anonymousId,
          'appUserId': appUserId,
          'link': link,
        };
    }

    final base = Uri.tryParse(baseUrl + path);
    if (base == null || base.host.isEmpty) {
      throw AppReferBillingException(
        AppReferBillingErrorCode.network,
        message: 'invalid base URL $baseUrl',
      );
    }
    final request = http.Request(
      method,
      query == null ? base : base.replace(queryParameters: query),
    );
    request.headers.addAll({
      'X-AppRefer-Key': apiKey,
      'X-SDK-Version': appReferVersion,
      'Accept': 'application/json',
    });
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    return request;
  }

  /// `AppReferSDK.configure` usually runs just before `AppReferBilling.configure`
  /// without being awaited, so give it a moment to register the key.
  Future<String?> _resolveApiKey() async {
    for (var attempt = 0; attempt <= keyWaitAttempts; attempt++) {
      final key = apiKey();
      if (key != null && key.isNotEmpty) return key;
      if (attempt < keyWaitAttempts) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    return null;
  }

  /// [linkAllowed], with an error (e.g. unreadable preferences) read as
  /// false, so the gate can never break a Billing request.
  Future<bool> _linkAllowedSafely() async {
    final gate = linkAllowed;
    if (gate == null) return true;
    try {
      return await gate();
    } catch (_) {
      return false;
    }
  }

  /// Sends the request. 5xx and network errors fail over to the next host; 4xx are final.
  static http.Request _offeringsRequest(
    String baseUrl,
    String apiKey,
    Map<String, dynamic> body,
  ) {
    return http.Request('POST', Uri.parse('$baseUrl/api/billing/v1/offerings'))
      ..headers.addAll({
        'X-AppRefer-Key': apiKey,
        'X-SDK-Version': appReferVersion,
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode(body);
  }

  Future<BillingCustomerResponse> send(BillingEndpoint endpoint) async =>
      BillingCustomerResponse.fromJson(await sendRaw(endpoint));
  Future<Map<String, dynamic>> sendRaw(BillingEndpoint endpoint) async {
    final key = await _resolveApiKey();
    if (key == null) {
      throw const AppReferBillingException(
        AppReferBillingErrorCode.missingApiKey,
      );
    }
    var lastError = const AppReferBillingException(
      AppReferBillingErrorCode.network,
      message: 'no endpoint',
    );
    // A host that answered with Retry-After asked for a pause; a later host
    // that merely could not be reached must not lose that.
    AppReferBillingException? pause;

    final hosts =
        baseUrls.length == 2 &&
            baseUrls[0] == 'https://trk.apprefer.com' &&
            baseUrls[1] == 'https://apprefer.com'
        ? TrackingConsent.hosts(
            await _linkAllowedSafely()
                ? await TrackingConsent.current()
                : 'denied',
            baseUrls,
          )
        : baseUrls;
    for (final baseUrl in hosts) {
      final request = makeRequest(endpoint, baseUrl, key);
      final http.Response response;
      try {
        response = await http.Response.fromStream(
          await _client.send(request),
        ).timeout(timeout);
      } catch (e) {
        lastError = AppReferBillingException(
          AppReferBillingErrorCode.network,
          message: e.toString(),
        );
        continue;
      }

      final status = response.statusCode;
      if (status >= 200 && status < 300) {
        final Map<String, dynamic> json;
        try {
          json = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
        } catch (_) {
          throw const AppReferBillingException(
            AppReferBillingErrorCode.invalidResponse,
          );
        }
        if (endpoint is RecordPurchase && !isRecorded(json)) {
          // Older servers answered 200 when the purchase was verified but not
          // recorded; treat it like today's 503 so the retry copy is kept.
          throw const AppReferBillingException(
            AppReferBillingErrorCode.server,
            status: 503,
            message: 'purchase verified but not recorded yet',
            retryAfter: legacyRetryAfter,
          );
        }
        try {
          return json;
        } catch (_) {
          throw const AppReferBillingException(
            AppReferBillingErrorCode.invalidResponse,
          );
        }
      }
      String? message;
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map && decoded['error'] is String) {
          message = decoded['error'] as String;
        }
      } catch (_) {}
      final error = AppReferBillingException(
        AppReferBillingErrorCode.server,
        status: status,
        message: message,
        retryAfter: parseRetryAfter(response.headers['retry-after']),
      );
      if (status >= 500) {
        lastError = error;
        if (error.retryAfter != null) pause = error;
        continue;
      }
      throw error;
    }
    throw lastError.retryAfter == null && pause != null ? pause : lastError;
  }

  /// The pause for a legacy "verified but not recorded" 200.
  static const legacyRetryAfter = Duration(seconds: 30);

  /// False only when a 2xx purchase answer says the ledger write failed.
  static bool isRecorded(Map<String, dynamic> json) {
    final purchase = json['purchase'];
    return purchase is! Map || purchase['conversion'] != 'failed';
  }

  /// `Retry-After` as delta-seconds or an HTTP date; null when absent or unreadable.
  static Duration? parseRetryAfter(String? value, {DateTime? now}) {
    if (value == null || value.trim().isEmpty) return null;
    final seconds = int.tryParse(value.trim());
    if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
    try {
      final at = HttpDate.parse(value.trim());
      final delta = at.difference(now ?? DateTime.now());
      return delta.isNegative ? Duration.zero : delta;
    } catch (_) {
      return null;
    }
  }
}
