import '../models/alert_notification_models.dart';
import '../models/radar_models.dart';
import 'alert_local_notifier.dart';
import 'alert_notification_api.dart';
import 'alert_notification_location.dart';
import 'alert_notification_permissions.dart';
import 'alert_notification_store.dart';

enum AlertNotificationRunResult { success, retry }

final class AlertNotificationWorker {
  AlertNotificationWorker({
    required AlertNotificationStore store,
    required AlertNotificationPermissionGateway permissions,
    required AlertNotificationLocationSource location,
    required AlertNotificationApi api,
    required WeatherAlertNotifier notifier,
    DateTime Function()? now,
  }) : _store = store,
       _permissions = permissions,
       _location = location,
       _api = api,
       _notifier = notifier,
       _now = now ?? DateTime.now;

  static const _fallbackRetention = Duration(days: 2);
  static const _retentionAfterExpiry = Duration(days: 1);

  final AlertNotificationStore _store;
  final AlertNotificationPermissionGateway _permissions;
  final AlertNotificationLocationSource _location;
  final AlertNotificationApi _api;
  final WeatherAlertNotifier _notifier;
  final DateTime Function() _now;

  Future<AlertNotificationRunResult> run() async {
    try {
      return await _run();
    } catch (_) {
      // An unexpected plugin or persistence failure should use WorkManager's
      // retry path instead of permanently failing the periodic work chain.
      return AlertNotificationRunResult.retry;
    }
  }

  Future<AlertNotificationRunResult> _run() async {
    final preferences = await _store.loadPreferences();
    if (!preferences.monitoringEnabled || preferences.enabledTypes.isEmpty) {
      return AlertNotificationRunResult.success;
    }

    final permission = await _permissions.status();
    if (!permission.supported || !permission.notificationsGranted) {
      return AlertNotificationRunResult.success;
    }

    AlertNotificationPoint? point;
    if (preferences.scope == AlertNotificationScope.nearby) {
      if (!permission.backgroundLocationGranted) {
        return AlertNotificationRunResult.success;
      }
      point = await _location.currentLocation();
      if (point == null) return AlertNotificationRunResult.success;
    }

    final previous = await _store.loadLedger();
    final scopeChanged = previous.scope != preferences.scope;
    final baselineChanged =
        previous.baselineGeneration != preferences.baselineGeneration;
    final initializedTypeGenerations = scopeChanged || baselineChanged
        ? <String, int>{}
        : Map<String, int>.of(previous.initializedTypeGenerations);
    final newlyInitializedTypes = {
      for (final type in preferences.enabledTypes)
        if (initializedTypeGenerations[type] !=
            preferences.typeGeneration(type))
          type,
    };

    late final AlertNotificationFetchResult fetch;
    try {
      fetch = await _api.fetchActiveAlerts(
        scope: preferences.scope,
        point: point,
        bypassCache:
            scopeChanged || baselineChanged || newlyInitializedTypes.isNotEmpty,
      );
    } on AlertNotificationApiException catch (error) {
      return error.transient
          ? AlertNotificationRunResult.retry
          : AlertNotificationRunResult.success;
    } catch (_) {
      return AlertNotificationRunResult.retry;
    }
    if (fetch.notModified) return AlertNotificationRunResult.success;
    final alerts = fetch.alerts;

    final now = _now().toUtc();
    final seenUntil = <String, int>{
      for (final entry in previous.seenUntilEpochMs.entries)
        if (entry.value > now.millisecondsSinceEpoch) entry.key: entry.value,
    };
    final baselineUntil = <String, int>{
      for (final entry in previous.baselineUntilEpochMs.entries)
        if (entry.value > now.millisecondsSinceEpoch) entry.key: entry.value,
    };

    for (final alert in alerts) {
      final type = normalizeAlertType(alert.event);
      if (!preferences.enabledTypes.contains(type) ||
          !_isCurrentlyActive(alert, now)) {
        continue;
      }

      final retainUntil = _retainUntil(alert, now).millisecondsSinceEpoch;
      if (_referencesSeenAlert(alert, seenUntil)) {
        seenUntil[alert.id] = retainUntil;
        continue;
      }
      if (seenUntil.containsKey(alert.id)) {
        if (retainUntil > seenUntil[alert.id]!) {
          seenUntil[alert.id] = retainUntil;
        }
        continue;
      }
      if (preferences.scope == AlertNotificationScope.nationwide) {
        if (_referencesSeenAlert(alert, baselineUntil)) {
          baselineUntil[alert.id] = retainUntil;
          continue;
        }
        if (baselineUntil.containsKey(alert.id)) {
          if (retainUntil > baselineUntil[alert.id]!) {
            baselineUntil[alert.id] = retainUntil;
          }
          continue;
        }
      }

      // A first nationwide check establishes a clean baseline instead of
      // dumping every already-active alert in the country into the tray.
      // Nearby defaults intentionally surface a warning already covering the
      // user when monitoring is first enabled.
      if (preferences.scope == AlertNotificationScope.nationwide &&
          newlyInitializedTypes.contains(type)) {
        baselineUntil[alert.id] = retainUntil;
        continue;
      }

      try {
        await _notifier.show(alert);
      } catch (_) {
        await _store.saveLedger(
          _ledger(
            seenUntil: seenUntil,
            baselineUntil: baselineUntil,
            initializedTypeGenerations: initializedTypeGenerations,
            scope: previous.scope,
            baselineGeneration: previous.baselineGeneration,
          ),
        );
        return AlertNotificationRunResult.retry;
      }
      seenUntil[alert.id] = retainUntil;

      // Persist after each displayed alert so a later failure cannot replay
      // notifications that were already delivered during this worker run.
      await _store.saveLedger(
        _ledger(
          seenUntil: seenUntil,
          baselineUntil: baselineUntil,
          initializedTypeGenerations: initializedTypeGenerations,
          scope: previous.scope,
          baselineGeneration: previous.baselineGeneration,
        ),
      );
    }

    initializedTypeGenerations.removeWhere(
      (type, _) => !preferences.enabledTypes.contains(type),
    );
    for (final type in preferences.enabledTypes) {
      initializedTypeGenerations[type] = preferences.typeGeneration(type);
    }
    await _store.saveLedger(
      _ledger(
        seenUntil: seenUntil,
        baselineUntil: baselineUntil,
        initializedTypeGenerations: initializedTypeGenerations,
        scope: preferences.scope,
        baselineGeneration: preferences.baselineGeneration,
      ),
    );
    await _api.acknowledge(fetch);
    return AlertNotificationRunResult.success;
  }

