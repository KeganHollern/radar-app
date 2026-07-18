import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../controllers/nearby_location_gate.dart';
import '../controllers/radar_controller.dart';
import '../controllers/radar_layer_swap.dart';
import '../controllers/startup_camera_focus.dart';
import '../models/alert_selection.dart';
import '../models/radar_models.dart';
import '../services/location_service.dart';
import '../services/native_startup_location_source.dart';
import '../services/startup_location_resolver.dart';
import '../services/startup_location_store.dart';
import '../theme/flexoki_theme.dart';
import '../widgets/map_attribution.dart';
import '../widgets/landscape_side_panel.dart';
import '../widgets/radar_legend.dart';
import '../widgets/responsive_map_chrome.dart';
import '../widgets/settings_panel.dart';
import '../widgets/status_banner.dart';

class RadarMapScreen extends StatefulWidget {
  const RadarMapScreen({
    super.key,
    this.startupLocationStore,
    this.nativeStartupLocationSource,
  });

  final StartupLocationStore? startupLocationStore;
  final NativeStartupLocationSource? nativeStartupLocationSource;

  @override
  State<RadarMapScreen> createState() => _RadarMapScreenState();
}

class _RadarMapScreenState extends State<RadarMapScreen>
    with WidgetsBindingObserver {
  static const _radarOpacity = 0.62;
  // Keep the pending layer renderable so MapLibre fetches its visible tiles,
  // while making its contribution imperceptible beneath the active layer.
  static const _radarPreloadOpacity = 0.001;
  static const _alertsSource = 'weather-alerts-source';
  static const _alertsFillLayer = 'weather-alerts-fill';
  static const _alertsLineLayer = 'weather-alerts-outline';
  static const _stationsSource = 'radar-stations-source';
  static const _stationsLayer = 'radar-stations-layer';
  static const _fallbackCameraPosition = CameraPosition(
    target: LatLng(39.5, -98.35),
    zoom: 3.25,
  );

  late final RadarController _radar;
  late final StartupLocationStore _startupLocationStore;
  late final StartupLocationWriter _startupLocationWriter;
  late final StartupLocationResolver _startupLocationResolver;
  final LocationService _location = LocationService();
  final StartupCameraFocus _startupCameraFocus = StartupCameraFocus();
  final NearbyLocationGate _nearbyLocationGate = NearbyLocationGate();
  final RadarLayerSwapCoordinator _radarLayers = RadarLayerSwapCoordinator();
  MapLibreMapController? _map;
  int _styleGeneration = 0;
  LocationAccess _locationAccess = LocationAccess.checking;
  bool _styleLoaded = false;
  bool _pinLocation = false;
  bool _restoreTracking = false;
  bool _baseSourcesInstalled = false;
  RadarLayerCandidate? _radarSwapAwaitingIdle;
  RadarLayerCandidate? _radarSwapReady;
  int _renderedStationRevision = -1;
  int _renderedAlertRevision = -1;
  bool _styleSyncRunning = false;
  bool _styleSyncPending = false;
  bool _forceStyleSync = false;
  bool _handlingAlertTap = false;
  LatLng? _latestUserLocation;
  CameraPosition? _initialCameraPosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startupLocationStore =
        widget.startupLocationStore ?? SharedPreferencesStartupLocationStore();
    _startupLocationWriter = StartupLocationWriter(_startupLocationStore);
    _startupLocationResolver = StartupLocationResolver(
      local: _startupLocationStore,
      native:
          widget.nativeStartupLocationSource ??
          GeolocatorNativeStartupLocationSource(),
    );
    _radar = RadarController()..addListener(_onRadarChanged);
    unawaited(_prepareInitialCamera());
    unawaited(_radar.initialize());
    unawaited(_requestLocation());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_radar.resume());
      unawaited(_requestLocation());
    } else {
      unawaited(_startupLocationWriter.flush());
    }
  }

  Future<void> _prepareInitialCamera() async {
    final saved = await _startupLocationResolver.load();
    if (!mounted) return;
    setState(() {
      _initialCameraPosition = saved == null
          ? _fallbackCameraPosition
          : CameraPosition(
              target: saved.position,
              zoom: StartupCameraFocus.zoom,
            );
    });
  }

  Future<void> _requestLocation() async {
    final access = await _location.requestAccess();
    if (!mounted) return;
    setState(() => _locationAccess = access);
    if (access == LocationAccess.granted && _pinLocation) {
      await _setTrackingMode(MyLocationTrackingMode.tracking);
    }
  }

  void _onRadarChanged() {
    if (!mounted) return;
    setState(() {});
    _queueStyleSync();
  }

  void _onMapCreated(MapLibreMapController controller) {
    _map = controller;
    controller.onFeatureTapped.add(_onFeatureTapped);
    _updateNearbyDetailStation(controller.cameraPosition?.target);
    unawaited(_applyStartupCameraFocus());
  }

  void _onStyleLoaded() {
    _styleGeneration++;
    _styleLoaded = true;
    _baseSourcesInstalled = false;
    _radarLayers.reset();
    _clearRadarSwapReadiness();
    _renderedStationRevision = -1;
    _renderedAlertRevision = -1;
    _updateNearbyDetailStation(_map?.cameraPosition?.target);
    _queueStyleSync(force: true);
    unawaited(_applyStartupCameraFocus());
    if (_pinLocation && _locationAccess == LocationAccess.granted) {
      unawaited(_setTrackingMode(MyLocationTrackingMode.tracking));
    }
  }

  void _onUserLocationUpdated(UserLocation location) {
    if (!_nearbyLocationGate.accept(
      timestamp: location.timestamp,
      horizontalAccuracy: location.horizontalAccuracy,
    )) {
      return;
    }
    _latestUserLocation = location.position;
    _startupLocationWriter.record(
      StartupLocation(
        position: location.position,
        observedAt: location.timestamp,
      ),
    );
    _startupCameraFocus.updateLocation(location.position);
    if (_pinLocation) _updateNearbyDetailStation(location.position);
    unawaited(_applyStartupCameraFocus());
  }

  Future<void> _applyStartupCameraFocus() async {
    final map = _map;
    final target = _startupCameraFocus.takeTarget(
      mapReady: map != null && _styleLoaded && !_pinLocation,
    );
    if (map == null || target == null) return;

    var succeeded = false;
    try {
      final result = await map.animateCamera(
        CameraUpdate.newLatLngZoom(target, StartupCameraFocus.zoom),
        duration: const Duration(milliseconds: 700),
      );
      // MapLibre returns null on iOS even when the animation is accepted.
      succeeded = result != false;
    } catch (error) {
      debugPrint('Unable to focus the startup location: $error');
    } finally {
      _startupCameraFocus.finish(succeeded: succeeded);
    }
    _updateNearbyDetailStation(succeeded ? target : map.cameraPosition?.target);
  }

  void _onMapPointerDown(PointerDownEvent event) {
    _startupCameraFocus.abandon();
  }

  void _queueStyleSync({bool force = false}) {
    if (!_styleLoaded || _map == null) return;
    _styleSyncPending = true;
    _forceStyleSync |= force;
    if (_styleSyncRunning) return;
    _styleSyncRunning = true;
    unawaited(_drainStyleSync());
  }

  Future<void> _drainStyleSync() async {
    try {
      while (mounted && _styleSyncPending) {
        _styleSyncPending = false;
        final force = _forceStyleSync;
        _forceStyleSync = false;
        try {
          await _syncStyle(force: force);
        } catch (error) {
          debugPrint('Map style update failed: $error');
        }
      }
    } finally {
      _styleSyncRunning = false;
      if (mounted && _styleSyncPending) _queueStyleSync();
    }
  }

  Future<void> _syncStyle({required bool force}) async {
    final map = _map;
    if (map == null || !_styleLoaded) return;
    final styleGeneration = _styleGeneration;

    if (!_baseSourcesInstalled) {
      await map.addGeoJsonSource(
        _alertsSource,
        _emptyFeatureCollection,
        promoteId: 'id',
      );
      if (!_isCurrentStyle(map, styleGeneration)) return;
      await map.addFillLayer(
        _alertsSource,
        _alertsFillLayer,
        const FillLayerProperties(
          fillColor: ['get', 'alert_color'],
          fillOpacity: 0.25,
          fillOutlineColor: ['get', 'alert_color'],
        ),
        enableInteraction: true,
      );
      if (!_isCurrentStyle(map, styleGeneration)) return;
      await map.addLineLayer(
        _alertsSource,
        _alertsLineLayer,
        const LineLayerProperties(
          lineColor: ['get', 'alert_color'],
          lineOpacity: 0.95,
          lineWidth: 2.5,
        ),
        enableInteraction: false,
      );
      if (!_isCurrentStyle(map, styleGeneration)) return;
      await map.addGeoJsonSource(
        _stationsSource,
        _emptyFeatureCollection,
        promoteId: 'id',
      );
      if (!_isCurrentStyle(map, styleGeneration)) return;
      await map.addCircleLayer(
        _stationsSource,
        _stationsLayer,
        const CircleLayerProperties(
          circleRadius: [
            'interpolate',
            ['linear'],
            ['zoom'],
            3,
            4,
            7,
            8,
            11,
            12,
          ],
          circleColor: '#3AA99F',
          circleOpacity: 0.9,
          circleStrokeWidth: 2,
          circleStrokeColor: '#FFFCF0',
        ),
        minzoom: 2.5,
        enableInteraction: true,
      );
      if (!_isCurrentStyle(map, styleGeneration)) return;
      _baseSourcesInstalled = true;
    }

    final stationRevision = _radar.stationRevision;
    if (stationRevision != _renderedStationRevision) {
      final stationGeoJson = _radar.stationGeoJson;
      await map.setGeoJsonSource(_stationsSource, stationGeoJson);
      if (!_isCurrentStyle(map, styleGeneration)) return;
      _renderedStationRevision = stationRevision;
    }
    final alertRevision = _radar.alertRevision;
    if (alertRevision != _renderedAlertRevision) {
      final alertGeoJson = _radar.alertGeoJson;
      await map.setGeoJsonSource(_alertsSource, alertGeoJson);
      if (!_isCurrentStyle(map, styleGeneration)) return;
      _renderedAlertRevision = alertRevision;
    }

    final nextKey = _radar.radarLayerKey;
    final tileTemplate = _radar.activeTileTemplate;
    final effectiveKey = tileTemplate == null ? '' : nextKey;
    if (effectiveKey.isEmpty &&
        _radar.isLoadingRadar &&
        _radarLayers.active != null) {
      // Explicit station/mode/elevation changes clear the controller snapshot
      // while their replacement manifest is loading. Keep the last complete
      // layer visible until that manifest can be staged.
      return;
    }
    if (force && _radarLayers.hasLayers) {
      await _retireRadarCandidates(map, _radarLayers.reset().retired);
      _clearRadarSwapReadiness();
      if (!_isCurrentStyle(map, styleGeneration)) return;
    }

    final transition = _radarLayers.reconcile(
      key: effectiveKey,
      resampling: _radar.mode == RadarMode.stationVelocity
          ? 'nearest'
          : 'linear',
    );
    await _applyRadarTransition(map, transition, tileTemplate: tileTemplate);
    if (!_isCurrentStyle(map, styleGeneration)) {
      final candidate = transition.candidate;
      if (candidate != null) {
        await _retireRadarCandidates(map, [candidate]);
      }
      _radarLayers.reset();
      _clearRadarSwapReadiness();
      return;
    }

    final pending = _radarLayers.pending;
    final currentTileTemplate = _radar.activeTileTemplate;
    final currentKey = currentTileTemplate == null ? '' : _radar.radarLayerKey;
    if (pending != null &&
        !_radar.isLoadingRadar &&
        identical(_radarSwapAwaitingIdle, pending) &&
        identical(_radarSwapReady, pending) &&
        pending.key == effectiveKey &&
        pending.key == currentKey) {
      await _promoteRadarCandidate(
        map,
        pending,
        styleGeneration: styleGeneration,
      );
    }
  }

  Future<void> _applyRadarTransition(
    MapLibreMapController map,
    RadarLayerTransition transition, {
    required String? tileTemplate,
  }) async {
    switch (transition.kind) {
      case RadarLayerTransitionKind.none:
        return;
      case RadarLayerTransitionKind.reset:
      case RadarLayerTransitionKind.discardPending:
        _clearRadarSwapReadiness();
        await _retireRadarCandidates(map, transition.retired);
        return;
      case RadarLayerTransitionKind.install:
        _clearRadarSwapReadiness();
        await _retireRadarCandidates(map, transition.retired);
        final candidate = transition.candidate!;
        try {
          // A prior platform failure may have left this otherwise inactive
          // slot behind. Cleanup is idempotent and the coordinator commits a
          // retryable empty state if installation still fails.
          await _retireRadarCandidates(map, [candidate]);
          await _addRadarCandidate(
            map,
            candidate,
            tileTemplate: tileTemplate!,
            opacity: _radarOpacity,
            belowLayerId: await _radarBelowLayer(map),
          );
        } catch (_) {
          await _retireRadarCandidates(map, _radarLayers.reset().retired);
          rethrow;
        }
        return;
      case RadarLayerTransitionKind.stage:
      case RadarLayerTransitionKind.supersede:
        _clearRadarSwapReadiness();
        await _retireRadarCandidates(map, transition.retired);
        final candidate = transition.candidate!;
        try {
          await _retireRadarCandidates(map, [candidate]);
          await _addRadarCandidate(
            map,
            candidate,
            tileTemplate: tileTemplate!,
            opacity: _radarPreloadOpacity,
            belowLayerId: _radarLayers.active!.layerId,
          );
        } catch (_) {
          await _retireRadarCandidates(
            map,
            _radarLayers.discardPending().retired,
          );
          rethrow;
        }
        if (identical(_radarLayers.pending, candidate)) {
          _radarSwapAwaitingIdle = candidate;
        }
        return;
      case RadarLayerTransitionKind.promote:
        // Promotion is applied only by [_promoteRadarCandidate], after the
        // native layer has been made visible and the old slot is retired.
        return;
    }
  }

  Future<void> _addRadarCandidate(
    MapLibreMapController map,
    RadarLayerCandidate candidate, {
    required String tileTemplate,
    required double opacity,
    required String? belowLayerId,
  }) async {
    await map.addSource(
      candidate.sourceId,
      RasterSourceProperties(
        tiles: [tileTemplate],
        tileSize: 256,
        minzoom: 0,
        maxzoom: 12,
        attribution: 'Weather data: NOAA/NWS',
      ),
    );
    try {
      await map.addRasterLayer(
        candidate.sourceId,
        candidate.layerId,
        _radarLayerProperties(candidate, opacity),
        belowLayerId: belowLayerId,
      );
    } catch (_) {
      try {
        await map.removeSource(candidate.sourceId);
      } catch (_) {
        // The source may already be absent after a partial native add.
      }
      rethrow;
    }
  }

  Future<void> _promoteRadarCandidate(
    MapLibreMapController map,
    RadarLayerCandidate pending, {
    required int styleGeneration,
  }) async {
    final active = _radarLayers.active;
    await map.setLayerProperties(
      pending.layerId,
      _radarLayerProperties(pending, _radarOpacity),
    );
    if (!_isCurrentStyle(map, styleGeneration) ||
        !identical(_radarLayers.pending, pending)) {
      await _retireRadarCandidates(map, [pending]);
      return;
    }
    final currentTemplate = _radar.activeTileTemplate;
    final currentKey = currentTemplate == null ? '' : _radar.radarLayerKey;
    if (_radar.isLoadingRadar ||
        !identical(_radarSwapReady, pending) ||
        currentKey != pending.key) {
      // The camera or desired generation changed while the native property
      // update was in flight. Keep preloading beneath the active layer and
      // wait for a fresh idle signal (or the queued superseding transition).
      await map.setLayerProperties(
        pending.layerId,
        _radarLayerProperties(pending, _radarPreloadOpacity),
      );
      return;
    }
    if (active != null) await _retireRadarCandidates(map, [active]);

    final promotion = _radarLayers.promote();
    if (!identical(promotion.candidate, pending)) return;
    _clearRadarSwapReadiness();
  }

  RasterLayerProperties _radarLayerProperties(
    RadarLayerCandidate candidate,
    double opacity,
  ) => RasterLayerProperties(
    rasterOpacity: opacity,
    // Preserve the previously rendered parent/child tile while MapLibre adds
    // its replacement at a new zoom level. All tile URLs are generation-pinned,
    // so this crossfade cannot mix different live scans.
    rasterFadeDuration: 300,
    // Velocity bins are categorical measurements. Preserve nearest-neighbor
    // sampling both while preloading and after the slot is promoted.
    rasterResampling: candidate.resampling,
  );

  Future<void> _retireRadarCandidates(
    MapLibreMapController map,
    Iterable<RadarLayerCandidate> candidates,
  ) async {
    final retiredSlots = <RadarLayerSlot>{};
    for (final candidate in candidates) {
      if (!retiredSlots.add(candidate.slot)) continue;
      try {
        await map.removeLayer(candidate.layerId);
      } catch (_) {
        // Cleanup is deliberately idempotent: a source can be absent after a
        // style reload or a partially failed native add.
      }
      try {
        await map.removeSource(candidate.sourceId);
      } catch (_) {
        // See the layer cleanup note above.
      }
    }
  }

  bool _isCurrentStyle(MapLibreMapController map, int generation) =>
      mounted &&
      identical(_map, map) &&
      _styleLoaded &&
      _styleGeneration == generation;

  void _clearRadarSwapReadiness() {
    _radarSwapAwaitingIdle = null;
    _radarSwapReady = null;
  }

  Future<String?> _radarBelowLayer(MapLibreMapController map) async {
    final layerIds = await map.getLayerIds();
    for (final rawId in layerIds.reversed) {
      final id = rawId.toString();
      if (id == _alertsFillLayer ||
          id == _alertsLineLayer ||
          id == _stationsLayer) {
        continue;
      }
      if (id.toLowerCase().contains('label') ||
          id.toLowerCase().contains('place')) {
        return id;
      }
    }
    return null;
  }

  void _onFeatureTapped(
    Point<double> point,
    LatLng coordinates,
    String id,
    String layerId,
    Annotation? annotation,
  ) {
    if (layerId == _stationsLayer) {
      _radar.selectStationById(id);
      final station = _radar.selectedStation;
      if (station != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text('Viewing ${station.name} (${station.id})'),
          ),
        );
      }
      return;
    }
    if (layerId == _alertsFillLayer || layerId == _alertsLineLayer) {
      unawaited(_handleAlertTap(point, id));
    }
  }

  Future<void> _handleAlertTap(Point<double> point, String fallbackId) async {
    if (_handlingAlertTap) return;
    _handlingAlertTap = true;
    try {
      List<dynamic> features = const [];
      try {
        features =
            await _map?.queryRenderedFeatures(point, const [
              _alertsFillLayer,
            ], null) ??
            const [];
      } catch (error) {
        debugPrint('Unable to query overlapping alerts: $error');
      }
      if (!mounted) return;
      final alerts = resolveAlertsAtTap(
        renderedFeatures: features,
        visibleAlerts: _radar.alerts,
        fallbackId: fallbackId,
      );
      if (alerts.length == 1) {
        _showAlert(alerts.single);
      } else if (alerts.length > 1) {
        await _showAlertsAtLocation(alerts);
      }
    } finally {
      _handlingAlertTap = false;
    }
  }

  Future<void> _togglePin() async {
    if (_locationAccess != LocationAccess.granted) {
      await _requestLocation();
      if (_locationAccess != LocationAccess.granted) return;
    }
    final next = !_pinLocation;
    if (next) _startupCameraFocus.abandon();
    setState(() => _pinLocation = next);
    if (next) _updateNearbyDetailStation(_latestUserLocation);
    await _setTrackingMode(
      next ? MyLocationTrackingMode.tracking : MyLocationTrackingMode.none,
    );
  }

  Future<void> _setTrackingMode(MyLocationTrackingMode mode) async {
    final map = _map;
    if (map == null) return;
    try {
      await map.updateMyLocationTrackingMode(mode);
    } catch (error) {
      debugPrint('Unable to update location tracking: $error');
    }
  }

  void _onTrackingDismissed() {
    if (_pinLocation) _restoreTracking = true;
  }

  void _onCameraIdle() {
    _updateNearbyDetailStation(
      _pinLocation ? _latestUserLocation : _map?.cameraPosition?.target,
    );
    if (_pinLocation && _restoreTracking) {
      _restoreTracking = false;
      unawaited(_setTrackingMode(MyLocationTrackingMode.tracking));
    }
  }

  void _onCameraMove(CameraPosition _) {
    // A readiness signal belongs to the viewport that produced it. The staged
    // source keeps loading while the camera moves and must become idle again
    // at the new viewport before it can replace the visible layer.
    _radarSwapReady = null;
  }

  void _onMapIdle() {
    final pending = _radarLayers.pending;
    if (pending == null || !identical(_radarSwapAwaitingIdle, pending)) return;
    _radarSwapReady = pending;
    _queueStyleSync();
  }

  void _updateNearbyDetailStation(LatLng? target) {
    if (target == null) return;
    _radar.updateNearbyDetailStation(
      latitude: target.latitude,
      longitude: target.longitude,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _initialCameraPosition == null
                ? const ColoredBox(color: Flexoki.black)
                : Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _onMapPointerDown,
                    child: MapLibreMap(
                      styleString: AppConfig.mapStyleUrl,
                      initialCameraPosition: _initialCameraPosition!,
                      minMaxZoomPreference: const MinMaxZoomPreference(2.5, 15),
                      onMapCreated: _onMapCreated,
                      onStyleLoadedCallback: _onStyleLoaded,
                      onUserLocationUpdated: _onUserLocationUpdated,
                      onCameraTrackingDismissed: _onTrackingDismissed,
                      onCameraMove: _onCameraMove,
                      onCameraIdle: _onCameraIdle,
                      onMapIdle: _onMapIdle,
                      myLocationEnabled:
                          _locationAccess == LocationAccess.granted,
                      myLocationTrackingMode: MyLocationTrackingMode.none,
                      myLocationRenderMode: MyLocationRenderMode.normal,
                      trackCameraPosition: true,
                      compassEnabled: true,
                      rotateGesturesEnabled: false,
                      tiltGesturesEnabled: false,
                      logoEnabled: false,
                      attributionButtonPosition:
                          AttributionButtonPosition.bottomRight,
                      // maplibre_gl exposes ornament margins but no way to disable
                      // its native attribution button. Move that broken duplicate
                      // outside the viewport; the compact Flutter source button
                      // supplies the visible, accessible attribution interaction.
                      attributionButtonMargins: const Point(-64, -64),
                      foregroundLoadColor: Flexoki.black,
                    ),
                  ),
          ),
          ResponsiveMapChrome(
            status: _LiveStatusCard(
              radar: _radar,
              onRefresh: () => _radar.refreshAll(userInitiated: true),
              onOpenAlerts: _showAlerts,
              onOpenSettings: _showSettings,
            ),
            statusBanners: [
              if (_radar.radarError != null)
                StatusBanner(
                  icon: Icons.cloud_off_rounded,
                  message: _radar.radarError!,
                  onTap: _radar.refreshRadar,
                ),
              if (_radar.alertsStale || _radar.alertsError != null)
                StatusBanner(
                  icon: Icons.warning_amber_rounded,
                  message: _alertStatusMessage(_radar),
                  loading: _radar.isLoadingAlerts,
                  loadingSemanticLabel: 'Refreshing weather alerts',
                  onTap: () => _radar.refreshAlerts(userInitiated: true),
                ),
              if (_locationAccess != LocationAccess.granted &&
                  _locationAccess != LocationAccess.checking)
                StatusBanner(
                  icon: Icons.location_off_rounded,
                  message: _locationMessage,
                  onTap: () async {
                    if (_locationAccess == LocationAccess.deniedForever ||
                        _locationAccess == LocationAccess.servicesDisabled) {
                      await _location.openSettings(_locationAccess);
                    }
                    await _requestLocation();
                  },
                ),
            ],
            legend: RadarLegend(mode: _radar.mode, compact: _isLandscape),
            radarControls: _RadarControls(
              radar: _radar,
              onOpenModes: _showRadarModes,
            ),
            settingsButton: _SettingsButton(onPressed: _showSettings),
            attributionButton: MapAttributionButton(
              credit: AppConfig.mapAttributionCompact,
              onPressed: _showMapAttribution,
            ),
            pinButton: _PinButton(pinned: _pinLocation, onPressed: _togglePin),
          ),
        ],
      ),
    );
  }

  String get _locationMessage => switch (_locationAccess) {
    LocationAccess.servicesDisabled => 'Location is off — tap to open settings',
    LocationAccess.deniedForever =>
      'Location permission blocked — tap to open settings',
    _ => 'Location permission is needed for your position and follow mode',
  };

  bool get _isLandscape =>
      MediaQuery.orientationOf(context) == Orientation.landscape;

  void _showRadarModes() {
    if (_isLandscape) {
      showLandscapeSidePanel<void>(
        context: context,
        barrierLabel: 'Close live radar controls',
        builder: (context, scrollController) =>
            RadarModePanel(radar: _radar, scrollController: scrollController),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => RadarModePanel(radar: _radar),
    );
  }

  void _showSettings() {
    if (_isLandscape) {
      showLandscapeSidePanel<void>(
        context: context,
        barrierLabel: 'Close settings',
        builder: (context, scrollController) => StatefulBuilder(
          builder: (context, setPanelState) => RadarSettingsPanel(
            scrollController: scrollController,
            landscape: true,
            alertTypes: _radar.knownAlertTypes,
            alertTypeCounts: _radar.alertTypeCounts,
            isAlertTypeVisible: _radar.isAlertTypeVisible,
            onAlertTypeChanged: (alertType, visible) {
              _radar.setAlertTypeVisible(alertType, visible);
              setPanelState(() {});
            },
            onShowAllAlertTypes: () {
              _radar.showAllAlertTypes();
              setPanelState(() {});
            },
          ),
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.42,
        maxChildSize: 0.94,
        builder: (context, scrollController) => StatefulBuilder(
          builder: (context, setSheetState) => RadarSettingsPanel(
            scrollController: scrollController,
            alertTypes: _radar.knownAlertTypes,
            alertTypeCounts: _radar.alertTypeCounts,
            isAlertTypeVisible: _radar.isAlertTypeVisible,
            onAlertTypeChanged: (alertType, visible) {
              _radar.setAlertTypeVisible(alertType, visible);
              setSheetState(() {});
            },
            onShowAllAlertTypes: () {
              _radar.showAllAlertTypes();
              setSheetState(() {});
            },
          ),
        ),
      ),
    );
  }

  void _showMapAttribution() {
    if (_isLandscape) {
      showLandscapeSidePanel<void>(
        context: context,
        barrierLabel: 'Close data sources',
        builder: (context, scrollController) => MapAttributionPanel(
          scrollController: scrollController,
          mapAttributions: AppConfig.mapAttributions,
          onOpenLink: _openAttributionLink,
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => MapAttributionPanel(
        mapAttributions: AppConfig.mapAttributions,
        onOpenLink: _openAttributionLink,
      ),
    );
  }

  Future<void> _openAttributionLink(Uri uri) async {
    var opened = false;
    try {
      opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (error) {
      debugPrint('Unable to open attribution link: $error');
    }
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Unable to open the source website.')),
    );
  }

  void _showAlerts() {
    if (_isLandscape) {
      showLandscapeSidePanel<void>(
        context: context,
        barrierLabel: 'Close active weather alerts',
        builder: (context, scrollController) => _AlertsListSheet(
          alerts: _radar.alerts,
          scrollController: scrollController,
          onSelect: _showAlert,
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.68,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (context, scrollController) => _AlertsListSheet(
          alerts: _radar.alerts,
          scrollController: scrollController,
          onSelect: _showAlert,
        ),
      ),
    );
  }

  void _showAlert(WeatherAlert alert) {
    if (_isLandscape) {
      showLandscapeSidePanel<void>(
        context: context,
        barrierLabel: 'Close ${alert.event}',
        builder: (context, scrollController) =>
            _AlertSheet(alert: alert, scrollController: scrollController),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.58,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        builder: (context, scrollController) =>
            _AlertSheet(alert: alert, scrollController: scrollController),
      ),
    );
  }

  Future<void> _showAlertsAtLocation(List<WeatherAlert> alerts) async {
    WeatherAlert? selected;
    if (_isLandscape) {
      selected = await showLandscapeSidePanel<WeatherAlert>(
        context: context,
        barrierLabel: 'Close overlapping weather alerts',
        builder: (context, scrollController) => _AlertsAtLocationSheet(
          alerts: alerts,
          scrollController: scrollController,
          onSelect: (alert) => Navigator.pop(context, alert),
        ),
      );
    } else {
      selected = await showModalBottomSheet<WeatherAlert>(
        context: context,
        isScrollControlled: true,
        builder: (context) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: min(0.78, 0.24 + alerts.length * 0.14),
          minChildSize: 0.32,
          maxChildSize: 0.9,
          builder: (context, scrollController) => _AlertsAtLocationSheet(
            alerts: alerts,
            scrollController: scrollController,
            onSelect: (alert) => Navigator.pop(context, alert),
          ),
        ),
      );
    }
    if (selected != null && mounted) _showAlert(selected);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_startupLocationWriter.flush());
    _radar.removeListener(_onRadarChanged);
    _radar.dispose();
    _map?.dispose();
    super.dispose();
  }
}

const Map<String, dynamic> _emptyFeatureCollection = {
  'type': 'FeatureCollection',
  'features': <dynamic>[],
};

class _LiveStatusCard extends StatelessWidget {
  const _LiveStatusCard({
    required this.radar,
    required this.onRefresh,
    required this.onOpenAlerts,
    required this.onOpenSettings,
  });

  final RadarController radar;
  final Future<void> Function() onRefresh;
  final VoidCallback onOpenAlerts;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final observedAt = radar.snapshot?.observedAt.toLocal();
    final unavailable = radar.radarError != null;
    final stale = radar.snapshot?.stale == true;
    final badgeLabel = unavailable
        ? 'OFFLINE'
        : stale
        ? 'STALE'
        : 'LIVE';
    final badgeColor = unavailable
        ? Flexoki.base500
        : stale
        ? Flexoki.yellow
        : Flexoki.red;
    final status = radar.isLoadingRadar && radar.snapshot == null
        ? 'Connecting…'
        : observedAt == null
        ? 'Waiting for live scan'
        : unavailable
        ? 'Last scan · ${_relativeAge(observedAt)}'
        : stale
        ? 'Stale scan · ${_relativeAge(observedAt)}'
        : 'Latest scan · ${_relativeAge(observedAt)}';
    final refreshing =
        radar.isLoadingRadar ||
        radar.isLoadingAlerts ||
        radar.isLoadingStations;
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (landscape) {
      return Card(
        key: const ValueKey('landscape-live-status-card'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: badgeColor.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: badgeColor.withValues(alpha: 0.55),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.circle, size: 7, color: badgeColor),
                                const SizedBox(width: 5),
                                Flexible(
                                  child: Text(
                                    badgeLabel,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Flexoki.paper,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.7,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (radar.alerts.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Semantics(
                            button: true,
                            label:
                                '${radar.alerts.length} active weather alerts',
                            child: Tooltip(
                              message: 'View active weather alerts',
                              child: InkWell(
                                onTap: onOpenAlerts,
                                borderRadius: BorderRadius.circular(999),
                                child: ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    minWidth: 48,
                                    minHeight: 48,
                                  ),
                                  child: Center(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Flexoki.yellow.withValues(
                                          alpha: 0.16,
                                        ),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.warning_amber_rounded,
                                            size: 16,
                                            color: Flexoki.yellow,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            '${radar.alerts.length}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      radar.mode.shortLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 1),
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Flexoki.base500,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                key: const ValueKey('landscape-refresh-button'),
                tooltip: refreshing ? 'Refreshing live data' : 'Refresh now',
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                padding: EdgeInsets.zero,
                onPressed: refreshing ? null : onRefresh,
                icon: refreshing
                    ? const SizedBox.square(
                        dimension: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_rounded, size: 21),
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      key: const ValueKey('portrait-live-status-card'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: badgeColor.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: badgeColor.withValues(alpha: 0.55)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.circle, size: 8, color: badgeColor),
                  const SizedBox(width: 6),
                  Text(
                    badgeLabel,
                    style: const TextStyle(
                      color: Flexoki.paper,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    radar.mode.shortLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    status,
                    style: const TextStyle(
                      color: Flexoki.base500,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (radar.alerts.isNotEmpty)
              Semantics(
                button: true,
                label: '${radar.alerts.length} active weather alerts',
                child: Tooltip(
                  message: 'View active weather alerts',
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: onOpenAlerts,
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        margin: const EdgeInsets.only(right: 2),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Flexoki.yellow.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              size: 18,
                              color: Flexoki.yellow,
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '${radar.alerts.length}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            IconButton(
              tooltip: 'Alert display settings',
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
            IconButton(
              tooltip: refreshing ? 'Refreshing live data' : 'Refresh now',
              onPressed: refreshing ? null : onRefresh,
              icon: refreshing
                  ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadarControls extends StatelessWidget {
  const _RadarControls({required this.radar, required this.onOpenModes});

  final RadarController radar;
  final VoidCallback onOpenModes;

  @override
  Widget build(BuildContext context) {
    final station = radar.selectedStation;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onOpenModes,
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.radar_rounded, color: Flexoki.cyan),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      radar.mode.label,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  const Icon(Icons.tune_rounded, color: Flexoki.base500),
                ],
              ),
              if (radar.mode.requiresStation) ...[
                const SizedBox(height: 7),
                Text(
                  station == null
                      ? 'Tap a station dot on the map'
                      : '${station.name} · ${station.id}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: station == null ? Flexoki.yellow : Flexoki.base700,
                    fontSize: 13,
                  ),
                ),
                if (station != null) ...[
                  const SizedBox(height: 7),
                  _ElevationPicker(radar: radar, compact: true),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PinButton extends StatelessWidget {
  const _PinButton({required this.pinned, required this.onPressed});

  final bool pinned;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: pinned,
      label: pinned ? 'Stop following my location' : 'Follow my location',
      child: Material(
        color: pinned ? Flexoki.cyan : Flexoki.base100,
        elevation: 9,
        shadowColor: Colors.black87,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: pinned ? Flexoki.cyan : Flexoki.base300),
        ),
        child: InkWell(
          key: const ValueKey('pin-location-button'),
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: SizedBox.square(
            dimension: mapUtilityButtonDimension,
            child: Icon(
              pinned ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
              size: 30,
              color: pinned ? Flexoki.black : Flexoki.paper,
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsButton extends StatelessWidget {
  const _SettingsButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Alert display settings',
      child: Material(
        color: Flexoki.base100,
        elevation: 9,
        shadowColor: Colors.black87,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Flexoki.base300),
        ),
        child: InkWell(
          key: const ValueKey('landscape-settings-button'),
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: const SizedBox.square(
            dimension: mapUtilityButtonDimension,
            child: Icon(
              Icons.settings_outlined,
              size: 28,
              color: Flexoki.paper,
            ),
          ),
        ),
      ),
    );
  }
}

class RadarModePanel extends StatefulWidget {
  const RadarModePanel({required this.radar, this.scrollController, super.key});

  final RadarController radar;
  final ScrollController? scrollController;

  @override
  State<RadarModePanel> createState() => _RadarModePanelState();
}

class _RadarModePanelState extends State<RadarModePanel> {
  @override
  Widget build(BuildContext context) {
    final radar = widget.radar;
    final station = radar.selectedStation;
    final velocityEnabled = station == null || station.supportsVelocity;
    final compact = widget.scrollController != null;
    final children = <Widget>[
      Text('Live radar', style: Theme.of(context).textTheme.headlineSmall),
      const SizedBox(height: 4),
      Text(
        compact
            ? 'Newest scan only · no forecast or timeline.'
            : 'Only the newest available scan is shown. There is no forecast or playback timeline.',
        style: const TextStyle(color: Flexoki.base500),
      ),
      const SizedBox(height: 12),
      _ModeTile(
        tileKey: const ValueKey('mode-nearby'),
        compact: compact,
        selected: radar.mode == RadarMode.aggregate,
        icon: Icons.layers_rounded,
        title: 'Nearby radar',
        subtitle: 'Combined view from nearby stations',
        onTap: () {
          radar.selectMode(RadarMode.aggregate);
          Navigator.pop(context);
        },
      ),
      _ModeTile(
        tileKey: const ValueKey('mode-station-reflectivity'),
        compact: compact,
        selected: radar.mode == RadarMode.stationReflectivity,
        icon: Icons.radar_rounded,
        title: 'Station reflectivity',
        subtitle: station == null
            ? 'Choose this, then tap a station on the map'
            : '${station.name} (${station.id})',
        onTap: () {
          radar.selectMode(RadarMode.stationReflectivity);
          Navigator.pop(context);
        },
      ),
      _ModeTile(
        tileKey: const ValueKey('mode-station-velocity'),
        compact: compact,
        selected: radar.mode == RadarMode.stationVelocity,
        enabled: velocityEnabled,
        icon: Icons.air_rounded,
        title: 'Station velocity',
        subtitle: station == null
            ? 'Choose this, then tap a velocity-capable station'
            : velocityEnabled
            ? 'Radial wind velocity from ${station.id}'
            : '${station.id} does not currently expose velocity',
        onTap: () {
          radar.selectMode(RadarMode.stationVelocity);
          Navigator.pop(context);
        },
      ),
      if (radar.mode.requiresStation && station != null) ...[
        const Divider(height: 28),
        const Text(
          'ELEVATION',
          style: TextStyle(
            color: Flexoki.base500,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        _ElevationPicker(radar: radar),
      ],
    ];
    if (widget.scrollController != null) {
      return ListView(
        key: const ValueKey('radar-mode-panel'),
        controller: widget.scrollController,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        children: children,
      );
    }
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          key: const ValueKey('radar-mode-panel'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tileKey,
    this.compact = false,
    this.enabled = true,
  });

  final bool selected;
  final bool enabled;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Key? tileKey;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: tileKey,
      enabled: enabled,
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      dense: compact,
      visualDensity: compact
          ? const VisualDensity(horizontal: 0, vertical: -2)
          : null,
      leading: Icon(icon, color: selected ? Flexoki.cyan : Flexoki.base500),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle, maxLines: compact ? 1 : null),
      trailing: selected
          ? const Icon(Icons.check_circle_rounded, color: Flexoki.cyan)
          : null,
      onTap: onTap,
    );
  }
}

class _ElevationPicker extends StatelessWidget {
  const _ElevationPicker({required this.radar, this.compact = false});

  final RadarController radar;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final elevations = radar.elevations;
    if (elevations.isEmpty) {
      return const Text(
        'Elevation: latest sweep (tilt selection unavailable)',
        style: TextStyle(color: Flexoki.base500, fontSize: 12),
      );
    }
    if (elevations.length == 1) {
      return Text(
        'Elevation: ${elevations.first}° (only available tilt)',
        style: const TextStyle(color: Flexoki.base500, fontSize: 12),
      );
    }
    if (compact) {
      return Text(
        'Elevation: ${radar.selectedElevation}° · tap to change',
        style: const TextStyle(color: Flexoki.base500, fontSize: 12),
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: elevations
          .map(
            (elevation) => ChoiceChip(
              label: Text('$elevation°'),
              selected: elevation == radar.selectedElevation,
              onSelected: (_) => radar.selectElevation(elevation),
            ),
          )
          .toList(),
    );
  }
}

class _AlertsAtLocationSheet extends StatelessWidget {
  const _AlertsAtLocationSheet({
    required this.alerts,
    required this.scrollController,
    required this.onSelect,
  });

  final List<WeatherAlert> alerts;
  final ScrollController scrollController;
  final ValueChanged<WeatherAlert> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 28),
      itemCount: alerts.length + 1,
      separatorBuilder: (context, index) => const SizedBox(height: 9),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Alerts at this location',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '${alerts.length} overlapping alerts · choose one for details',
                  style: const TextStyle(color: Flexoki.base500),
                ),
              ],
            ),
          );
        }
        final alert = alerts[index - 1];
        return _AlertListRow(alert: alert, onTap: () => onSelect(alert));
      },
    );
  }
}

class _AlertsListSheet extends StatelessWidget {
  const _AlertsListSheet({
    required this.alerts,
    required this.scrollController,
    required this.onSelect,
  });

  final List<WeatherAlert> alerts;
  final ScrollController scrollController;
  final ValueChanged<WeatherAlert> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 28),
      itemCount: alerts.length + 1,
      separatorBuilder: (context, index) => const SizedBox(height: 9),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Active weather alerts',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  '${alerts.length} active ${alerts.length == 1 ? 'alert' : 'alerts'} · National Weather Service',
                  style: const TextStyle(color: Flexoki.base500),
                ),
              ],
            ),
          );
        }
        final alert = alerts[index - 1];
        return _AlertListRow(alert: alert, onTap: () => onSelect(alert));
      },
    );
  }
}

