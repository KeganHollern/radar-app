import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/models/alert_notification_models.dart';
import 'package:radar_mobile/models/radar_models.dart';
import 'package:radar_mobile/services/alert_local_notifier.dart';
import 'package:radar_mobile/services/alert_notification_api.dart';
import 'package:radar_mobile/services/alert_notification_location.dart';
import 'package:radar_mobile/services/alert_notification_permissions.dart';
import 'package:radar_mobile/services/alert_notification_store.dart';
import 'package:radar_mobile/services/alert_notification_worker.dart';

void main() {
  final now = DateTime.utc(2026, 7, 17, 18);

  test(
    'disabled notifications do no permission, location, or network work',
    () async {
      final store = _MemoryStore(
        AlertNotificationPreferences(
          enabledTypes: const [],
          onboardingCompleted: true,
          monitoringEnabled: true,
        ),
      );
      final permissions = _FakePermissions(_grantedPermissions);
      final location = _FakeLocation(_point(now));
      final api = _FakeApi(const []);
      final notifier = _FakeNotifier();

      final result = await _worker(
        store: store,
        permissions: permissions,
        location: location,
        api: api,
        notifier: notifier,
        now: now,
      ).run();

      expect(result, AlertNotificationRunResult.success);
      expect(permissions.statusCalls, 0);
      expect(location.calls, 0);
      expect(api.calls, 0);
      expect(notifier.alerts, isEmpty);
    },
  );

  test(
    'nationwide baseline skips location and only notifies later alerts',
    () async {
      final store = _MemoryStore(
        AlertNotificationPreferences(
          enabledTypes: const ['Tornado Warning'],
          scope: AlertNotificationScope.nationwide,
          onboardingCompleted: true,
          monitoringEnabled: true,
        ),
      );
      final permissions = _FakePermissions(
        const AlertNotificationPermissionSnapshot(
          supported: true,
          notificationsGranted: true,
          foregroundLocationGranted: false,
          backgroundLocationGranted: false,
        ),
      );
      final location = _FakeLocation(null);
      final first = _alert('existing', now: now);
      final api = _FakeApi([first]);
      final notifier = _FakeNotifier();
      final worker = _worker(
        store: store,
        permissions: permissions,
        location: location,
        api: api,
        notifier: notifier,
        now: now,
      );

      expect(await worker.run(), AlertNotificationRunResult.success);
      expect(location.calls, 0);
      expect(notifier.alerts, isEmpty);

      api.alerts = [first, _alert('new', now: now)];
      expect(await worker.run(), AlertNotificationRunResult.success);
      expect(location.calls, 0);
      expect(notifier.alerts.map((alert) => alert.id), ['new']);
    },
  );

  test(
    'nearby monitoring sends a rounded point and deduplicates alerts',
    () async {
      final store = _MemoryStore(
        AlertNotificationPreferences(
          enabledTypes: const ['Tornado Warning'],
          onboardingCompleted: true,
          monitoringEnabled: true,
        ),
      );
      final location = _FakeLocation(_point(now));
      final api = _FakeApi([_alert('local', now: now)]);
      final notifier = _FakeNotifier();
      final worker = _worker(
        store: store,
        permissions: _FakePermissions(_grantedPermissions),
        location: location,
        api: api,
        notifier: notifier,
        now: now,
      );

      expect(await worker.run(), AlertNotificationRunResult.success);
      expect(await worker.run(), AlertNotificationRunResult.success);

      expect(location.calls, 2);
      expect(api.points, hasLength(2));
      expect(api.points.first?.latitude, 30.2672);
      expect(notifier.alerts.map((alert) => alert.id), ['local']);
    },
  );

  test(
    'nationwide baseline does not suppress a later nearby warning',
    () async {
      final store = _MemoryStore(
        AlertNotificationPreferences(
          enabledTypes: const ['Tornado Warning'],
          scope: AlertNotificationScope.nationwide,
          onboardingCompleted: true,
          monitoringEnabled: true,
        ),
      );
      final alert = _alert('covers-user', now: now);
      final api = _FakeApi([alert]);
      final notifier = _FakeNotifier();
      final worker = _worker(
        store: store,
        permissions: _FakePermissions(_grantedPermissions),
        location: _FakeLocation(_point(now)),
        api: api,
        notifier: notifier,
        now: now,
      );

      await worker.run();
      expect(notifier.alerts, isEmpty);
      expect(store.ledger.baselineUntilEpochMs, contains('covers-user'));

      store.preferences = store.preferences.copyWith(
        scope: AlertNotificationScope.nearby,
      );
      await worker.run();
      expect(notifier.alerts.map((item) => item.id), ['covers-user']);
      expect(store.ledger.seenUntilEpochMs, contains('covers-user'));
    },
  );

  test('nationwide baseline retains every live alert identity', () async {
    final store = _MemoryStore(
      AlertNotificationPreferences(
        enabledTypes: const ['Tornado Warning'],
        scope: AlertNotificationScope.nationwide,
        onboardingCompleted: true,
        monitoringEnabled: true,
      ),
    );
    final alerts = [
      for (var index = 0; index < 1105; index++)
        _alert('baseline-$index', now: now),
    ];
    final notifier = _FakeNotifier();

    final result = await _worker(
      store: store,
      permissions: _FakePermissions(_grantedPermissions),
      location: _FakeLocation(null),
      api: _FakeApi(alerts),
      notifier: notifier,
      now: now,
    ).run();

    expect(result, AlertNotificationRunResult.success);
    expect(notifier.alerts, isEmpty);
    expect(store.ledger.baselineUntilEpochMs, hasLength(1105));
  });

  test(
    'resuming nationwide monitoring baselines alerts accumulated while off',
    () async {
      final store = _MemoryStore(
        AlertNotificationPreferences(
          enabledTypes: const ['Tornado Warning'],
          scope: AlertNotificationScope.nationwide,
          onboardingCompleted: true,
          monitoringEnabled: true,
          baselineGeneration: 1,
        ),
      );
      final existing = _alert('existing', now: now);
      final whilePaused = _alert('while-paused', now: now);
      final afterResume = _alert('after-resume', now: now);
      final api = _FakeApi([existing]);
      final notifier = _FakeNotifier();
      final worker = _worker(
        store: store,
        permissions: _FakePermissions(_grantedPermissions),
        location: _FakeLocation(null),
        api: api,
        notifier: notifier,
        now: now,
      );

      await worker.run();
      store.preferences = store.preferences.copyWith(monitoringEnabled: false);
      api.alerts = [existing, whilePaused];
      await worker.run();
      expect(api.calls, 1);

      store.preferences = store.preferences.copyWith(
        monitoringEnabled: true,
        baselineGeneration: 2,
      );
      await worker.run();
      expect(notifier.alerts, isEmpty);
      expect(store.ledger.baselineUntilEpochMs, contains('while-paused'));

      api.alerts = [existing, whilePaused, afterResume];
      await worker.run();
      expect(notifier.alerts.map((alert) => alert.id), ['after-resume']);
    },
  );

  test(
    'a newly enabled nationwide type bypasses cache and baselines',
    () async {
      final store =
          _MemoryStore(
              AlertNotificationPreferences(
                enabledTypes: const ['Tornado Warning', 'Flash Flood Warning'],
                scope: AlertNotificationScope.nationwide,
                onboardingCompleted: true,
                monitoringEnabled: true,
                typeGenerations: const {'Flash Flood Warning': 1},
              ),
            )
            ..ledger = AlertNotificationLedger(
              initializedTypeGenerations: const {'Tornado Warning': 0},
              scope: AlertNotificationScope.nationwide,
              baselineGeneration: 0,
            );
      final api = _FakeApi([
        _alert('new-tornado', now: now),
        _alert('newly-enabled', now: now, event: 'Flash Flood Warning'),
      ]);
      final notifier = _FakeNotifier();

      expect(
        await _worker(
          store: store,
          permissions: _FakePermissions(_grantedPermissions),
          location: _FakeLocation(null),
          api: api,
          notifier: notifier,
          now: now,
        ).run(),
        AlertNotificationRunResult.success,
      );

      expect(api.bypassCacheValues, [true]);
      expect(notifier.alerts.map((alert) => alert.id), ['new-tornado']);
      expect(store.ledger.seenUntilEpochMs, contains('new-tornado'));
      expect(store.ledger.baselineUntilEpochMs, contains('newly-enabled'));
      expect(
        store.ledger.initializedTypes,
        contains(normalizeAlertType('Flash Flood Warning')),
      );
    },
  );

  test(
    'an update referencing a seen alert does not stack a duplicate',
    () async {
      final store = _MemoryStore(
        AlertNotificationPreferences(
          enabledTypes: const ['Tornado Warning'],
          onboardingCompleted: true,
          monitoringEnabled: true,
        ),
      );
      final api = _FakeApi([_alert('original', now: now)]);
      final notifier = _FakeNotifier();
      final worker = _worker(
        store: store,
        permissions: _FakePermissions(_grantedPermissions),
        location: _FakeLocation(_point(now)),
        api: api,
        notifier: notifier,
        now: now,
      );
      await worker.run();

      api.alerts = [
        _alert('update', now: now, references: const ['original']),
      ];
      await worker.run();

      expect(notifier.alerts.map((alert) => alert.id), ['original']);
      expect(store.ledger.seenUntilEpochMs, contains('update'));
    },
  );

  test('expired alerts are ignored and transient API failures retry', () async {
    final store = _MemoryStore(
      AlertNotificationPreferences(
        enabledTypes: const ['Tornado Warning'],
        onboardingCompleted: true,
        monitoringEnabled: true,
      ),
    );
    final api = _FakeApi([
      _alert(
        'expired',
        now: now,
        expires: now.subtract(const Duration(minutes: 1)),
      ),
    ]);
    final notifier = _FakeNotifier();
    final worker = _worker(
      store: store,
      permissions: _FakePermissions(_grantedPermissions),
      location: _FakeLocation(_point(now)),
      api: api,
      notifier: notifier,
      now: now,
    );

    expect(await worker.run(), AlertNotificationRunResult.success);
    expect(notifier.alerts, isEmpty);

    api.error = const AlertNotificationApiException('offline', transient: true);
    expect(await worker.run(), AlertNotificationRunResult.retry);
  });

  test(
    'failed notification is not marked seen and succeeds on retry',
    () async {
      final store = _MemoryStore(
        AlertNotificationPreferences(
          enabledTypes: const ['Tornado Warning'],
          onboardingCompleted: true,
          monitoringEnabled: true,
        ),
      );
      final notifier = _FakeNotifier(failNext: true);
      final worker = _worker(
        store: store,
        permissions: _FakePermissions(_grantedPermissions),
        location: _FakeLocation(_point(now)),
        api: _FakeApi([_alert('retry-me', now: now)]),
        notifier: notifier,
        now: now,
      );

      expect(await worker.run(), AlertNotificationRunResult.retry);
      expect(store.ledger.seenUntilEpochMs, isNot(contains('retry-me')));
      expect(await worker.run(), AlertNotificationRunResult.success);
      expect(notifier.alerts.map((alert) => alert.id), ['retry-me']);
    },
  );

  test('unexpected persistence failure uses the retry path', () async {
    final permissions = _FakePermissions(_grantedPermissions);
    final location = _FakeLocation(_point(now));
    final api = _FakeApi(const []);
    final notifier = _FakeNotifier();
    final worker = AlertNotificationWorker(
      store: _ThrowingStore(),
      permissions: permissions,
      location: location,
      api: api,
      notifier: notifier,
      now: () => now,
    );

    expect(await worker.run(), AlertNotificationRunResult.retry);
    expect(permissions.statusCalls, 0);
    expect(location.calls, 0);
    expect(api.calls, 0);
  });
}

