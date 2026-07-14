import 'radar_models.dart';

/// Resolves the visible alerts returned by a MapLibre point query.
///
/// MapLibre may return the same feature through multiple rendered layers, so
/// IDs are de-duplicated while preserving render order. [fallbackId] keeps a
/// normal single-feature tap working if a platform query omits feature data.
List<WeatherAlert> resolveAlertsAtTap({
  required Iterable<dynamic> renderedFeatures,
  required Iterable<WeatherAlert> visibleAlerts,
  String? fallbackId,
}) {
  final ids = <String>{};
  for (final feature in renderedFeatures) {
    final id = _featureId(feature);
    if (id != null && id.isNotEmpty) ids.add(id);
  }
  if (fallbackId != null && fallbackId.isNotEmpty) ids.add(fallbackId);

  final byId = <String, WeatherAlert>{
    for (final alert in visibleAlerts) alert.id: alert,
  };
  final resolved = <WeatherAlert>[];
  for (final id in ids) {
    final alert = byId[id];
    if (alert != null) resolved.add(alert);
  }
  return resolved;
}

String? _featureId(dynamic feature) {
  if (feature is! Map) return null;
  final direct = feature['id'];
  if (direct != null) return direct.toString();
  final properties = feature['properties'];
  if (properties is! Map) return null;
  return properties['id']?.toString();
}
