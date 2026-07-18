import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../config/app_config.dart';
import '../models/lightning_models.dart';
import '../services/lightning_api.dart';
import '../services/lightning_visibility_store.dart';

enum LightningStatus { disabled, connecting, live, stale, unavailable, error }

typedef LightningUiState = ({
  bool initialized,
  bool enabled,
  LightningStatus status,
});

typedef LightningScheduleOnce =
    VoidCallback Function(Duration delay, VoidCallback callback);
typedef LightningSchedulePeriodic =
    VoidCallback Function(Duration interval, VoidCallback callback);

/// Owns the optional, foreground-only lightning stream and the small transient
/// GeoJSON collection consumed by MapLibre.
///
/// Snapshot/reset events establish a reconnect baseline without animation.
/// Only IDs first seen in a subsequent `lightning` event are shown, with their
/// one-second fade measured from a local monotonic receipt clock. Provider
/// observation timestamps are intentionally not used for animation because
/// satellite products have inherent delivery latency.
final class LightningController extends ChangeNotifier {
  LightningController({
    LightningDataSource? api,
    LightningVisibilityStore? store,
    int Function()? monotonicMilliseconds,
    LightningScheduleOnce? scheduleOnce,
    LightningSchedulePeriodic? schedulePeriodic,
    this.fadeDuration = const Duration(seconds: 1),
    this.fadeInterval = const Duration(milliseconds: 100),
    this.reconnectBaseDelay = const Duration(seconds: 1),
    this.reconnectMaxDelay = const Duration(seconds: 30),
    this.maxSeenIds = 50000,
    this.maxActiveStrikes = 5000,
  }) : _api = api ?? LightningApi(baseUrl: AppConfig.apiBaseUrl),
       _store = store ?? SharedPreferencesLightningVisibilityStore(),
       _monotonicMilliseconds =
           monotonicMilliseconds ?? _defaultMonotonicMilliseconds,
       _scheduleOnce = scheduleOnce ?? _defaultScheduleOnce,
       _schedulePeriodic = schedulePeriodic ?? _defaultSchedulePeriodic;

  final LightningDataSource _api;
  final LightningVisibilityStore _store;
  final int Function() _monotonicMilliseconds;
  final LightningScheduleOnce _scheduleOnce;
  final LightningSchedulePeriodic _schedulePeriodic;
  final Duration fadeDuration;
  final Duration fadeInterval;
  final Duration reconnectBaseDelay;
  final Duration reconnectMaxDelay;
  final int maxSeenIds;
  final int maxActiveStrikes;

  final LinkedHashMap<String, Object?> _seenIds = LinkedHashMap();
  final LinkedHashMap<String, _ActiveStrike> _active = LinkedHashMap();
  final ValueNotifier<LightningUiState> _uiState = ValueNotifier((
    initialized: false,
    enabled: false,
    status: LightningStatus.disabled,
  ));
  StreamSubscription<LightningUpdate>? _updatesSubscription;
  VoidCallback? _cancelReconnect;
  VoidCallback? _cancelFade;
  LightningBounds? _bounds;
  Map<String, dynamic> _geoJson = lightningFeatureCollection(const []);
  LightningSnapshot? _snapshot;
  LightningStatus _status = LightningStatus.disabled;
  String? _lastEventId;
  String? _error;
  bool _initialized = false;
  bool _enabled = false;
  bool _foreground = true;
  bool _available = true;
  bool _disposed = false;
  int _preferenceGeneration = 0;
  int _connectionGeneration = 0;
  int _reconnectAttempt = 0;
  int _revision = 0;

  bool get initialized => _initialized;
  bool get enabled => _enabled;
  bool get foreground => _foreground;
  bool get available => _available;
  ValueListenable<LightningUiState> get uiState => _uiState;
  LightningStatus get status => _status;
  String? get error => _error;
  LightningSnapshot? get snapshot => _snapshot;
  LightningBounds? get bounds => _bounds;
  Map<String, dynamic> get geoJson => _geoJson;
  int get revision => _revision;
  bool get hasActiveStrikes => _active.isNotEmpty;
  String get statusSummary => switch (_status) {
    LightningStatus.disabled => 'Lightning is off',
    LightningStatus.connecting => 'Connecting to live lightning…',
    LightningStatus.live => 'Live lightning connected',
    LightningStatus.stale => 'Lightning data is delayed',
    LightningStatus.unavailable => 'Lightning is unavailable',
    LightningStatus.error => 'Lightning connection interrupted',
  };

  Future<void> initialize({bool foreground = true}) async {
    if (_disposed || _initialized) return;
    _initialized = true;
    _foreground = foreground;
    final preferenceGeneration = _preferenceGeneration;
    var storedEnabled = false;
    try {
      storedEnabled = await _store.load();
    } catch (_) {
      // A corrupt or unavailable preference must fail closed: lightning is an
      // optional enhancement and must not begin network work unexpectedly.
    }
    if (_disposed || preferenceGeneration != _preferenceGeneration) return;
    _enabled = storedEnabled;
    _status = _enabled ? LightningStatus.connecting : LightningStatus.disabled;
    notifyListeners();
    if (_enabled && _foreground && _bounds != null) await _start();
  }

