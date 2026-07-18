import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:workmanager/workmanager.dart';

import '../config/app_config.dart';
import 'alert_local_notifier.dart';
import 'alert_notification_api.dart';
import 'alert_notification_location.dart';
import 'alert_notification_permissions.dart';
import 'alert_notification_store.dart';
import 'alert_notification_worker.dart';

const alertNotificationTaskName = 'hyprradar.alert-notification-check.v1';
const alertNotificationUniqueWorkName =
    'hyprradar.periodic-alert-notification-check.v1';

@pragma('vm:entry-point')
void alertNotificationCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    if (taskName != alertNotificationTaskName) return true;

    HttpAlertNotificationApi? api;
    try {
      api = HttpAlertNotificationApi(
        baseUrl: AppConfig.apiBaseUrl,
        requestStateStore:
            SharedPreferencesAlertNotificationRequestStateStore(),
      );
      final result = await AlertNotificationWorker(
        store: SharedPreferencesAlertNotificationStore(),
        permissions: PlatformAlertNotificationPermissionGateway(),
        location: GeolocatorAlertNotificationLocationSource(),
        api: api,
        notifier: LocalWeatherAlertNotifier(),
      ).run();
      return result == AlertNotificationRunResult.success;
    } catch (_) {
      return false;
    } finally {
      api?.close();
    }
  });
}

Future<void> initializeAlertNotificationBackground() async {
  if (!Platform.isAndroid) return;
  await Workmanager().initialize(alertNotificationCallbackDispatcher);
}

abstract interface class AlertNotificationScheduler {
  Future<void> sync({required bool enabled});
}

final class WorkmanagerAlertNotificationScheduler
    implements AlertNotificationScheduler {
  @override
  Future<void> sync({required bool enabled}) async {
    if (!Platform.isAndroid) return;
    if (!enabled) {
      await Workmanager().cancelByUniqueName(alertNotificationUniqueWorkName);
      return;
    }
    await Workmanager().registerPeriodicTask(
      alertNotificationUniqueWorkName,
      alertNotificationTaskName,
      frequency: const Duration(minutes: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 10),
    );
  }
}