AlertNotificationWorker _worker({
  required _MemoryStore store,
  required _FakePermissions permissions,
  required _FakeLocation location,
  required _FakeApi api,
  required _FakeNotifier notifier,
  required DateTime now,
}) => AlertNotificationWorker(
  store: store,
  permissions: permissions,
  location: location,
  api: api,
  notifier: notifier,
  now: () => now,
);

const _grantedPermissions = AlertNotificationPermissionSnapshot(
  supported: true,
  notificationsGranted: true,
  foregroundLocationGranted: true,
  backgroundLocationGranted: true,
);

AlertNotificationPoint _point(DateTime now) => AlertNotificationPoint(
  latitude: 30.2672,
  longitude: -97.7431,
  observedAt: now,
  accuracyMeters: 12,
);

WeatherAlert _alert(
  String id, {
  required DateTime now,
  String event = 'Tornado Warning',
  DateTime? expires,
  List<String> references = const [],
}) => WeatherAlert.fromFeature({
  'type': 'Feature',
  'id': id,
  'properties': {
    'event': event,
    'headline': '$event for the test area',
    'effective': now.subtract(const Duration(minutes: 1)).toIso8601String(),
    'expires': (expires ?? now.add(const Duration(hours: 1))).toIso8601String(),
    'references': [
      for (final reference in references) {'identifier': reference},
    ],
  },
  'geometry': null,
});

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