  Future<void> setEnabled(bool enabled) async {
    if (_disposed || (_initialized && _enabled == enabled)) return;
    _preferenceGeneration++;
    _initialized = true;
    _enabled = enabled;
    try {
      await _store.save(enabled);
    } catch (_) {
      // Keep the user's in-memory choice for this session if persistence fails.
    }
    if (_disposed || _enabled != enabled) return;
    if (!enabled) {
      await _stop(clearSeen: true);
      if (_disposed || _enabled) return;
      _status = LightningStatus.disabled;
      _error = null;
      notifyListeners();
    } else if (_foreground && _bounds != null) {
      await _start();
    } else {
      _status = LightningStatus.connecting;
      notifyListeners();
    }
  }

  Future<void> setForeground(bool foreground) async {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    if (!foreground) {
      await _stop(clearSeen: false);
      if (_disposed || _foreground) return;
      if (_enabled) _status = LightningStatus.connecting;
      notifyListeners();
    } else if (_enabled && _bounds != null) {
      await _start();
    }
  }

  Future<void> setBounds(LightningBounds? bounds) async {
    if (_disposed || _bounds == bounds) return;
    _bounds = bounds;
    if (_enabled && _foreground) {
      await _stop(clearSeen: false);
      if (_disposed || _bounds != bounds || !_enabled || !_foreground) return;
      if (_bounds != null) await _start();
    }
  }

  Future<void> _start() async {
    final bounds = _bounds;
    if (_disposed || !_enabled || !_foreground || bounds == null) return;
    final generation = ++_connectionGeneration;
    _cancelReconnect?.call();
    _cancelReconnect = null;
    final previousSubscription = _updatesSubscription;
    _updatesSubscription = null;
    await previousSubscription?.cancel();
    if (!_isCurrent(generation)) return;
    _status = LightningStatus.connecting;
    _error = null;
    notifyListeners();

    try {
      final latest = await _api.fetchLatest(bounds: bounds);
      if (!_isCurrent(generation)) return;
      _applyBaseline(latest);
      _available = latest.available;
      _status = !latest.available
          ? LightningStatus.unavailable
          : latest.stale
          ? LightningStatus.stale
          : LightningStatus.live;
      _error = null;
      _reconnectAttempt = 0;
      notifyListeners();
    } catch (error) {
      if (!_isCurrent(generation)) return;
      _recordError(error);
      _scheduleReconnect(generation);
      return;
    }

    if (!_isCurrent(generation)) return;
    final stream = _api.watchUpdates(bounds: bounds, lastEventId: _lastEventId);
    _updatesSubscription = stream.listen(
      (update) => _handleUpdate(generation, update),
      onError: (Object error, StackTrace stackTrace) {
        if (!_isCurrent(generation)) return;
        _recordError(error);
        _scheduleReconnect(generation);
      },
      onDone: () {
        if (!_isCurrent(generation)) return;
        _scheduleReconnect(generation);
      },
      cancelOnError: false,
    );
  }

  void _handleUpdate(int generation, LightningUpdate update) {
    if (!_isCurrent(generation)) return;
    if (update.id case final id? when id.isNotEmpty) _lastEventId = id;
    final fresh = update.snapshot;
    switch (update.event) {
      case LightningStreamEvent.snapshot:
      case LightningStreamEvent.reset:
        if (fresh != null) _applyBaseline(fresh);
      case LightningStreamEvent.lightning:
        if (fresh != null) _applyLightning(fresh);
      case LightningStreamEvent.status:
        if (fresh != null) _applyStatus(fresh);
      case LightningStreamEvent.unknown:
        return;
    }
    if (fresh == null) return;
    _available = fresh.available;
    _error = null;
    _reconnectAttempt = 0;
    _status = !fresh.available
        ? LightningStatus.unavailable
        : fresh.stale
        ? LightningStatus.stale
        : LightningStatus.live;
    notifyListeners();
  }

  void _applyBaseline(LightningSnapshot fresh) {
    _snapshot = fresh;
    _seedSeen(fresh.strikes);
  }

  void _applyLightning(LightningSnapshot fresh) {
    _snapshot = fresh;
    final firstSeen = _monotonicMilliseconds();
    var changed = false;
    for (final strike in fresh.strikes) {
      if (_markSeen(strike.id)) {
        _active[strike.id] = _ActiveStrike(
          strike: strike,
          firstSeenMilliseconds: firstSeen,
        );
        changed = true;
      }
    }
    while (_active.length > maxActiveStrikes && _active.isNotEmpty) {
      _active.remove(_active.keys.first);
      changed = true;
    }
    if (changed) {
      _rebuildGeoJson(firstSeen, notify: false);
      _ensureFadeTimer();
    }
  }

