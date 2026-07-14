import 'dart:async';

import '../config/app_config.dart';
import '../models/radar_models.dart';
import '../services/alert_visibility_store.dart';
import '../services/radar_api.dart';

typedef VoidCallback = void Function();

final class RadarController {
  RadarController({RadarApi? api, AlertVisibilityStore? alertVisibilityStore})
    : _api = api ?? RadarApi(baseUrl: AppConfig.apiBaseUrl),
      _alertVisibilityStore =
          alertVisibilityStore ?? SharedPreferencesAlertVisibilityStore() {
    for (final type in _defaultKnownAlertTypes) {
      _knownAlertTypeLabels[_normalizeAlertType(type)] = type;
    }
  }

  final RadarApi _api;
  final AlertVisibilityStore _alertVisibilityStore;
  final List<VoidCallback> _listeners = [];
  Timer? _radarTimer;
  Timer? _alertsTimer;
  Timer? _stationsTimer;
  Timer? _updatesReconnectTimer;
  StreamSubscription<RadarUpdate>? _updatesSubscription;
  bool _disposed = false;
  bool _loadingRadar = false;
  bool _loadingAlerts = false;
  bool _loadingStations = false;
  int _radarRequest = 0;
  int _updatesGeneration = 0;
  Map<String, dynamic> _stationGeoJson = _emptyFeatureCollection();
  Map<String, dynamic> _alertGeoJson = _emptyFeatureCollection();
  List<WeatherAlert> _allAlerts = const [];
  List<WeatherAlert> _visibleAlerts = const [];
  final Set<String> _hiddenAlertTypes = {};
  final Map<String, String> _knownAlertTypeLabels = {};
  bool _alertVisibilityLoaded = false;

  RadarMode mode = RadarMode.aggregate;
  RadarStation? selectedStation;
  String? selectedElevation;
  RadarSnapshot? snapshot;
  List<RadarStation> stations = const [];
  String? radarError;
  String? alertsError;
  bool alertsStale = false;
  String? stationsError;
  DateTime? alertsUpdatedAt;
  int stationRevision = 0;
  int alertRevision = 0;

  bool get isLoadingRadar => _loadingRadar;
  bool get isLoadingAlerts => _loadingAlerts;
  bool get isLoadingStations => _loadingStations;
  String get apiBaseUrl => _api.baseUrl;
  List<WeatherAlert> get alerts => _visibleAlerts;
  List<WeatherAlert> get allAlerts => _allAlerts;

  List<String> get knownAlertTypes {
    final types = _knownAlertTypeLabels.values.toList();
    types.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return List.unmodifiable(types);
  }

  Map<String, int> get alertTypeCounts {
    final counts = <String, int>{};
    for (final alert in _allAlerts) {
      final label =
          _knownAlertTypeLabels[_normalizeAlertType(alert.event)] ??
          alert.event;
      counts[label] = (counts[label] ?? 0) + 1;
    }
    return Map.unmodifiable(counts);
  }

  List<String> get elevations =>
      selectedStation?.elevationsFor(mode) ?? const [];
  bool get hasSelectableElevations => elevations.length > 1;

  String? get activeTileTemplate {
    final current = snapshot;
    if (current == null) return null;
    return _api.tileTemplate(
      mode: mode,
      snapshot: current,
      station: selectedStation,
      elevation: selectedElevation,
    );
  }

  String get radarLayerKey {
    final current = snapshot;
    if (current == null) return '';
    return [
      mode.apiValue,
      selectedStation?.id ?? '_',
      selectedElevation ?? '_',
      current.version,
    ].join(':');
  }

  Map<String, dynamic> get stationGeoJson => _stationGeoJson;

  Map<String, dynamic> get alertGeoJson => _alertGeoJson;

  void addListener(VoidCallback listener) => _listeners.add(listener);
  void removeListener(VoidCallback listener) => _listeners.remove(listener);

  Future<void> initialize() async {
    await loadAlertVisibility();
    _radarTimer = Timer.periodic(
      AppConfig.radarRefreshInterval,
      (_) => refreshRadar(),
    );
    _alertsTimer = Timer.periodic(
      AppConfig.alertsRefreshInterval,
      (_) => refreshAlerts(),
    );
    _stationsTimer = Timer.periodic(
      AppConfig.stationsRefreshInterval,
      (_) => refreshStations(),
    );
    unawaited(_restartUpdates());
    await Future.wait([refreshStations(), refreshAlerts(), refreshRadar()]);
  }

  Future<void> refreshAll() async {
    await Future.wait([refreshStations(), refreshAlerts(), refreshRadar()]);
  }

  Future<void> resume() async {
    unawaited(_restartUpdates());
    await refreshAll();
  }

