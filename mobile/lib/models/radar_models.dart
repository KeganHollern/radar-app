import 'dart:convert';

enum RadarMode {
  aggregate(apiValue: 'aggregate', label: 'Nearby', shortLabel: 'Nearby radar'),
  stationReflectivity(
    apiValue: 'reflectivity',
    label: 'Station',
    shortLabel: 'Station reflectivity',
  ),
  stationVelocity(
    apiValue: 'velocity',
    label: 'Velocity',
    shortLabel: 'Station velocity',
  );

  const RadarMode({
    required this.apiValue,
    required this.label,
    required this.shortLabel,
  });

  final String apiValue;
  final String label;
  final String shortLabel;

  bool get requiresStation => this != RadarMode.aggregate;
}

final class RadarStation {
  const RadarStation({
    required this.id,
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.reflectivityElevations,
    required this.velocityElevations,
    required this.supportsReflectivity,
    required this.supportsVelocity,
  });

  final String id;
  final String name;
  final double latitude;
  final double longitude;
  final List<String> reflectivityElevations;
  final List<String> velocityElevations;
  final bool supportsReflectivity;
  final bool supportsVelocity;

  factory RadarStation.fromJson(Map<String, dynamic> json) {
    final properties = _asMap(json['properties']);
    final source = properties.isEmpty ? json : properties;
    final geometry = _asMap(json['geometry']);
    final coordinates = geometry['coordinates'] is List
        ? geometry['coordinates'] as List
        : const <dynamic>[];

    final commonElevations = _elevationList(
      source['elevations'] ?? source['supported_elevations'],
    );
    final reflectivityElevations = _elevationList(
      source['reflectivity_elevations'] ?? commonElevations,
    );
    final velocityElevations = _elevationList(
      source['velocity_elevations'] ?? commonElevations,
    );

    final products = _stringSet(
      source['products'] ?? source['supported_products'],
    );
    final capabilities = _asMap(source['capabilities']);
    final velocity =
        _boolOrNull(source['supports_velocity']) ??
        _boolOrNull(capabilities['velocity']) ??
        products.any(
          (value) =>
              value.contains('velocity') || value.toUpperCase() == 'SR_BVEL',
        );
    final reflectivity =
        _boolOrNull(source['supports_reflectivity']) ??
        _boolOrNull(capabilities['reflectivity']) ??
        products.isEmpty ||
            products.any(
              (value) =>
                  value.contains('reflect') || value.toUpperCase() == 'SR_BREF',
            );

    return RadarStation(
      id: _firstString([
        json['id'],
        source['id'],
        source['site'],
        source['code'],
      ]),
      name: _firstString([
        source['name'],
        source['site_name'],
        source['city'],
        source['id'],
      ]),
      longitude: _firstDouble([
        source['longitude'],
        source['lon'],
        coordinates.isNotEmpty ? coordinates[0] : null,
      ]),
      latitude: _firstDouble([
        source['latitude'],
        source['lat'],
        coordinates.length > 1 ? coordinates[1] : null,
      ]),
      reflectivityElevations: reflectivityElevations,
      velocityElevations: velocityElevations,
      supportsReflectivity: reflectivity,
      supportsVelocity: velocity,
    );
  }

  Map<String, dynamic> toGeoJsonFeature() => {
    'type': 'Feature',
    'id': id,
    'properties': {'id': id, 'name': name, 'velocity': supportsVelocity},
    'geometry': {
      'type': 'Point',
      'coordinates': [longitude, latitude],
    },
  };

  List<String> elevationsFor(RadarMode mode) => switch (mode) {
    RadarMode.stationVelocity => velocityElevations,
    RadarMode.stationReflectivity => reflectivityElevations,
    RadarMode.aggregate => const [],
  };
}

final class RadarSnapshot {
  const RadarSnapshot({
    required this.observedAt,
    required this.version,
    required this.tileTemplate,
    this.stale = false,
    this.ageSeconds = 0,
  });

  final DateTime observedAt;
  final String version;
  final String? tileTemplate;
  final bool stale;
  final int ageSeconds;

  factory RadarSnapshot.fromJson(Map<String, dynamic> json) {
    final data = _asMap(json['data']);
    final source = data.isEmpty ? json : data;
    final rawTime = _firstString([
      source['observed_at'],
      source['observedAt'],
      source['timestamp'],
      source['updated_at'],
      source['updatedAt'],
      source['generated_at'],
      source['generatedAt'],
      source['checkedAt'],
    ]);
    final observedAt =
        DateTime.tryParse(rawTime)?.toUtc() ?? DateTime.now().toUtc();
    final version = _firstString([
      source['version'],
      source['scan_id'],
      source['etag'],
      rawTime,
    ]);
    final tileTemplate = _nullableString(
      source['tile_url'] ??
          source['tile_template'] ??
          source['tileTemplate'] ??
          source['tiles'],
    );
    return RadarSnapshot(
      observedAt: observedAt,
      version: version.isEmpty
          ? observedAt.millisecondsSinceEpoch.toString()
          : version,
      tileTemplate: tileTemplate,
      stale: source['stale'] == true,
      ageSeconds: _firstInt([source['ageSeconds'], source['age_seconds']]),
    );
  }
}

final class WeatherAlert {
  const WeatherAlert({
    required this.id,
    required this.event,
    required this.headline,
    required this.description,
    required this.instruction,
    required this.severity,
    required this.urgency,
    required this.certainty,
    required this.effective,
    required this.expires,
    required this.feature,
    this.radarGeometryPartial = false,
    this.requestedZoneCount,
    this.resolvedZoneCount,
  });

