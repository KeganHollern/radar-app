import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../config/app_config.dart';
import '../controllers/radar_controller.dart';
import '../models/radar_models.dart';
import '../services/location_service.dart';
import '../theme/flexoki_theme.dart';
import '../widgets/radar_legend.dart';

class RadarMapScreen extends StatefulWidget {
  const RadarMapScreen({super.key});

  @override
  State<RadarMapScreen> createState() => _RadarMapScreenState();
}

class _RadarMapScreenState extends State<RadarMapScreen>
    with WidgetsBindingObserver {
  static const _radarSource = 'live-radar-source';
  static const _radarLayer = 'live-radar-layer';
  static const _alertsSource = 'weather-alerts-source';
  static const _alertsFillLayer = 'weather-alerts-fill';
  static const _alertsLineLayer = 'weather-alerts-outline';
  static const _stationsSource = 'radar-stations-source';
  static const _stationsLayer = 'radar-stations-layer';

  late final RadarController _radar;
  final LocationService _location = LocationService();
  MapLibreMapController? _map;
  LocationAccess _locationAccess = LocationAccess.checking;
  bool _styleLoaded = false;
  bool _pinLocation = false;
  bool _restoreTracking = false;
  bool _baseSourcesInstalled = false;
  bool _radarInstalled = false;
  String _renderedRadarKey = '';
  int _renderedStationRevision = -1;
  int _renderedAlertRevision = -1;
  bool _styleSyncRunning = false;
  bool _styleSyncPending = false;
  bool _forceStyleSync = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _radar = RadarController()..addListener(_onRadarChanged);
    unawaited(_radar.initialize());
    unawaited(_requestLocation());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_radar.resume());
    unawaited(_requestLocation());
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
  }

  void _onStyleLoaded() {
    _styleLoaded = true;
    _baseSourcesInstalled = false;
    _radarInstalled = false;
    _renderedRadarKey = '';
    _renderedStationRevision = -1;
    _renderedAlertRevision = -1;
    _queueStyleSync(force: true);
    if (_pinLocation && _locationAccess == LocationAccess.granted) {
      unawaited(_setTrackingMode(MyLocationTrackingMode.tracking));
    }
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

    if (!_baseSourcesInstalled) {
      await map.addGeoJsonSource(
        _alertsSource,
        _emptyFeatureCollection,
        promoteId: 'id',
      );
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
      await map.addGeoJsonSource(
        _stationsSource,
        _emptyFeatureCollection,
        promoteId: 'id',
      );
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
      _baseSourcesInstalled = true;
    }

    final stationRevision = _radar.stationRevision;
    if (stationRevision != _renderedStationRevision) {
      final stationGeoJson = _radar.stationGeoJson;
      await map.setGeoJsonSource(_stationsSource, stationGeoJson);
      _renderedStationRevision = stationRevision;
    }
    final alertRevision = _radar.alertRevision;
    if (alertRevision != _renderedAlertRevision) {
      final alertGeoJson = _radar.alertGeoJson;
      await map.setGeoJsonSource(_alertsSource, alertGeoJson);
      _renderedAlertRevision = alertRevision;
    }

    final nextKey = _radar.radarLayerKey;
    final tileTemplate = _radar.activeTileTemplate;
    if (!force && nextKey == _renderedRadarKey) return;
    if (_radarInstalled) {
      await map.removeLayer(_radarLayer);
      await map.removeSource(_radarSource);
      _radarInstalled = false;
    }
    _renderedRadarKey = nextKey;
    if (nextKey.isEmpty || tileTemplate == null) return;

    final layerIds = await map.getLayerIds();
    String? belowLayer;
    for (final rawId in layerIds.reversed) {
      final id = rawId.toString();
      if (id == _alertsFillLayer ||
          id == _alertsLineLayer ||
          id == _stationsLayer) {
        continue;
      }
      if (id.toLowerCase().contains('label') ||
          id.toLowerCase().contains('place')) {
        belowLayer = id;
        break;
      }
    }
    await map.addSource(
      _radarSource,
      RasterSourceProperties(
        tiles: [tileTemplate],
        tileSize: 256,
        minzoom: 0,
        maxzoom: 12,
        attribution: 'Weather data: NOAA/NWS',
      ),
    );
    await map.addRasterLayer(
      _radarSource,
      _radarLayer,
      const RasterLayerProperties(
        rasterOpacity: 0.62,
        rasterFadeDuration: 0,
        rasterResampling: 'linear',
      ),
      belowLayerId: belowLayer,
    );
    _radarInstalled = true;
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
      final alert = _radar.alertById(id);
      if (alert != null) _showAlert(alert);
    }
  }

  Future<void> _togglePin() async {
    if (_locationAccess != LocationAccess.granted) {
      await _requestLocation();
      if (_locationAccess != LocationAccess.granted) return;
    }
    final next = !_pinLocation;
    setState(() => _pinLocation = next);
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
    if (!_pinLocation || !_restoreTracking) return;
    _restoreTracking = false;
    unawaited(_setTrackingMode(MyLocationTrackingMode.tracking));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: MapLibreMap(
              styleString: AppConfig.mapStyleUrl,
              initialCameraPosition: const CameraPosition(
                target: LatLng(39.5, -98.35),
                zoom: 3.25,
              ),
              minMaxZoomPreference: const MinMaxZoomPreference(2.5, 15),
              onMapCreated: _onMapCreated,
              onStyleLoadedCallback: _onStyleLoaded,
              onCameraTrackingDismissed: _onTrackingDismissed,
              onCameraIdle: _onCameraIdle,
              myLocationEnabled: _locationAccess == LocationAccess.granted,
              myLocationTrackingMode: MyLocationTrackingMode.none,
              myLocationRenderMode: MyLocationRenderMode.normal,
              trackCameraPosition: true,
              compassEnabled: true,
              rotateGesturesEnabled: false,
              tiltGesturesEnabled: false,
              logoEnabled: false,
              attributionButtonPosition: AttributionButtonPosition.bottomRight,
              attributionButtonMargins: const Point(16, 196),
              foregroundLoadColor: Flexoki.black,
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LiveStatusCard(
                  radar: _radar,
                  onRefresh: _radar.refreshAll,
                  onOpenAlerts: _showAlerts,
                ),
                if (_radar.radarError != null) ...[
                  const SizedBox(height: 8),
                  _StatusBanner(
                    icon: Icons.cloud_off_rounded,
                    message: _radar.radarError!,
                    onTap: _radar.refreshRadar,
                  ),
                ],
                if (_radar.alertsStale || _radar.alertsError != null) ...[
                  const SizedBox(height: 8),
                  _StatusBanner(
                    icon: Icons.warning_amber_rounded,
                    message:
                        'Weather alerts may be out of date — tap to refresh',
                    onTap: _radar.refreshAlerts,
                  ),
                ],
                if (_locationAccess != LocationAccess.granted &&
                    _locationAccess != LocationAccess.checking) ...[
                  const SizedBox(height: 8),
                  _StatusBanner(
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
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          RadarLegend(mode: _radar.mode),
                          const SizedBox(height: 8),
                          _RadarControls(
                            radar: _radar,
                            onOpenModes: _showRadarModes,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    _PinButton(pinned: _pinLocation, onPressed: _togglePin),
                  ],
                ),
              ],
            ),
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

  void _showRadarModes() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => _ModeSheet(radar: _radar),
    );
  }

  void _showAlerts() {
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
  });

  final RadarController radar;
  final Future<void> Function() onRefresh;
  final VoidCallback onOpenAlerts;

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
    return Card(
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
              tooltip: 'Refresh now',
              onPressed: radar.isLoadingRadar ? null : onRefresh,
              icon: radar.isLoadingRadar
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
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: pinned ? Flexoki.cyan : Flexoki.base300),
        ),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox.square(
            dimension: 64,
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

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.icon,
    required this.message,
    required this.onTap,
  });

  final IconData icon;
  final String message;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Flexoki.base100.withValues(alpha: 0.96),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: Flexoki.base300),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(
            children: [
              Icon(icon, size: 19, color: Flexoki.yellow),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Flexoki.base500),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeSheet extends StatefulWidget {
  const _ModeSheet({required this.radar});

  final RadarController radar;

  @override
  State<_ModeSheet> createState() => _ModeSheetState();
}

class _ModeSheetState extends State<_ModeSheet> {
  @override
  Widget build(BuildContext context) {
    final radar = widget.radar;
    final station = radar.selectedStation;
    final velocityEnabled = station == null || station.supportsVelocity;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Live radar',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 4),
            const Text(
              'Only the newest available scan is shown. There is no forecast or playback timeline.',
              style: TextStyle(color: Flexoki.base500),
            ),
            const SizedBox(height: 12),
            _ModeTile(
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
          ],
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
    this.enabled = true,
  });

  final bool selected;
  final bool enabled;
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      enabled: enabled,
      selected: selected,
      contentPadding: const EdgeInsets.symmetric(horizontal: 6),
      leading: Icon(icon, color: selected ? Flexoki.cyan : Flexoki.base500),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
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
