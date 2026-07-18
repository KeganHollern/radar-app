import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/radar_models.dart';

abstract interface class WeatherAlertNotifier {
  Future<void> initialize();

  Future<void> show(WeatherAlert alert);
}

final class LocalWeatherAlertNotifier implements WeatherAlertNotifier {
  LocalWeatherAlertNotifier({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const channelId = 'hyprradar_weather_alerts_v1';
  static const channelName = 'Weather alerts';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_radar'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestSoundPermission: false,
          requestBadgePermission: false,
        ),
      ),
    );
    _initialized = true;
  }

  @override
  Future<void> show(WeatherAlert alert) async {
    await initialize();
    final body = _notificationBody(alert);
    await _plugin.show(
      id: stableAlertNotificationId(alert.id),
      title: alert.event,
      body: body,
      payload: alert.id,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription:
              'Selected live National Weather Service alert types.',
          icon: 'ic_stat_radar',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.event,
          visibility: NotificationVisibility.public,
          groupKey: 'hyprradar.weather-alerts',
          onlyAlertOnce: true,
          styleInformation: BigTextStyleInformation(body),
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBanner: true,
          presentList: true,
          presentSound: true,
        ),
      ),
    );
  }
}

String _notificationBody(WeatherAlert alert) {
  final headline = alert.headline.trim();
  if (headline.isNotEmpty &&
      headline.toLowerCase() != alert.event.trim().toLowerCase()) {
    return headline;
  }
  final description = alert.description.trim();
  if (description.isNotEmpty) {
    return description.length <= 240
        ? description
        : '${description.substring(0, 237)}…';
  }
  return 'A new ${alert.event} is active.';
}

int stableAlertNotificationId(String value) {
  var hash = 0x811C9DC5;
  for (final byte in value.codeUnits) {
    hash ^= byte;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}
