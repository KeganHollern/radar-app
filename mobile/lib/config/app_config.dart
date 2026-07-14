import '../models/data_attribution.dart';

final class AppConfig {
  AppConfig._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://radar.lystic.dev',
  );

  static const String mapStyleUrl = String.fromEnvironment(
    'MAP_STYLE_URL',
    defaultValue: 'https://tiles.openfreemap.org/styles/dark',
  );

  /// Compact credit that remains visible over the map from first render.
  static const String mapAttributionCompact = String.fromEnvironment(
    'MAP_ATTRIBUTION_COMPACT',
    defaultValue: '© OpenStreetMap',
  );

  static const String _mapProviderAttribution = String.fromEnvironment(
    'MAP_PROVIDER_ATTRIBUTION',
    defaultValue: 'OpenFreeMap',
  );
  static const String _mapProviderAttributionUrl = String.fromEnvironment(
    'MAP_PROVIDER_ATTRIBUTION_URL',
    defaultValue: 'https://openfreemap.org/',
  );
  static const String _mapSchemaAttribution = String.fromEnvironment(
    'MAP_SCHEMA_ATTRIBUTION',
    defaultValue: '© OpenMapTiles',
  );
  static const String _mapSchemaAttributionUrl = String.fromEnvironment(
    'MAP_SCHEMA_ATTRIBUTION_URL',
    defaultValue: 'https://openmaptiles.org/',
  );
  static const String _mapDataAttribution = String.fromEnvironment(
    'MAP_DATA_ATTRIBUTION',
    defaultValue: '© OpenStreetMap contributors',
  );
  static const String _mapDataAttributionUrl = String.fromEnvironment(
    'MAP_DATA_ATTRIBUTION_URL',
    defaultValue: 'https://www.openstreetmap.org/copyright',
  );

  /// Credits paired with [mapStyleUrl] for this build.
  ///
  /// Releases that override `MAP_STYLE_URL` must override these attribution
  /// defines to match that style's provider, schema, and map-data licenses.
  static List<DataAttribution> get mapAttributions => [
    if (_mapProviderAttribution.trim().isNotEmpty)
      const DataAttribution(
        label: _mapProviderAttribution,
        url: _mapProviderAttributionUrl,
      ),
    if (_mapSchemaAttribution.trim().isNotEmpty)
      const DataAttribution(
        label: _mapSchemaAttribution,
        url: _mapSchemaAttributionUrl,
      ),
    if (_mapDataAttribution.trim().isNotEmpty)
      const DataAttribution(
        label: _mapDataAttribution,
        url: _mapDataAttributionUrl,
      ),
  ];

  static const Duration radarRefreshInterval = Duration(seconds: 15);
  static const Duration alertsRefreshInterval = Duration(seconds: 30);
  static const Duration stationsRefreshInterval = Duration(hours: 6);
}
