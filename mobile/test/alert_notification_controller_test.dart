import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/controllers/alert_notification_controller.dart';
import 'package:radar_mobile/models/alert_notification_models.dart';
import 'package:radar_mobile/services/alert_notification_background.dart';
import 'package:radar_mobile/services/alert_notification_permissions.dart';
import 'package:radar_mobile/services/alert_notification_store.dart';

void main() {
  test('defaults are nearby life-threatening alerts and round trip', () {
    final defaults = AlertNotificationPreferences.defaults();
    expect(defaults.scope, AlertNotificationScope.nearby);
    expect(defaults.onboardingCompleted, isFalse);
    expect(defaults.monitoringEnabled, isFalse);
    expect(defaults.baselineGeneration, 0);
    expect(defaults.typeGeneration('Tornado Warning'), 0);
    expect(defaults.isEnabled(' Tornado Warning '), isTrue);
    expect(defaults.isEnabled('Air Quality Alert'), isFalse);

    final restored = AlertNotificationPreferences.fromJson(defaults.toJson());
    expect(restored.scope, defaults.scope);
    expect(restored.enabledTypes, defaults.enabledTypes);
    expect(restored.onboardingCompleted, isFalse);
    expect(restored.monitoringEnabled, isFalse);
    expect(restored.baselineGeneration, 0);
    expect(restored.typeGenerations, defaults.typeGenerations);
  });

  test('notification baseline generations persist across worker isolates', () {
    final preferences = AlertNotificationPreferences.defaults().copyWith(
      baselineGeneration: 4,
      typeGenerations: const {'Tornado Warning': 2},
    );
    final restoredPreferences = AlertNotificationPreferences.fromJson(
      preferences.toJson(),
    );
    expect(restoredPreferences.baselineGeneration, 4);
    expect(restoredPreferences.typeGeneration('tornado warning'), 2);

    final ledger = AlertNotificationLedger(
      initializedTypeGenerations: const {'Tornado Warning': 2},
      scope: AlertNotificationScope.nationwide,
      baselineGeneration: 4,
    );
    final restoredLedger = AlertNotificationLedger.fromJson(ledger.toJson());
    expect(restoredLedger.initializedTypeGenerations, {
      normalizeAlertType('Tornado Warning'): 2,
    });
    expect(restoredLedger.baselineGeneration, 4);
  });

  test(
    'declining onboarding cannot schedule work with pregranted permissions',
    () async {
      final store = _MemoryStore(AlertNotificationPreferences.defaults());
      final scheduler = _FakeScheduler();
      final controller = AlertNotificationController(
        store: store,
        permissions: _FakePermissions(_granted),
        scheduler: scheduler,
      );

      await controller.initialize();
      await controller.completeOnboarding(requestPermissions: false);

      expect(controller.preferences.monitoringEnabled, isFalse);
      expect(controller.backgroundWorkEnabled, isFalse);
      expect(scheduler.enabled, [false, false]);
      controller.dispose();
    },
  );

  test(
    'accepting onboarding explicitly enables the default monitoring',
    () async {
      final store = _MemoryStore(AlertNotificationPreferences.defaults());
      final scheduler = _FakeScheduler();
      final controller = AlertNotificationController(
        store: store,
        permissions: _FakePermissions(_granted),
        scheduler: scheduler,
      );

      await controller.initialize();
      await controller.completeOnboarding(requestPermissions: true);

      expect(controller.preferences.monitoringEnabled, isTrue);
      expect(controller.preferences.baselineGeneration, 1);
      expect(controller.backgroundWorkEnabled, isTrue);
      expect(scheduler.enabled, [false, true]);
      controller.dispose();
    },
  );

  test(
    'scheduler starts with permissions and stops when all types are off',
    () async {
      final store = _MemoryStore(
        AlertNotificationPreferences.defaults().copyWith(
          monitoringEnabled: true,
        ),
      );
      final scheduler = _FakeScheduler();
      final controller = AlertNotificationController(
        store: store,
        permissions: _FakePermissions(_granted),
        scheduler: scheduler,
      );

      await controller.initialize();
      expect(controller.backgroundWorkEnabled, isTrue);
      expect(scheduler.enabled, [true]);

      await controller.disableAll();
      expect(controller.preferences.enabledTypes, isEmpty);
      expect(controller.backgroundWorkEnabled, isFalse);
      expect(scheduler.enabled.last, isFalse);

      final pausedGeneration = controller.preferences.baselineGeneration;
      await controller.setAlertTypeEnabled('Tornado Warning', true);
      expect(controller.preferences.typeGeneration('Tornado Warning'), 1);
      await controller.setMonitoringEnabled(true);
      expect(controller.preferences.baselineGeneration, pausedGeneration + 1);
      controller.dispose();
    },
  );

  test(
    'nationwide runs without background location and nearby cannot be selected',
    () async {
      final store = _MemoryStore(
        AlertNotificationPreferences(
          enabledTypes: const ['Tornado Warning'],
          scope: AlertNotificationScope.nationwide,
          onboardingCompleted: true,
          monitoringEnabled: true,
        ),
      );
      final scheduler = _FakeScheduler();
      final controller = AlertNotificationController(
        store: store,
        permissions: _FakePermissions(_notificationsOnly),
        scheduler: scheduler,
      );

      await controller.initialize();
      expect(controller.backgroundWorkEnabled, isTrue);
      expect(scheduler.enabled.single, isTrue);

      await controller.setScope(AlertNotificationScope.nearby);
      expect(controller.preferences.scope, AlertNotificationScope.nationwide);
      controller.dispose();
    },
  );

  test(
    'denied permissions disable work and recovery opens app settings',
    () async {
      final store = _MemoryStore(AlertNotificationPreferences.defaults());
      final permissions = _FakePermissions(_denied);
      final scheduler = _FakeScheduler();
      final controller = AlertNotificationController(
        store: store,
        permissions: permissions,
        scheduler: scheduler,
      );

      await controller.initialize();
      expect(controller.needsOnboarding, isTrue);
      expect(controller.backgroundWorkEnabled, isFalse);
      expect(scheduler.enabled.single, isFalse);

      await controller.enableNotifications();
      expect(permissions.notificationRequests, 1);
      expect(permissions.settingsOpens, 1);

      await controller.completeOnboarding(requestPermissions: false);
      expect(controller.needsOnboarding, isFalse);
      expect(store.preferences.onboardingCompleted, isTrue);
      expect(store.preferences.monitoringEnabled, isFalse);
      expect(scheduler.enabled.last, isFalse);
      controller.dispose();
    },
  );
}

