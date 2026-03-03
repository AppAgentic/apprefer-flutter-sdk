import 'event_type.dart';

class AppReferEvent {
  final String eventName;
  final EventType eventType;
  final Map<String, dynamic>? properties;
  final double? revenue;
  final String? currency;
  final DateTime timestamp;
  final String deviceId;

  const AppReferEvent({
    required this.eventName,
    required this.eventType,
    this.properties,
    this.revenue,
    this.currency,
    required this.timestamp,
    required this.deviceId,
  });

  Map<String, dynamic> toJson() {
    return {
      'event_name': eventName,
      'event_type': eventType.value,
      if (properties != null && properties!.isNotEmpty)
        'properties': properties,
      if (revenue != null) 'revenue': revenue,
      if (currency != null) 'currency': currency,
      'timestamp': timestamp.toIso8601String(),
      'device_id': deviceId,
    };
  }
}
