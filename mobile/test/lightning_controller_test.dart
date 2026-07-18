import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/controllers/lightning_controller.dart';
import 'package:radar_mobile/models/lightning_models.dart';
import 'package:radar_mobile/services/lightning_api.dart';
import 'package:radar_mobile/services/lightning_visibility_store.dart';

void main() {
  final bounds = LightningBounds(west: -110, south: 20, east: -90, north: 40);

  test('default-off preference performs no network or timer work', () async {
    final api = _FakeApi();
    final scheduler = _FakeScheduler();
    final controller = LightningController(
      api: api,
      store: _MemoryStore(false),
      scheduleOnce: scheduler.once,
      schedulePeriodic: scheduler.periodic,
    );

    await controller.initialize();
    await controller.setBounds(bounds);

    expect(controller.enabled, isFalse);
    expect(controller.status, LightningStatus.disabled);
    expect(controller.statusSummary, 'Lightning is off');
    expect(api.latestCalls, 0);
    expect(api.watchCalls, 0);
    expect(scheduler.hasActiveTasks, isFalse);
    controller.dispose();
  });

  test('baseline does not flash and only newly streamed ids fade', () async {
    var monotonicMs = 10000;
    final api = _FakeApi(latest: _snapshot('baseline', ['old']));
    final scheduler = _FakeScheduler();
    final controller = LightningController(
      api: api,
      store: _MemoryStore(true),
      monotonicMilliseconds: () => monotonicMs,
      scheduleOnce: scheduler.once,
      schedulePeriodic: scheduler.periodic,
    );

    await controller.initialize();
    await controller.setBounds(bounds);
    expect(_features(controller.geoJson), isEmpty);
    final baselineRevision = controller.revision;
    var uiNotifications = 0;
    controller.uiState.addListener(() => uiNotifications++);

    api.streams.single.add(
      LightningUpdate(
        event: LightningStreamEvent.snapshot,
        snapshot: _snapshot('stream-baseline', [
          'old',
          'arrived-before-stream',
        ]),
      ),
    );
    await _flushEvents();
    expect(_features(controller.geoJson), isEmpty);

    api.streams.single.add(
      LightningUpdate(
        event: LightningStreamEvent.lightning,
        id: 'generation-2',
        snapshot: _snapshot('generation-2', [
          'old',
          'arrived-before-stream',
          'new',
          'new',
        ]),
      ),
    );
    await _flushEvents();

    expect(_featureIds(controller.geoJson), ['new']);
    expect(_opacity(controller.geoJson), 1);
    expect(controller.revision, baselineRevision + 1);
    expect(uiNotifications, 0);
    expect(scheduler.periodicTasks, hasLength(1));

    monotonicMs += 500;
    scheduler.firePeriodic();
    expect(_opacity(controller.geoJson), closeTo(0.5, 0.001));

    monotonicMs += 500;
    scheduler.firePeriodic();
    expect(_features(controller.geoJson), isEmpty);
    expect(controller.hasActiveStrikes, isFalse);
    expect(scheduler.hasActivePeriodic, isFalse);
    expect(uiNotifications, 0);
    controller.dispose();
  });

  test(
    'reconnect snapshots seed missed ids instead of replaying flashes',
    () async {
      final api = _FakeApi(latest: _snapshot('baseline', ['old']));
      final scheduler = _FakeScheduler();
      final controller = LightningController(
        api: api,
        store: _MemoryStore(true),
        scheduleOnce: scheduler.once,
        schedulePeriodic: scheduler.periodic,
      );

      await controller.initialize();
      await controller.setBounds(bounds);
      api.streams.single.addError(StateError('connection lost'));
      await _flushEvents();
      expect(controller.status, LightningStatus.error);
      expect(scheduler.onceTasks, hasLength(1));

      api.latest = _snapshot('reconnect-baseline', ['old', 'missed']);
      scheduler.fireNextOnce();
      await _waitFor(() => api.watchCalls == 2);
      expect(_features(controller.geoJson), isEmpty);

      api.streams.last.add(
        LightningUpdate(
          event: LightningStreamEvent.lightning,
          snapshot: _snapshot('after-reconnect', ['old', 'missed', 'new']),
        ),
      );
      await _flushEvents();
      expect(_featureIds(controller.geoJson), ['new']);
      controller.dispose();
    },
  );

  test('foreground and visibility lifecycle cancel all active work', () async {
    final store = _MemoryStore(true);
    final api = _FakeApi(latest: _snapshot('baseline', const []));
    final scheduler = _FakeScheduler();
    final controller = LightningController(
      api: api,
      store: store,
      scheduleOnce: scheduler.once,
      schedulePeriodic: scheduler.periodic,
    );

    await controller.initialize();
    await controller.setBounds(bounds);
    api.streams.single.add(
      LightningUpdate(
        event: LightningStreamEvent.lightning,
        snapshot: _snapshot('generation-1', ['new']),
      ),
    );
    await _flushEvents();
    expect(controller.hasActiveStrikes, isTrue);

    await controller.setForeground(false);
    expect(controller.hasActiveStrikes, isFalse);
    expect(api.streams.first.hasListener, isFalse);
    expect(scheduler.hasActiveTasks, isFalse);

    await controller.setForeground(true);
    expect(api.latestCalls, 2);
    expect(api.watchCalls, 2);

    await controller.setEnabled(false);
    expect(store.enabled, isFalse);
    expect(controller.status, LightningStatus.disabled);
    expect(api.streams.last.hasListener, isFalse);
    expect(scheduler.hasActiveTasks, isFalse);
    controller.dispose();
  });

  test(
    '503 marks the optional source unavailable without starting a stream',
    () async {
      final api = _FakeApi(
        latestError: const LightningApiException(
          'not configured',
          statusCode: 503,
        ),
      );
      final scheduler = _FakeScheduler();
      final controller = LightningController(
        api: api,
        store: _MemoryStore(true),
        scheduleOnce: scheduler.once,
        schedulePeriodic: scheduler.periodic,
      );

      await controller.initialize();
      await controller.setBounds(bounds);

      expect(controller.available, isFalse);
      expect(controller.status, LightningStatus.unavailable);
      expect(controller.statusSummary, 'Lightning is unavailable');
      expect(api.watchCalls, 0);
      expect(scheduler.onceTasks, hasLength(1));
      controller.dispose();
    },
  );

  test('an explicit unavailable snapshot is not labeled live', () async {
    final api = _FakeApi(
      latest: LightningSnapshot(
        mode: LightningSourceMode.event,
        generation: 'disabled',
        strikes: const [],
        available: false,
      ),
    );
    final controller = LightningController(api: api, store: _MemoryStore(true));

    await controller.initialize();
    await controller.setBounds(bounds);

    expect(controller.available, isFalse);
    expect(controller.status, LightningStatus.unavailable);
    expect(api.watchCalls, 1);
    controller.dispose();
  });

  test('persisted-on lightning waits for viewport bounds', () async {
    final api = _FakeApi(latest: _snapshot('baseline', const []));
    final controller = LightningController(api: api, store: _MemoryStore(true));

    await controller.initialize();

    expect(controller.enabled, isTrue);
    expect(controller.status, LightningStatus.connecting);
    expect(api.latestCalls, 0);
    expect(api.watchCalls, 0);

    await controller.setBounds(bounds);

    expect(api.latestCalls, 1);
    expect(api.latestBounds.single, bounds);
    expect(api.watchCalls, 1);
    expect(api.watchBounds.single, bounds);
    controller.dispose();
  });

  test('a delayed preference load cannot overwrite a user toggle', () async {
    final store = _DelayedStore();
    final api = _FakeApi(latest: _snapshot('baseline', const []));
    final controller = LightningController(api: api, store: store);
    await controller.setBounds(bounds);

    final initialization = controller.initialize();
    await _flushEvents();
    await controller.setEnabled(true);
    store.completeLoad(false);
    await initialization;

    expect(controller.enabled, isTrue);
    expect(store.enabled, isTrue);
    expect(api.latestCalls, 1);
    expect(api.watchCalls, 1);
    controller.dispose();
  });

  test(
    'disposing during delayed stream cancellation does not notify',
    () async {
      final cancel = Completer<void>();
      final api = _FakeApi(
        latest: _snapshot('baseline', const []),
        cancelGate: () => cancel.future,
      );
      final controller = LightningController(
        api: api,
        store: _MemoryStore(true),
      );
      await controller.initialize();
      await controller.setBounds(bounds);

      final disabling = controller.setEnabled(false);
      await _flushEvents();
      controller.dispose();
      cancel.complete();

      await expectLater(disabling, completes);
    },
  );
}