  Future<void> refreshStations() async {
    if (_loadingStations || _disposed) return;
    _loadingStations = true;
    _notify();
    try {
      final fresh = await _api.fetchStations();
      if (_disposed) return;
      stations = fresh;
      _stationGeoJson = {
        'type': 'FeatureCollection',
        'features': fresh
            .map((station) => station.toGeoJsonFeature())
            .toList(growable: false),
      };
      stationRevision++;
      stationsError = null;
      final selectedId = selectedStation?.id;
      if (selectedId != null) {
        selectedStation = _stationById(selectedId);
        _normalizeSelection();
      }
    } catch (error) {
      if (!_disposed) stationsError = error.toString();
    } finally {
      _loadingStations = false;
      _notify();
    }
  }

  Future<void> refreshAlerts() async {
    if (_loadingAlerts || _disposed) return;
    _loadingAlerts = true;
    _notify();
    try {
      final fresh = await _api.fetchAlerts();
      if (_disposed) return;
      _allAlerts = List.unmodifiable(fresh.alerts);
      if (fresh.changed) {
        final learnedTypes = _rememberAlertTypes(fresh.alerts);
        _rebuildVisibleAlerts();
        if (learnedTypes && _alertVisibilityLoaded) {
          unawaited(_saveAlertVisibility());
        }
      }
      alertsStale = fresh.stale;
      alertsUpdatedAt = DateTime.now();
      alertsError = null;
    } catch (error) {
      if (!_disposed) {
        // Keep the last successfully received polygons visible, but never
        // present them as current when their refresh failed.
        alertsStale = true;
        alertsError = error.toString();
      }
    } finally {
      _loadingAlerts = false;
      _notify();
    }
  }

  Future<void> refreshRadar() async {
    if (_loadingRadar || _disposed) return;
    if (mode.requiresStation && selectedStation == null) {
      radarError = 'Select a radar station on the map.';
      snapshot = null;
      _notify();
      return;
    }
    final request = ++_radarRequest;
    final requestMode = mode;
    final requestStation = selectedStation;
    final requestElevation = selectedElevation;
    _loadingRadar = true;
    _notify();
    try {
      final fresh = await _api.fetchLatest(
        mode: requestMode,
        station: requestStation,
        elevation: requestElevation,
      );
      if (_disposed || request != _radarRequest) return;
      snapshot = fresh;
      radarError = null;
    } catch (error) {
      if (!_disposed && request == _radarRequest) radarError = error.toString();
    } finally {
      if (request == _radarRequest) _loadingRadar = false;
      _notify();
    }
  }

  void selectMode(RadarMode next) {
    if (next == RadarMode.stationVelocity &&
        selectedStation != null &&
        !selectedStation!.supportsVelocity) {
      return;
    }
    if (mode == next) {
      return;
    }
    mode = next;
    _normalizeSelection();
    snapshot = null;
    radarError = null;
    _invalidateAndRefresh();
  }

  void selectStation(RadarStation station) {
    selectedStation = station;
    if (mode == RadarMode.aggregate) mode = RadarMode.stationReflectivity;
    if (mode == RadarMode.stationVelocity && !station.supportsVelocity) {
      mode = RadarMode.stationReflectivity;
    }
    _normalizeSelection();
    snapshot = null;
    radarError = null;
    _invalidateAndRefresh();
  }

  void selectStationById(String id) {
    final station = _stationById(id);
    if (station != null) selectStation(station);
  }

  void selectElevation(String elevation) {
    if (!elevations.contains(elevation) || elevation == selectedElevation) {
      return;
    }
    selectedElevation = elevation;
    snapshot = null;
    _invalidateAndRefresh();
  }

  WeatherAlert? alertById(String id) {
    for (final alert in _visibleAlerts) {
      if (alert.id == id) return alert;
    }
    return null;
  }

  bool isAlertTypeVisible(String alertType) =>
      !_hiddenAlertTypes.contains(_normalizeAlertType(alertType));

  void setAlertTypeVisible(String alertType, bool visible) {
    final normalized = _normalizeAlertType(alertType);
    if (normalized.isEmpty) return;
    _knownAlertTypeLabels.putIfAbsent(normalized, () => alertType);
    final changed = visible
        ? _hiddenAlertTypes.remove(normalized)
        : _hiddenAlertTypes.add(normalized);
    if (!changed) return;
    _rebuildVisibleAlerts();
    _notify();
    unawaited(_saveAlertVisibility());
  }

  void showAllAlertTypes() {
    if (_hiddenAlertTypes.isEmpty) return;
    _hiddenAlertTypes.clear();
    _rebuildVisibleAlerts();
    _notify();
    unawaited(_saveAlertVisibility());
  }