class _AlertListRow extends StatelessWidget {
  const _AlertListRow({required this.alert, required this.onTap});

  final WeatherAlert alert;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final mapUnavailable =
        !alert.hasMapGeometry || alert.resolvedZoneCount == 0;
    final mapPartial = !mapUnavailable && alert.radarGeometryPartial;
    return Material(
      color: Flexoki.base100,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Flexoki.base200),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 92),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 5,
                  height: 52,
                  decoration: BoxDecoration(
                    color: _alertColor(alert),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        alert.event,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        alert.headline,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Flexoki.base700,
                          fontSize: 13,
                        ),
                      ),
                      if (mapUnavailable || mapPartial) ...[
                        const SizedBox(height: 8),
                        _MapAreaIndicator(unavailable: mapUnavailable),
                      ],
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 15),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: Flexoki.base500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapAreaIndicator extends StatelessWidget {
  const _MapAreaIndicator({required this.unavailable});

  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final color = unavailable ? Flexoki.orange : Flexoki.yellow;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        unavailable ? 'MAP AREA UNAVAILABLE' : 'MAP AREA PARTIAL',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.45,
        ),
      ),
    );
  }
}

class _AlertSheet extends StatelessWidget {
  const _AlertSheet({required this.alert, required this.scrollController});

  final WeatherAlert alert;
  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(22, 4, 22, 30),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Flexoki.yellow),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                alert.event,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(alert.headline, style: Theme.of(context).textTheme.titleMedium),
        if (alert.radarGeometryPartial) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Flexoki.yellow.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Flexoki.yellow.withValues(alpha: 0.45)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 19,
                  color: Flexoki.yellow,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    _partialGeometryNotice(alert),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _AlertFact(label: 'Severity', value: alert.severity),
            _AlertFact(label: 'Urgency', value: alert.urgency),
            _AlertFact(label: 'Certainty', value: alert.certainty),
          ],
        ),
        if (alert.effective != null || alert.expires != null) ...[
          const SizedBox(height: 16),
          Text(
            [
              if (alert.effective != null)
                'Effective ${_formatDate(alert.effective!)}',
              if (alert.expires != null)
                'Expires ${_formatDate(alert.expires!)}',
            ].join('  ·  '),
            style: const TextStyle(color: Flexoki.base500),
          ),
        ],
        if (alert.description.isNotEmpty) ...[
          const Divider(height: 30),
          Text(alert.description),
        ],
        if (alert.instruction.isNotEmpty) ...[
          const SizedBox(height: 22),
          const Text(
            'WHAT TO DO',
            style: TextStyle(
              color: Flexoki.yellow,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Text(alert.instruction),
        ],
        const SizedBox(height: 24),
        const Text(
          'Source: National Weather Service',
          style: TextStyle(color: Flexoki.base500, fontSize: 12),
        ),
      ],
    );
  }
}

