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
    'the default spreads a streamed batch across the full 20-second cadence',
    () async {
      var monotonicMs = 10000;
      final api = _FakeApi(latest: _snapshot('baseline', const []));
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
      api.streams.single.add(
        LightningUpdate(
          event: LightningStreamEvent.lightning,
          snapshot: LightningSnapshot(
            mode: LightningSourceMode.event,
            generation: 'paced',
            strikes: [
              _strikeAt('newest', const Duration(milliseconds: 1000)),
              _strikeAt('oldest', Duration.zero),
              _strikeAt('middle', const Duration(milliseconds: 500)),
            ],
          ),
        ),
      );
      await _flushEvents();

      expect(controller.batchPlaybackDuration, const Duration(seconds: 20));
      expect(_featureIds(controller.geoJson), ['oldest']);

      monotonicMs += 999;
      scheduler.firePeriodic();
      expect(_featureIds(controller.geoJson), ['oldest']);
      expect(
        _featureOpacity(controller.geoJson, 'oldest'),
        closeTo(0.001, 0.001),
      );

      monotonicMs += 1;
      scheduler.firePeriodic();
      expect(_features(controller.geoJson), isEmpty);

      monotonicMs += 9000;
      scheduler.firePeriodic();
      expect(_featureIds(controller.geoJson), ['middle']);
      expect(_featureOpacity(controller.geoJson, 'middle'), 1);

      monotonicMs += 1000;
      scheduler.firePeriodic();
      expect(_features(controller.geoJson), isEmpty);

      monotonicMs += 9000;
      scheduler.firePeriodic();
      expect(_featureIds(controller.geoJson), ['newest']);
      expect(_featureOpacity(controller.geoJson, 'newest'), 1);

      monotonicMs += 1000;
      scheduler.firePeriodic();
      expect(_features(controller.geoJson), isEmpty);
      expect(scheduler.hasActivePeriodic, isFalse);
      controller.dispose();
    },
  );

  test('a configured short window compresses a long catch-up batch', () async {
    var monotonicMs = 20000;
    final api = _FakeApi(latest: _snapshot('baseline', const []));
    final scheduler = _FakeScheduler();
    final controller = LightningController(
      api: api,
      store: _MemoryStore(true),
      monotonicMilliseconds: () => monotonicMs,
      scheduleOnce: scheduler.once,
      schedulePeriodic: scheduler.periodic,
      batchPlaybackDuration: const Duration(seconds: 3),
    );

    await controller.initialize();
    await controller.setBounds(bounds);
    api.streams.single.add(
      LightningUpdate(
        event: LightningStreamEvent.lightning,
        snapshot: LightningSnapshot(
          mode: LightningSourceMode.event,
          generation: 'catch-up',
          strikes: [
            _strikeAt('latest', const Duration(seconds: 60)),
            _strikeAt('earliest', Duration.zero),
            _strikeAt('middle', const Duration(seconds: 30)),
          ],
        ),
      ),
    );
    await _flushEvents();
    expect(_featureIds(controller.geoJson), ['earliest']);

    monotonicMs += 1500;
    scheduler.firePeriodic();
    expect(_featureIds(controller.geoJson), ['middle']);

    monotonicMs += 1500;
    scheduler.firePeriodic();
    expect(_featureIds(controller.geoJson), ['latest']);
    controller.dispose();
  });

  test('capacity truncation rebases the newest retained flashes', () async {
    var monotonicMs = 25000;
    final api = _FakeApi(latest: _snapshot('baseline', const []));
    final scheduler = _FakeScheduler();
    final controller = LightningController(
      api: api,
      store: _MemoryStore(true),
      monotonicMilliseconds: () => monotonicMs,
      scheduleOnce: scheduler.once,
      schedulePeriodic: scheduler.periodic,
      maxActiveStrikes: 2,
    );

    await controller.initialize();
    await controller.setBounds(bounds);
    final update = LightningUpdate(
      event: LightningStreamEvent.lightning,
      snapshot: LightningSnapshot(
        mode: LightningSourceMode.event,
        generation: 'over-capacity',
        strikes: [
          _strikeAt('oldest-dropped', Duration.zero),
          _strikeAt('middle-retained', const Duration(seconds: 1)),
          _strikeAt('newest-retained', const Duration(seconds: 2)),
        ],
      ),
    );
    api.streams.single.add(update);
    await _flushEvents();

    expect(_featureIds(controller.geoJson), ['middle-retained']);

    // The cumulative full snapshot must not replay the capacity-dropped ID.
    api.streams.single.add(update);
    await _flushEvents();
    expect(_featureIds(controller.geoJson), ['middle-retained']);

    monotonicMs += 19999;
    scheduler.firePeriodic();
    expect(_features(controller.geoJson), isEmpty);

    monotonicMs += 1;
    scheduler.firePeriodic();
    expect(_featureIds(controller.geoJson), ['newest-retained']);
    controller.dispose();
  });

  test(
    'an overlapping batch merges and accelerates the pending queue',
    () async {
      var monotonicMs = 30000;
      final api = _FakeApi(latest: _snapshot('baseline', const []));
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
      api.streams.single.add(
        LightningUpdate(
          event: LightningStreamEvent.lightning,
          snapshot: LightningSnapshot(
            mode: LightningSourceMode.event,
            generation: 'first-batch',
            strikes: [
              _strikeAt('first-20s', const Duration(seconds: 20)),
              _strikeAt('first-0s', Duration.zero),
              _strikeAt('first-10s', const Duration(seconds: 10)),
            ],
          ),
        ),
      );
      await _flushEvents();
      expect(_featureIds(controller.geoJson), ['first-0s']);

      monotonicMs += 500;
      scheduler.firePeriodic();
      api.streams.single.add(
        LightningUpdate(
          event: LightningStreamEvent.lightning,
          snapshot: LightningSnapshot(
            mode: LightningSourceMode.event,
            generation: 'overlapping-batch',
            strikes: [
              _strikeAt('first-0s', Duration.zero),
              _strikeAt('new-30s', const Duration(seconds: 30)),
              _strikeAt('new-5s', const Duration(seconds: 5)),
              _strikeAt('first-20s', const Duration(seconds: 20)),
              _strikeAt('first-10s', const Duration(seconds: 10)),
            ],
          ),
        ),
      );
      await _flushEvents();

      // The newly received 5s flash is placed before both previously pending
      // flashes, while the already visible 0s flash continues its own fade.
      // The merged future queue is rebased across one new 20-second window.
      expect(_featureIds(controller.geoJson), ['first-0s', 'new-5s']);
      expect(scheduler.periodicTasks, hasLength(1));

      monotonicMs += 599;
      scheduler.firePeriodic();
      expect(_featureIds(controller.geoJson), ['new-5s']);

      monotonicMs += 1;
      scheduler.firePeriodic();
      expect(_featureIds(controller.geoJson), ['new-5s']);

      monotonicMs += 3400;
      scheduler.firePeriodic();
      expect(_featureIds(controller.geoJson), ['first-10s']);

      monotonicMs += 8000;
      scheduler.firePeriodic();
      expect(_featureIds(controller.geoJson), ['first-20s']);

      monotonicMs += 8000;
      scheduler.firePeriodic();
      expect(_featureIds(controller.geoJson), ['new-30s']);
      controller.dispose();
    },
  );

  test('equal observation times form one stable simultaneous bucket', () async {
    final api = _FakeApi(latest: _snapshot('baseline', const []));
    final scheduler = _FakeScheduler();
    final controller = LightningController(
      api: api,
      store: _MemoryStore(true),
      scheduleOnce: scheduler.once,
      schedulePeriodic: scheduler.periodic,
    );

    await controller.initialize();
    await controller.setBounds(bounds);
    api.streams.single.add(
      LightningUpdate(
        event: LightningStreamEvent.lightning,
        snapshot: LightningSnapshot(
          mode: LightningSourceMode.event,
          generation: 'tied',
          strikes: [
            _strikeAt('zulu', Duration.zero),
            _strikeAt('alpha', Duration.zero),
            _strikeAt('middle', Duration.zero),
          ],
        ),
      ),
    );
    await _flushEvents();

    expect(_featureIds(controller.geoJson), ['alpha', 'middle', 'zulu']);
    expect(scheduler.periodicTasks, hasLength(1));
    controller.dispose();
  });

  test('a repeated full generation does not restart a flash', () async {
    var monotonicMs = 40000;
    final api = _FakeApi(latest: _snapshot('baseline', const []));
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
    final update = LightningUpdate(
      event: LightningStreamEvent.lightning,
      id: 'same-generation',
      snapshot: _snapshot('same-generation', ['once', 'once']),
    );
    api.streams.single.add(update);
    await _flushEvents();
    final firstRevision = controller.revision;
    expect(_featureIds(controller.geoJson), ['once']);

    monotonicMs += 250;
    api.streams.single.add(update);
    await _flushEvents();
    expect(controller.revision, firstRevision);
    expect(_opacity(controller.geoJson), 1);
    expect(scheduler.periodicTasks, hasLength(1));

    scheduler.firePeriodic();
    expect(_opacity(controller.geoJson), closeTo(0.75, 0.001));
    controller.dispose();
  });

  test('snapshot and reset events cancel visible and future flashes', () async {
    for (final baselineEvent in [
      LightningStreamEvent.snapshot,
      LightningStreamEvent.reset,
    ]) {
      var monotonicMs = 50000;
      final api = _FakeApi(latest: _snapshot('baseline', const []));
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
      api.streams.single.add(
        LightningUpdate(
          event: LightningStreamEvent.lightning,
          snapshot: LightningSnapshot(
            mode: LightningSourceMode.event,
            generation: 'paced',
            strikes: [
              _strikeAt('visible', Duration.zero),
              _strikeAt('future', const Duration(seconds: 20)),
            ],
          ),
        ),
      );
      await _flushEvents();
      expect(_featureIds(controller.geoJson), ['visible']);
      expect(controller.hasActiveStrikes, isTrue);

      api.streams.single.add(
        LightningUpdate(
          event: baselineEvent,
          snapshot: _snapshot('new-baseline', ['visible', 'future']),
        ),
      );
      await _flushEvents();
      expect(_features(controller.geoJson), isEmpty);
      expect(controller.hasActiveStrikes, isFalse);
      expect(scheduler.hasActivePeriodic, isFalse);

      monotonicMs += 10000;
      scheduler.firePeriodic();
      expect(_features(controller.geoJson), isEmpty);
      controller.dispose();
    }
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
        snapshot: LightningSnapshot(
          mode: LightningSourceMode.event,
          generation: 'generation-1',
          strikes: [
            _strikeAt('visible', Duration.zero),
            _strikeAt('future', const Duration(seconds: 20)),
          ],
        ),
      ),
    );
    await _flushEvents();
    expect(controller.hasActiveStrikes, isTrue);
    expect(_featureIds(controller.geoJson), ['visible']);

    await controller.setForeground(false);
    expect(controller.hasActiveStrikes, isFalse);
    expect(_features(controller.geoJson), isEmpty);
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

LightningStrike _strikeAt(String id, Duration offset) => LightningStrike(
  id: id,
  latitude: 30.27,
  longitude: -97.74,
  observedAt: DateTime.utc(2026, 7, 18, 12).add(offset),
  kind: 'satellite-detected lightning flash',
);

List<dynamic> _features(Map<String, dynamic> geoJson) =>
    geoJson['features'] as List<dynamic>;

List<String> _featureIds(Map<String, dynamic> geoJson) => _features(
  geoJson,
).map((feature) => (feature as Map)['id'].toString()).toList();

num _opacity(Map<String, dynamic> geoJson) =>
    ((_features(geoJson).single as Map)['properties'] as Map)['opacity'] as num;

num _featureOpacity(Map<String, dynamic> geoJson, String id) {
  final feature = _features(
    geoJson,
  ).cast<Map>().singleWhere((feature) => feature['id'] == id);
  return (feature['properties'] as Map)['opacity'] as num;
}

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