LightningSnapshot _snapshot(
  String generation,
  List<String> ids, {
  LightningSourceMode mode = LightningSourceMode.event,
}) => LightningSnapshot(
  mode: mode,
  generation: generation,
  strikes: ids.map(_strike).toList(growable: false),
);

LightningStrike _strike(String id) => LightningStrike(
  id: id,
  latitude: 30.27,
  longitude: -97.74,
  observedAt: DateTime.utc(2026, 7, 18, 12),
  kind: 'satellite-detected lightning flash',
);

List<dynamic> _features(Map<String, dynamic> geoJson) =>
    geoJson['features'] as List<dynamic>;

List<String> _featureIds(Map<String, dynamic> geoJson) => _features(
  geoJson,
).map((feature) => (feature as Map)['id'].toString()).toList();

num _opacity(Map<String, dynamic> geoJson) =>
    ((_features(geoJson).single as Map)['properties'] as Map)['opacity'] as num;

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for state.');
    await _flushEvents();
  }
}

final class _MemoryStore implements LightningVisibilityStore {
  _MemoryStore(this.enabled);

  bool enabled;

  @override
  Future<bool> load() async => enabled;

  @override
  Future<void> save(bool enabled) async => this.enabled = enabled;
}

final class _DelayedStore implements LightningVisibilityStore {
  final Completer<bool> _load = Completer<bool>();
  bool enabled = false;

