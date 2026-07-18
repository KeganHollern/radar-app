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
  Future<void> _sideEffects = Future<void>.value();

  AlertNotificationPreferences get preferences => _preferences;
  AlertNotificationPermissionSnapshot get permission => _permission;
  bool get initialized => _initialized;
  bool get busy => _busy;
  bool get needsOnboarding =>
      _initialized &&
      _permission.supported &&
      !_preferences.onboardingCompleted;

  bool get backgroundWorkEnabled =>
      _backgroundWorkEnabledFor(_preferences, _permission);
  bool get backgroundWorkActive => backgroundWorkEnabled && _schedulerHealthy;

  bool isAlertTypeEnabled(String type) => _preferences.isEnabled(type);

  List<String> alertTypes(Iterable<String> learnedTypes) =>
      mergedAlertNotificationTypes(learnedTypes);

  Future<void> initialize() async {
    _preferences = await _store.loadPreferences();
    _permission = await _permissions.status();
    _initialized = true;
    await _queueSchedulerSync(backgroundWorkEnabled);
    notifyListeners();
  }

  Future<void> refreshPermissions() async {
    if (!_initialized) return initialize();
    _permission = await _permissions.status();
    await _queueSchedulerSync(backgroundWorkEnabled);
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
      await _queuePreferencesCommit(
        _preferences,
        schedulerEnabled: backgroundWorkEnabled,
      );
    } finally {
      _setBusy(false);
    }
  }

  Future<void> setAlertTypeEnabled(String type, bool enabled) async {
    if (_busy || !_permission.notificationsGranted) return;
    final wasBackgroundWorkEnabled = backgroundWorkEnabled;
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
    final shouldEnableBackgroundWork = backgroundWorkEnabled;
    await _queuePreferencesCommit(
      _preferences,
      schedulerEnabled: wasBackgroundWorkEnabled == shouldEnableBackgroundWork
          ? null
          : shouldEnableBackgroundWork,
    );
    if (wasBackgroundWorkEnabled != shouldEnableBackgroundWork) {
      notifyListeners();
    }
  }

  Future<void> setMonitoringEnabled(bool enabled) async {
    if (_busy ||
        (enabled && !_permission.notificationsGranted) ||
        _preferences.monitoringEnabled == enabled) {
      return;
    }
    final wasBackgroundWorkEnabled = backgroundWorkEnabled;
    _preferences = _preferences.copyWith(
      monitoringEnabled: enabled,
      baselineGeneration: enabled
          ? _preferences.baselineGeneration + 1
          : _preferences.baselineGeneration,
    );
    notifyListeners();
    final shouldEnableBackgroundWork = backgroundWorkEnabled;
    await _queuePreferencesCommit(
      _preferences,
      schedulerEnabled: wasBackgroundWorkEnabled == shouldEnableBackgroundWork
          ? null
          : shouldEnableBackgroundWork,
    );
    if (wasBackgroundWorkEnabled != shouldEnableBackgroundWork) {
      notifyListeners();
    }
  }

  Future<void> setScope(AlertNotificationScope scope) async {
    if (_busy || !_permission.notificationsGranted) return;
    if (scope == AlertNotificationScope.nearby &&
        !_permission.backgroundLocationGranted) {
      return;
    }
    if (_preferences.scope == scope) return;
    final wasBackgroundWorkEnabled = backgroundWorkEnabled;
    _preferences = _preferences.copyWith(scope: scope);
    notifyListeners();
    final shouldEnableBackgroundWork = backgroundWorkEnabled;
    await _queuePreferencesCommit(
      _preferences,
      schedulerEnabled: wasBackgroundWorkEnabled == shouldEnableBackgroundWork
          ? null
          : shouldEnableBackgroundWork,
    );
    if (wasBackgroundWorkEnabled != shouldEnableBackgroundWork) {
      notifyListeners();
    }
  }

  Future<void> disableAll() async {
    if (_busy || _preferences.enabledTypes.isEmpty) return;
    final wasBackgroundWorkEnabled = backgroundWorkEnabled;
    _preferences = _preferences.copyWith(
      enabledTypes: const <String>[],
      monitoringEnabled: false,
    );
    notifyListeners();
    final shouldEnableBackgroundWork = backgroundWorkEnabled;
    await _queuePreferencesCommit(
      _preferences,
      schedulerEnabled: wasBackgroundWorkEnabled == shouldEnableBackgroundWork
          ? null
          : shouldEnableBackgroundWork,
    );
    if (wasBackgroundWorkEnabled != shouldEnableBackgroundWork) {
      notifyListeners();
    }
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
      await _queuePreferencesCommit(
        _preferences,
        schedulerEnabled: backgroundWorkEnabled,
      );
      if (!_permission.notificationsGranted) {
        await _permissions.openSettings();
      }
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
      await _queueSchedulerSync(backgroundWorkEnabled);
    } finally {
      _setBusy(false);
    }
  }

  Future<void> openPermissionSettings() => _permissions.openSettings();

  Future<void> _queuePreferencesCommit(
    AlertNotificationPreferences preferences, {
    bool? schedulerEnabled,
  }) => _enqueueSideEffect(() async {
    await _store.savePreferences(preferences);
    if (schedulerEnabled != null) {
      await _syncScheduler(schedulerEnabled);
    }
  });

  Future<void> _queueSchedulerSync(bool enabled) =>
      _enqueueSideEffect(() => _syncScheduler(enabled));

  Future<void> _enqueueSideEffect(Future<void> Function() operation) {
    final result = _sideEffects.then((_) => operation());
    _sideEffects = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  Future<void> _syncScheduler(bool enabled) async {
    try {
      await _scheduler.sync(enabled: enabled);
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

bool _backgroundWorkEnabledFor(
  AlertNotificationPreferences preferences,
  AlertNotificationPermissionSnapshot permission,
) =>
    preferences.monitoringEnabled &&
    preferences.enabledTypes.isNotEmpty &&
    permission.supported &&
    permission.notificationsGranted &&
    (preferences.scope == AlertNotificationScope.nationwide ||
        permission.backgroundLocationGranted);
