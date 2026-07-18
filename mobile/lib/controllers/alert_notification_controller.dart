import 'package:flutter/foundation.dart';

import '../models/alert_notification_models.dart';
import '../services/alert_notification_background.dart';
import '../services/alert_notification_permissions.dart';
import '../services/alert_notification_store.dart';

final class AlertNotificationController extends ChangeNotifier {
  AlertNotificationController({
    AlertNotificationStore? store,
    AlertNotificationPermissionGateway? permissions,
    AlertNotificationScheduler? scheduler,
  }) : _store = store ?? SharedPreferencesAlertNotificationStore(),
       _permissions =
           permissions ?? PlatformAlertNotificationPermissionGateway(),
       _scheduler = scheduler ?? WorkmanagerAlertNotificationScheduler();

  final AlertNotificationStore _store;
  final AlertNotificationPermissionGateway _permissions;
  final AlertNotificationScheduler _scheduler;

  AlertNotificationPreferences _preferences =
      AlertNotificationPreferences.defaults();
  AlertNotificationPermissionSnapshot _permission =
      const AlertNotificationPermissionSnapshot.unsupported();
  bool _initialized = false;
  bool _busy = false;
  bool _schedulerHealthy = true;

  AlertNotificationPreferences get preferences => _preferences;
  AlertNotificationPermissionSnapshot get permission => _permission;
  bool get initialized => _initialized;
  bool get busy => _busy;
  bool get needsOnboarding =>
      _initialized &&
      _permission.supported &&
      !_preferences.onboardingCompleted;

  bool get backgroundWorkEnabled =>
      _preferences.monitoringEnabled &&
      _preferences.enabledTypes.isNotEmpty &&
      _permission.supported &&
      _permission.notificationsGranted &&
      (_preferences.scope == AlertNotificationScope.nationwide ||
          _permission.backgroundLocationGranted);
  bool get backgroundWorkActive => backgroundWorkEnabled && _schedulerHealthy;

  bool isAlertTypeEnabled(String type) => _preferences.isEnabled(type);

  List<String> alertTypes(Iterable<String> learnedTypes) =>
      mergedAlertNotificationTypes(learnedTypes);

  Future<void> initialize() async {
    _preferences = await _store.loadPreferences();
    _permission = await _permissions.status();
    _initialized = true;
    await _syncScheduler();
    notifyListeners();
  }

  Future<void> refreshPermissions() async {
    if (!_initialized) return initialize();
    _permission = await _permissions.status();
    await _syncScheduler();
    notifyListeners();
  }

  Future<void> completeOnboarding({required bool requestPermissions}) async {
    if (_busy) return;
    _setBusy(true);
    try {
      if (requestPermissions) {
        _permission = await _permissions.requestNotifications();
        if (_permission.notificationsGranted &&
            _preferences.scope == AlertNotificationScope.nearby) {
          _permission = await _permissions.requestBackgroundLocation();
        }
      }
      _preferences = _preferences.copyWith(
        onboardingCompleted: true,
        monitoringEnabled: requestPermissions,
        baselineGeneration:
            requestPermissions && !_preferences.monitoringEnabled
            ? _preferences.baselineGeneration + 1
            : _preferences.baselineGeneration,
      );
      await _store.savePreferences(_preferences);
      await _syncScheduler();
    } finally {
      _setBusy(false);
    }
  }

  Future<void> setAlertTypeEnabled(String type, bool enabled) async {
    if (_busy || !_permission.notificationsGranted) return;
    final normalized = normalizeAlertType(type);
    if (normalized.isEmpty) return;
    final types = Set<String>.of(_preferences.enabledTypes);
    final changed = enabled ? types.add(normalized) : types.remove(normalized);
    if (!changed) return;
    final typeGenerations = Map<String, int>.of(_preferences.typeGenerations);
    if (enabled) {
      typeGenerations[normalized] = _preferences.typeGeneration(normalized) + 1;
    }
    _preferences = _preferences.copyWith(
      enabledTypes: types,
      monitoringEnabled: types.isEmpty ? false : _preferences.monitoringEnabled,
      typeGenerations: typeGenerations,
    );
    notifyListeners();
    await _store.savePreferences(_preferences);
    await _syncScheduler();
    notifyListeners();
  }

  Future<void> setMonitoringEnabled(bool enabled) async {
    if (_busy ||
        (enabled && !_permission.notificationsGranted) ||
        _preferences.monitoringEnabled == enabled) {
      return;
    }
    _preferences = _preferences.copyWith(
      monitoringEnabled: enabled,
      baselineGeneration: enabled
          ? _preferences.baselineGeneration + 1
          : _preferences.baselineGeneration,
    );
    notifyListeners();
    await _store.savePreferences(_preferences);
    await _syncScheduler();
    notifyListeners();
  }

  Future<void> setScope(AlertNotificationScope scope) async {
    if (_busy || !_permission.notificationsGranted) return;
    if (scope == AlertNotificationScope.nearby &&
        !_permission.backgroundLocationGranted) {
      return;
    }
    if (_preferences.scope == scope) return;
    _preferences = _preferences.copyWith(scope: scope);
    notifyListeners();
    await _store.savePreferences(_preferences);
    await _syncScheduler();
    notifyListeners();
  }

  Future<void> disableAll() async {
    if (_busy || _preferences.enabledTypes.isEmpty) return;
    _preferences = _preferences.copyWith(
      enabledTypes: const <String>[],
      monitoringEnabled: false,
    );
    notifyListeners();
    await _store.savePreferences(_preferences);
    await _syncScheduler();
    notifyListeners();
  }

  Future<void> enableNotifications() async {
    if (_busy) return;
    _setBusy(true);
    try {
      _permission = await _permissions.requestNotifications();
      _preferences = _preferences.copyWith(
        monitoringEnabled: true,
        onboardingCompleted: true,
        baselineGeneration: !_preferences.monitoringEnabled
            ? _preferences.baselineGeneration + 1
            : _preferences.baselineGeneration,
      );
      await _store.savePreferences(_preferences);
      if (!_permission.notificationsGranted) {
        await _permissions.openSettings();
      }
      await _syncScheduler();
    } finally {
      _setBusy(false);
    }
  }

  Future<void> enableBackgroundLocation() async {
    if (_busy) return;
    _setBusy(true);
    try {
      _permission = await _permissions.requestBackgroundLocation();
      if (!_permission.backgroundLocationGranted) {
        await _permissions.openSettings();
      }
      await _syncScheduler();
    } finally {
      _setBusy(false);
    }
  }

  Future<void> openPermissionSettings() => _permissions.openSettings();

  Future<void> _syncScheduler() async {
    try {
      await _scheduler.sync(enabled: backgroundWorkEnabled);
      _schedulerHealthy = true;
    } catch (_) {
      // A scheduler failure must not break the foreground radar experience.
      // The next launch, resume, or preference change will reconcile it again.
      _schedulerHealthy = false;
    }
  }

  void _setBusy(bool value) {
    _busy = value;
    notifyListeners();
  }
}