  void _applyStatus(LightningSnapshot fresh) {
    _snapshot = fresh;
  }

  void _seedSeen(Iterable<LightningStrike> strikes) {
    for (final strike in strikes) {
      _seenIds.remove(strike.id);
      _seenIds[strike.id] = null;
    }
    _trimSeen();
  }

  bool _markSeen(String id) {
    if (_seenIds.containsKey(id)) {
      _seenIds.remove(id);
      _seenIds[id] = null;
      return false;
    }
    _seenIds[id] = null;
    _trimSeen();
    return true;
  }

  void _trimSeen() {
    while (_seenIds.length > maxSeenIds && _seenIds.isNotEmpty) {
      _seenIds.remove(_seenIds.keys.first);
    }
  }

  void _ensureFadeTimer() {
    if (_cancelFade != null || _active.isEmpty) return;
    _cancelFade = _schedulePeriodic(fadeInterval, _onFadeTick);
  }

  void _onFadeTick() {
    if (_disposed || _active.isEmpty) {
      _cancelFade?.call();
      _cancelFade = null;
      return;
    }
    _rebuildGeoJson(_monotonicMilliseconds());
    if (_active.isEmpty) {
      _cancelFade?.call();
      _cancelFade = null;
    }
  }

  void _rebuildGeoJson(int nowMilliseconds, {bool notify = true}) {
    final durationMs = fadeDuration.inMilliseconds.clamp(1, 1 << 31);
    final features = <Map<String, dynamic>>[];
    final expired = <String>[];
    for (final entry in _active.entries) {
      final age = nowMilliseconds - entry.value.firstSeenMilliseconds;
      if (age >= durationMs) {
        expired.add(entry.key);
        continue;
      }
      final normalizedAge = (age / durationMs).clamp(0.0, 1.0);
      final opacity = 1 - normalizedAge;
      features.add(entry.value.strike.toGeoJsonFeature(opacity: opacity));
    }
    for (final id in expired) {
      _active.remove(id);
    }
    _geoJson = lightningFeatureCollection(features);
    _revision++;
    if (notify) notifyListeners();
  }

  void _recordError(Object error) {
    _error = error.toString();
    if (error is LightningApiException && error.indicatesUnavailable) {
      _available = false;
      _status = LightningStatus.unavailable;
    } else {
      _status = LightningStatus.error;
    }
    notifyListeners();
  }

  void _scheduleReconnect(int generation) {
    if (!_isCurrent(generation) || _cancelReconnect != null) return;
    unawaited(_updatesSubscription?.cancel());
    _updatesSubscription = null;
    final exponent = _reconnectAttempt.clamp(0, 20);
    final multiplier = 1 << exponent;
    final calculated = reconnectBaseDelay.inMilliseconds * multiplier;
    final delay = Duration(
      milliseconds: calculated.clamp(
        reconnectBaseDelay.inMilliseconds,
        reconnectMaxDelay.inMilliseconds,
      ),
    );
    _reconnectAttempt++;
    _cancelReconnect = _scheduleOnce(delay, () {
      _cancelReconnect = null;
      if (_isCurrent(generation)) unawaited(_start());
    });
  }

  bool _isCurrent(int generation) =>
      !_disposed &&
      _enabled &&
      _foreground &&
      generation == _connectionGeneration;

  Future<void> _stop({required bool clearSeen}) async {
    _connectionGeneration++;
    _cancelReconnect?.call();
    _cancelReconnect = null;
    _cancelFade?.call();
    _cancelFade = null;
    final previousSubscription = _updatesSubscription;
    _updatesSubscription = null;
    _active.clear();
    if (clearSeen) {
      _seenIds.clear();
      _lastEventId = null;
    }
    _snapshot = null;
    _geoJson = lightningFeatureCollection(const []);
    _revision++;
    await previousSubscription?.cancel();
  }

  @override
  void notifyListeners() {
    final nextUiState = (
      initialized: _initialized,
      enabled: _enabled,
      status: _status,
    );
    if (_uiState.value != nextUiState) _uiState.value = nextUiState;
    super.notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _connectionGeneration++;
    _cancelReconnect?.call();
    _cancelFade?.call();
    unawaited(_updatesSubscription?.cancel());
    _api.close();
    _uiState.dispose();
    super.dispose();
  }
}

final class _ActiveStrike {
  const _ActiveStrike({
    required this.strike,
    required this.firstSeenMilliseconds,
  });

  final LightningStrike strike;
  final int firstSeenMilliseconds;
}

final Stopwatch _lightningStopwatch = Stopwatch()..start();

int _defaultMonotonicMilliseconds() => _lightningStopwatch.elapsedMilliseconds;

VoidCallback _defaultScheduleOnce(Duration delay, VoidCallback callback) {
  final timer = Timer(delay, callback);
  return timer.cancel;
}

VoidCallback _defaultSchedulePeriodic(
  Duration interval,
  VoidCallback callback,
) {
  final timer = Timer.periodic(interval, (_) => callback());
  return timer.cancel;
}
