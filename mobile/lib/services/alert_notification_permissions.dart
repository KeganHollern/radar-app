import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

import '../models/alert_notification_models.dart';

abstract interface class AlertNotificationPermissionGateway {
  Future<AlertNotificationPermissionSnapshot> status();

  Future<AlertNotificationPermissionSnapshot> requestNotifications();

  Future<AlertNotificationPermissionSnapshot> requestBackgroundLocation();

  Future<bool> openSettings();
}

final class PlatformAlertNotificationPermissionGateway
    implements AlertNotificationPermissionGateway {
  bool get _supported => Platform.isAndroid;

  @override
  Future<AlertNotificationPermissionSnapshot> status() async {
    if (!_supported) {
      return const AlertNotificationPermissionSnapshot.unsupported();
    }
    try {
      final notification = await Permission.notification.status;
      final foreground = await Permission.locationWhenInUse.status;
      final background = await Permission.locationAlways.status;
      return AlertNotificationPermissionSnapshot(
        supported: true,
        notificationsGranted: notification.isGranted,
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
      return openAppSettings();
    } catch (_) {
      return false;
    }
  }
}