  Future<void> loadAlertVisibility() async {
    if (_alertVisibilityLoaded) return;
    try {
      final saved = await _alertVisibilityStore.load();
      if (_disposed) return;
      _hiddenAlertTypes
        ..clear()
        ..addAll(saved.hiddenTypes.map(_normalizeAlertType));
      for (final type in saved.knownTypes) {
        final normalized = _normalizeAlertType(type);
        if (normalized.isNotEmpty) {
          _knownAlertTypeLabels.putIfAbsent(normalized, () => type);
        }
      }
    } catch (_) {
      // Preferences are an enhancement; default to showing every alert if the
      // device store is unavailable or corrupt.
      _hiddenAlertTypes.clear();
    } finally {
      _alertVisibilityLoaded = true;
    }
    if (_allAlerts.isNotEmpty) {
      _rebuildVisibleAlerts();
      _notify();
    }
  }

  bool _rememberAlertTypes(Iterable<WeatherAlert> freshAlerts) {
    var changed = false;
    for (final alert in freshAlerts) {
      final normalized = _normalizeAlertType(alert.event);
      if (normalized.isEmpty) continue;
      if (_knownAlertTypeLabels.containsKey(normalized)) continue;
      _knownAlertTypeLabels[normalized] = alert.event;
      changed = true;
    }
    return changed;
  }

  void _rebuildVisibleAlerts() {
    _visibleAlerts = List.unmodifiable(
      _allAlerts.where((alert) => isAlertTypeVisible(alert.event)),
    );
    _alertGeoJson = {
      'type': 'FeatureCollection',
      'features': _visibleAlerts
          .where((alert) => alert.hasMapGeometry)
          .map((alert) => alert.toGeoJsonFeature())
          .toList(growable: false),
    };
    alertRevision++;
  }

  Future<void> _saveAlertVisibility() async {
    if (!_alertVisibilityLoaded || _disposed) return;
    try {
      await _alertVisibilityStore.save(
        hiddenTypes: Set.unmodifiable(_hiddenAlertTypes),
        knownTypes: Set.unmodifiable(_knownAlertTypeLabels.values.toSet()),
      );
    } catch (_) {
      // Keep the in-memory selection for this session if persistence fails.
    }
  }

  RadarStation? _stationById(String id) {
    for (final station in stations) {
      if (station.id == id) return station;
    }
    return null;
  }

  void _normalizeSelection() {
    final station = selectedStation;
    final available = elevations;
    if (station == null || available.isEmpty) {
      selectedElevation = null;
      return;
    }
    if (!available.contains(selectedElevation)) {
      selectedElevation = available.first;
    }
  }

  void _invalidateAndRefresh() {
    _radarRequest++;
    _loadingRadar = false;
    _notify();
    unawaited(_restartUpdates());
    unawaited(refreshRadar());
  }

  Future<void> _restartUpdates() async {
    final generation = ++_updatesGeneration;
    _updatesReconnectTimer?.cancel();
    await _updatesSubscription?.cancel();
    _updatesSubscription = null;
    if (_disposed ||
        generation != _updatesGeneration ||
        (mode.requiresStation && selectedStation == null)) {
      return;
    }

    final stream = _api.watchUpdates(
      mode: mode,
      station: selectedStation,
      elevation: selectedElevation,
    );
    _updatesSubscription = stream.listen(
      (update) {
        if (_disposed || generation != _updatesGeneration) return;
        if (update.snapshot != null &&
            (update.radarChanged || snapshot == null)) {
          snapshot = update.snapshot;
          radarError = null;
          _notify();
        }
        if (update.refreshAlerts) unawaited(refreshAlerts());
      },
      onError: (Object error, StackTrace stackTrace) {
        _scheduleUpdatesReconnect(generation);
      },
      onDone: () => _scheduleUpdatesReconnect(generation),
      cancelOnError: false,
    );
  }

  void _scheduleUpdatesReconnect(int generation) {
    if (_disposed || generation != _updatesGeneration) return;
    _updatesReconnectTimer?.cancel();
    _updatesReconnectTimer = Timer(const Duration(seconds: 5), () {
      if (!_disposed && generation == _updatesGeneration) {
        unawaited(_restartUpdates());
      }
    });
  }

  void _notify() {
    if (_disposed) return;
    for (final listener in List<VoidCallback>.from(_listeners)) {
      listener();
    }
  }

  void dispose() {
    _disposed = true;
    _radarTimer?.cancel();
    _alertsTimer?.cancel();
    _stationsTimer?.cancel();
    _updatesReconnectTimer?.cancel();
    unawaited(_updatesSubscription?.cancel());
    _listeners.clear();
    _api.close();
  }
}

Map<String, dynamic> _emptyFeatureCollection() => {
  'type': 'FeatureCollection',
  'features': <dynamic>[],
};

const _defaultKnownAlertTypes = <String>['Air Quality Alert'];

String _normalizeAlertType(String value) => value.trim().toLowerCase();
