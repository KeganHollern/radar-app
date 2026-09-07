import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/alert_notification_models.dart';
import 'alert_local_notifier.dart';

const backgroundLocationDisclosureText =
    'HyprRadar collects location data to find and deliver Near me weather alerts even when the app is closed or not in use. For a Near me check, it rounds your current location to roughly 100 meters and sends it in an HTTPS request body through radar.lystic.dev to the National Weather Service to request alerts covering that point. The radar service actively removes the short-lived memory-cache entry and does not create a location history.\n\n'
    'Separately, while you use the map, HyprRadar saves a roughly 100-meter location on this device so the next launch can open nearby. It uses that saved location for no more than 30 days and deletes it when next read after it expires. Android backup rules exclude it. You can choose Nationwide alerts instead, which do not use location in the background.';

abstract interface class AlertNotificationPermissionGateway {
  Future<AlertNotificationPermissionSnapshot> status();

  Future<AlertNotificationPermissionSnapshot> requestNotifications();

  Future<AlertNotificationPermissionSnapshot> requestBackgroundLocation();

  Future<bool> openSettings();
}

final class PlatformAlertNotificationPermissionGateway
    implements AlertNotificationPermissionGateway {
  PlatformAlertNotificationPermissionGateway({
    bool? supported,
    AndroidFlutterLocalNotificationsPlugin? notifications,
  }) : _supported = supported ?? Platform.isAndroid,
       _notifications =
           notifications ?? AndroidFlutterLocalNotificationsPlugin();

  final bool _supported;
  final AndroidFlutterLocalNotificationsPlugin _notifications;

  @override
  Future<AlertNotificationPermissionSnapshot> status() async {
    if (!_supported) {
      return const AlertNotificationPermissionSnapshot.unsupported();
    }
    try {
      final notification = await Permission.notification.status;
      final channels = await _notifications.getNotificationChannels();
      final weatherChannel = channels
          ?.where(
            (channel) => channel.id == LocalWeatherAlertNotifier.channelId,
          )
          .firstOrNull;
      final foreground = await Permission.locationWhenInUse.status;
      final background = await Permission.locationAlways.status;
      return AlertNotificationPermissionSnapshot(
        supported: true,
        // Android can block one channel while the app-wide permission remains
        // granted. A successful show() then silently discards the notification.
        notificationsGranted:
            notification.isGranted &&
            weatherChannel?.importance != Importance.none,
        foregroundLocationGranted: foreground.isGranted,
        backgroundLocationGranted: background.isGranted,
        notificationsPermanentlyDenied: notification.isPermanentlyDenied,
        backgroundLocationPermanentlyDenied:
            background.isPermanentlyDenied || background.isRestricted,
      );
    } catch (_) {
      return const AlertNotificationPermissionSnapshot(
        supported: true,
        notificationsGranted: false,
        foregroundLocationGranted: false,
        backgroundLocationGranted: false,
      );
    }
  }

  @override
  Future<AlertNotificationPermissionSnapshot> requestNotifications() async {
    if (!_supported) return status();
    try {
      await Permission.notification.request();
    } catch (_) {
      // The settings recovery action remains available when a platform prompt
      // cannot be presented or has already been permanently dismissed.
    }
    return status();
  }

  @override
  Future<AlertNotificationPermissionSnapshot>
  requestBackgroundLocation() async {
    if (!_supported) return status();
    try {
      var foreground = await Permission.locationWhenInUse.status;
      if (!foreground.isGranted) {
        foreground = await Permission.locationWhenInUse.request();
      }
      if (foreground.isGranted) await Permission.locationAlways.request();
    } catch (_) {
      // Android 11+ can require the user to choose Allow all the time from the
      // app's system settings. The settings panel exposes that direct route.
    }
    return status();
  }

  @override
  Future<bool> openSettings() async {
    if (!_supported) return false;
    try {
      return await openAppSettings();
    } catch (_) {
      return false;
    }
  }
}