const _granted = AlertNotificationPermissionSnapshot(
  supported: true,
  notificationsGranted: true,
  foregroundLocationGranted: true,
  backgroundLocationGranted: true,
);

const _notificationsOnly = AlertNotificationPermissionSnapshot(
  supported: true,
  notificationsGranted: true,
  foregroundLocationGranted: true,
  backgroundLocationGranted: false,
);

const _denied = AlertNotificationPermissionSnapshot(
  supported: true,
  notificationsGranted: false,
  foregroundLocationGranted: true,
  backgroundLocationGranted: false,
  notificationsPermanentlyDenied: true,
);

final class _MemoryStore implements AlertNotificationStore {
  _MemoryStore(this.preferences);

  AlertNotificationPreferences preferences;
  AlertNotificationLedger ledger = AlertNotificationLedger();

  @override
  Future<AlertNotificationLedger> loadLedger() async => ledger;

  @override
  Future<AlertNotificationPreferences> loadPreferences() async => preferences;

  @override
  Future<void> saveLedger(AlertNotificationLedger value) async {
    ledger = value;
  }

  @override
  Future<void> savePreferences(AlertNotificationPreferences value) async {
    preferences = value;
  }
}

final class _FakePermissions implements AlertNotificationPermissionGateway {
  _FakePermissions(this.value);

  AlertNotificationPermissionSnapshot value;
  int notificationRequests = 0;
  int backgroundRequests = 0;
  int settingsOpens = 0;

  @override
  Future<bool> openSettings() async {
    settingsOpens++;
    return true;
  }

  @override
  Future<AlertNotificationPermissionSnapshot>
  requestBackgroundLocation() async {
    backgroundRequests++;
    return value;
  }

  @override
  Future<AlertNotificationPermissionSnapshot> requestNotifications() async {
    notificationRequests++;
    return value;
  }

  @override
  Future<AlertNotificationPermissionSnapshot> status() async => value;
}

final class _FakeScheduler implements AlertNotificationScheduler {
  final List<bool> enabled = [];

  @override
  Future<void> sync({required bool enabled}) async {
    this.enabled.add(enabled);
  }
}