  bool _isCurrentlyActive(WeatherAlert alert, DateTime now) {
    final effective = alert.effective?.toUtc();
    final expires = alert.expires?.toUtc();
    if (effective != null && effective.isAfter(now)) return false;
    if (expires != null && !expires.isAfter(now)) return false;
    return true;
  }

  DateTime _retainUntil(WeatherAlert alert, DateTime now) {
    final expires = alert.expires?.toUtc();
    if (expires == null || expires.isBefore(now)) {
      return now.add(_fallbackRetention);
    }
    return expires.add(_retentionAfterExpiry);
  }

  bool _referencesSeenAlert(WeatherAlert alert, Map<String, int> seenUntil) {
    final properties = alert.feature['properties'];
    if (properties is! Map) return false;
    final references = properties['references'];
    if (references is! List) return false;
    for (final reference in references) {
      if (reference is String && seenUntil.containsKey(reference.trim())) {
        return true;
      }
      if (reference is Map) {
        for (final key in const ['identifier', 'id', '@id']) {
          final id = reference[key]?.toString().trim();
          if (id != null && id.isNotEmpty && seenUntil.containsKey(id)) {
            return true;
          }
        }
      }
    }
    return false;
  }

  AlertNotificationLedger _ledger({
    required Map<String, int> seenUntil,
    required Map<String, int> baselineUntil,
    required Map<String, int> initializedTypeGenerations,
    required AlertNotificationScope? scope,
    required int baselineGeneration,
  }) {
    return AlertNotificationLedger(
      seenUntilEpochMs: seenUntil,
      baselineUntilEpochMs: baselineUntil,
      initializedTypeGenerations: initializedTypeGenerations,
      scope: scope,
      baselineGeneration: baselineGeneration,
    );
  }
}
