import 'dart:async';

import '../config/app_config.dart';
import '../models/radar_models.dart';
import '../services/radar_api.dart';

typedef VoidCallback = void Function();

final class RadarController {
  RadarController({RadarApi? api})
    : _api = api ?? RadarApi(baseUrl: AppConfig.apiBaseUrl);

  final RadarApi _api;
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

  RadarMode mode = RadarMode.aggregate;
  RadarStation? selectedStation;
  String? selectedElevation;
  RadarSnapshot? snapshot;
  List<RadarStation> stations = const [];
  List<WeatherAlert> alerts = const [];
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
      alerts = fresh.alerts;
      if (fresh.changed) {
        _alertGeoJson = {
          'type': 'FeatureCollection',
          'features': fresh.alerts
              .where((alert) => alert.hasMapGeometry)
              .map((alert) => alert.toGeoJsonFeature())
              .toList(growable: false),
        };
        alertRevision++;
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
    for (final alert in alerts) {
      if (alert.id == id) return alert;
    }
    return null;
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