  final String id;
  final String event;
  final String headline;
  final String description;
  final String instruction;
  final String severity;
  final String urgency;
  final String certainty;
  final DateTime? effective;
  final DateTime? expires;
  final Map<String, dynamic> feature;
  final bool radarGeometryPartial;
  final int? requestedZoneCount;
  final int? resolvedZoneCount;

  String get colorHex {
    final serverColor = _nullableString(
      _asMap(feature['properties'])['radarColor'],
    );
    if (serverColor != null &&
        RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(serverColor)) {
      return serverColor.toUpperCase();
    }
    final normalized = event.toLowerCase();
    if (normalized.contains('tornado')) return '#D14D41';
    if (normalized.contains('severe thunderstorm')) return '#DA702C';
    if (normalized.contains('flash flood')) return '#4385BE';
    if (normalized.contains('flood')) return '#3AA99F';
    if (normalized.contains('winter') || normalized.contains('snow')) {
      return '#8B7EC8';
    }
    if (normalized.contains('heat') || normalized.contains('fire')) {
      return '#CE5D97';
    }
    return '#D0A215';
  }

  bool get hasMapGeometry {
    final geometry = _asMap(feature['geometry']);
    return geometry.isNotEmpty && geometry['coordinates'] != null;
  }

  Map<String, dynamic> toGeoJsonFeature() {
    return {
      'type': 'Feature',
      'id': id,
      // Keep verbose alert text in the Dart model for the details sheet, but
      // do not duplicate it into MapLibre's Java/native feature collection.
      'properties': {'id': id, 'alert_color': colorHex, 'event': event},
      'geometry': feature['geometry'],
    };
  }

  factory WeatherAlert.fromFeature(Map<String, dynamic> feature) {
    final properties = _asMap(feature['properties']);
    return WeatherAlert(
      id: _firstString([
        feature['id'],
        properties['id'],
        properties['@id'],
        properties['headline'],
      ]),
      event: _firstString([properties['event'], 'Weather alert']),
      headline: _firstString([
        properties['headline'],
        properties['event'],
        'Weather alert',
      ]),
      description: _firstString([
        properties['description'],
        properties['message'],
      ]),
      instruction: _firstString([properties['instruction']]),
      severity: _firstString([properties['severity'], 'Unknown']),
      urgency: _firstString([properties['urgency'], 'Unknown']),
      certainty: _firstString([properties['certainty'], 'Unknown']),
      effective: _dateOrNull(properties['effective'] ?? properties['onset']),
      expires: _dateOrNull(properties['expires'] ?? properties['ends']),
      feature: Map<String, dynamic>.from(feature),
      radarGeometryPartial: properties['radarGeometryPartial'] == true,
      requestedZoneCount: _firstNullableInt([
        properties['radarGeometryZonesRequested'],
        properties['radarGeometryRequestedZoneCount'],
        properties['requestedZoneCount'],
        properties['requestedZones'],
      ]),
      resolvedZoneCount: _firstNullableInt([
        properties['radarGeometryZonesResolved'],
        properties['radarGeometryZoneCount'],
        properties['radarGeometryResolvedZoneCount'],
        properties['resolvedZoneCount'],
        properties['resolvedZones'],
      ]),
    );
  }
}

Map<String, dynamic> decodeObject(String body) {
  final decoded = jsonDecode(body);
  if (decoded is! Map) throw const FormatException('Expected a JSON object');
  return Map<String, dynamic>.from(decoded);
}

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

String _firstString(List<dynamic> values) {
  for (final value in values) {
    final string = _nullableString(value);
    if (string != null && string.isNotEmpty) return string;
  }
  return '';
}

String? _nullableString(dynamic value) {
  if (value == null) return null;
  if (value is List && value.isNotEmpty) return _nullableString(value.first);
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

double _firstDouble(List<dynamic> values) {
  for (final value in values) {
    if (value is num) return value.toDouble();
    final parsed = double.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return 0;
}

int _firstInt(List<dynamic> values) {
  for (final value in values) {
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return 0;
}

int? _firstNullableInt(List<dynamic> values) {
  for (final value in values) {
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value?.toString() ?? '');
    if (parsed != null) return parsed;
  }
  return null;
}

String _formatElevation(dynamic value) {
  final asString = value.toString().trim().replaceAll('°', '');
  final numeric = double.tryParse(asString);
  if (numeric == null) return asString;
  return numeric == numeric.roundToDouble()
      ? numeric.toStringAsFixed(0)
      : numeric.toString();
}

List<String> _elevationList(dynamic value) {
  if (value is! List) return const [];
  return value
      .map((item) => _formatElevation(item))
      .where((item) => item.isNotEmpty)
      .toSet()
      .toList();
}

Set<String> _stringSet(dynamic value) {
  if (value is! List) return const {};
  return value.map((item) => item.toString()).toSet();
}

bool? _boolOrNull(dynamic value) {
  if (value is bool) return value;
  if (value is Map) return _boolOrNull(value['available'] ?? value['enabled']);
  if (value == null) return null;
  if (value.toString().toLowerCase() == 'true') return true;
  if (value.toString().toLowerCase() == 'false') return false;
  return null;
}

DateTime? _dateOrNull(dynamic value) =>
    value == null ? null : DateTime.tryParse(value.toString())?.toLocal();