class _AlertFact extends StatelessWidget {
  const _AlertFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Flexoki.base100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Flexoki.base200),
      ),
      child: Text('$label: $value', style: const TextStyle(fontSize: 12)),
    );
  }
}

String _relativeAge(DateTime time) {
  final age = DateTime.now().difference(time);
  if (age.isNegative || age.inSeconds < 10) return 'just now';
  if (age.inMinutes < 1) return '${age.inSeconds}s ago';
  if (age.inHours < 1) return '${age.inMinutes}m ago';
  return '${age.inHours}h ago';
}

String _alertStatusMessage(RadarController radar) {
  if (radar.isLoadingAlerts) return 'Refreshing weather alerts…';
  if (radar.alertsError != null) {
    return radar.alerts.isEmpty
        ? 'Weather alerts unavailable — tap to retry'
        : 'Couldn’t update weather alerts — tap to retry';
  }
  final updatedAt = radar.alertsUpdatedAt;
  if (updatedAt == null) return 'Cached weather alerts — tap to retry';
  return 'Cached weather alerts · ${_relativeAge(updatedAt.toLocal())} — tap to retry';
}

String _formatDate(DateTime time) {
  final hour = time.hour == 0
      ? 12
      : (time.hour > 12 ? time.hour - 12 : time.hour);
  final minute = time.minute.toString().padLeft(2, '0');
  final period = time.hour >= 12 ? 'PM' : 'AM';
  return '${time.month}/${time.day} $hour:$minute $period';
}

String _partialGeometryNotice(WeatherAlert alert) {
  final requested = alert.requestedZoneCount;
  final resolved = alert.resolvedZoneCount;
  final unavailable = !alert.hasMapGeometry || resolved == 0;
  final detail = requested != null && resolved != null
      ? ' ($resolved of $requested zones mapped)'
      : '';
  final status = unavailable ? 'unavailable' : 'partial';
  return 'Map area is $status$detail; alert text remains authoritative.';
}

Color _alertColor(WeatherAlert alert) {
  final value = int.tryParse(alert.colorHex.substring(1), radix: 16);
  return Color(0xFF000000 | (value ?? 0xD0A215));
}
