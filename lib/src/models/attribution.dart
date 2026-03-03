import 'dart:convert';

class Attribution {
  final String network;
  final String? campaign;
  final String matchType; // 'adservices', 'click_id', 'referrer', 'organic'
  final String? attributionId;
  final String? campaignId;
  final String? campaignName;
  final String? adGroupId;
  final String? adId;
  final String? keyword;
  final String? fbclid;
  final String? gclid;
  final String? ttclid;
  final Map<String, dynamic> queryParams;
  final DateTime createdAt;

  const Attribution({
    required this.network,
    this.campaign,
    required this.matchType,
    this.attributionId,
    this.campaignId,
    this.campaignName,
    this.adGroupId,
    this.adId,
    this.keyword,
    this.fbclid,
    this.gclid,
    this.ttclid,
    this.queryParams = const {},
    required this.createdAt,
  });

  factory Attribution.fromJson(Map<String, dynamic> json) {
    return Attribution(
      network: json['network'] as String? ?? 'unknown',
      campaign: json['campaign'] as String?,
      matchType: json['match_type'] as String? ?? 'organic',
      attributionId: json['attribution_id'] as String?,
      campaignId: json['campaign_id'] as String?,
      campaignName: json['campaign_name'] as String?,
      adGroupId: json['ad_group_id'] as String?,
      adId: json['ad_id'] as String?,
      keyword: json['keyword'] as String?,
      fbclid: json['fbclid'] as String?,
      gclid: json['gclid'] as String?,
      ttclid: json['ttclid'] as String?,
      queryParams: json['query_params'] is Map
          ? Map<String, dynamic>.from(json['query_params'] as Map)
          : const {},
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'network': network,
      'campaign': campaign,
      'match_type': matchType,
      'attribution_id': attributionId,
      'campaign_id': campaignId,
      'campaign_name': campaignName,
      'ad_group_id': adGroupId,
      'ad_id': adId,
      'keyword': keyword,
      'fbclid': fbclid,
      'gclid': gclid,
      'ttclid': ttclid,
      'query_params': queryParams,
      'created_at': createdAt.toIso8601String(),
    };
  }

  String toJsonString() => jsonEncode(toJson());

  static Attribution? fromJsonString(String? jsonString) {
    if (jsonString == null) return null;
    try {
      return Attribution.fromJson(
        jsonDecode(jsonString) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  String toString() =>
      'Attribution(network: $network, matchType: $matchType, campaign: $campaignName)';
}