  void completeLoad(bool value) => _load.complete(value);

  @override
  Future<bool> load() => _load.future;

  @override
  Future<void> save(bool enabled) async => this.enabled = enabled;
}

final class _FakeApi implements LightningDataSource {
  _FakeApi({LightningSnapshot? latest, this.latestError, this.cancelGate})
    : latest = latest ?? _snapshot('empty', const []);

  LightningSnapshot latest;
  Object? latestError;
  Future<void> Function()? cancelGate;
  int latestCalls = 0;
  int watchCalls = 0;
  bool closed = false;
  final List<LightningBounds?> latestBounds = [];
  final List<LightningBounds?> watchBounds = [];
  final List<String?> lastEventIds = [];
  final List<StreamController<LightningUpdate>> streams = [];

  @override
  Future<LightningSnapshot> fetchLatest({LightningBounds? bounds}) async {
    latestCalls++;
    latestBounds.add(bounds);
    if (latestError case final error?) throw error;
    return latest;
  }

  @override
  Stream<LightningUpdate> watchUpdates({
    LightningBounds? bounds,
    String? lastEventId,
  }) {
    watchCalls++;
    watchBounds.add(bounds);
    lastEventIds.add(lastEventId);
    final controller = StreamController<LightningUpdate>.broadcast(
      onCancel: cancelGate,
    );
    streams.add(controller);
    return controller.stream;
  }

  @override
  void close() {
    closed = true;
    for (final stream in streams) {
      unawaited(stream.close());
    }
  }
}

final class _FakeScheduler {
  final List<_ScheduledTask> onceTasks = [];
  final List<_ScheduledTask> periodicTasks = [];

  bool get hasActiveTasks =>
      onceTasks.any((task) => !task.cancelled) || hasActivePeriodic;
  bool get hasActivePeriodic => periodicTasks.any((task) => !task.cancelled);

  VoidCallback once(Duration delay, VoidCallback callback) {
    final task = _ScheduledTask(delay, callback);
    onceTasks.add(task);
    return () => task.cancelled = true;
  }

  VoidCallback periodic(Duration interval, VoidCallback callback) {
    final task = _ScheduledTask(interval, callback);
    periodicTasks.add(task);
    return () => task.cancelled = true;
  }

  void fireNextOnce() {
    final task = onceTasks.firstWhere((task) => !task.cancelled);
    task.cancelled = true;
    task.callback();
  }

  void firePeriodic() {
    for (final task in List<_ScheduledTask>.from(periodicTasks)) {
      if (!task.cancelled) task.callback();
    }
  }
}

final class _ScheduledTask {
  _ScheduledTask(this.duration, this.callback);

  final Duration duration;
  final VoidCallback callback;
  bool cancelled = false;
}