final class _ThrowingStore implements AlertNotificationStore {
  @override
  Future<AlertNotificationLedger> loadLedger() =>
      throw StateError('storage unavailable');

  @override
  Future<AlertNotificationPreferences> loadPreferences() =>
      throw StateError('storage unavailable');

  @override
  Future<void> saveLedger(AlertNotificationLedger ledger) =>
      throw StateError('storage unavailable');

  @override
  Future<void> savePreferences(AlertNotificationPreferences preferences) =>
      throw StateError('storage unavailable');
}

final class _FakePermissions implements AlertNotificationPermissionGateway {
  _FakePermissions(this.value);

  AlertNotificationPermissionSnapshot value;
  int statusCalls = 0;

  @override
  Future<bool> openSettings() async => true;

  @override
  Future<AlertNotificationPermissionSnapshot>
  requestBackgroundLocation() async => value;

  @override
  Future<AlertNotificationPermissionSnapshot> requestNotifications() async =>
      value;

  @override
  Future<AlertNotificationPermissionSnapshot> status() async {
    statusCalls++;
    return value;
  }
}

final class _FakeLocation implements AlertNotificationLocationSource {
  _FakeLocation(this.point);

  AlertNotificationPoint? point;
  int calls = 0;

  @override
  Future<AlertNotificationPoint?> currentLocation() async {
    calls++;
    return point;
  }
}

final class _FakeApi implements AlertNotificationApi {
  _FakeApi(this.alerts);

  List<WeatherAlert> alerts;
  Object? error;
  int calls = 0;
  final List<AlertNotificationPoint?> points = [];
  final List<bool> bypassCacheValues = [];
  int acknowledgements = 0;

  @override
  Future<AlertNotificationFetchResult> fetchActiveAlerts({
    required AlertNotificationScope scope,
    AlertNotificationPoint? point,
    bool bypassCache = false,
  }) async {
    calls++;
    points.add(point);
    bypassCacheValues.add(bypassCache);
    if (error case final failure?) throw failure;
    return AlertNotificationFetchResult(alerts: alerts);
  }

  @override
  Future<void> acknowledge(AlertNotificationFetchResult result) async {
    acknowledgements++;
  }
}

final class _FakeNotifier implements WeatherAlertNotifier {
  _FakeNotifier({this.failNext = false});

  bool failNext;
  final List<WeatherAlert> alerts = [];

  @override
  Future<void> initialize() async {}

  @override
  Future<void> show(WeatherAlert alert) async {
    if (failNext) {
      failNext = false;
      throw StateError('notification failed');
    }
    alerts.add(alert);
  }
}
