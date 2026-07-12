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

  static const Duration radarRefreshInterval = Duration(seconds: 15);
  static const Duration alertsRefreshInterval = Duration(seconds: 30);
  static const Duration stationsRefreshInterval = Duration(hours: 6);
}
