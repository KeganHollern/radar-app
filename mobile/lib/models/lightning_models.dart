import 'dart:collection';
import 'dart:math' as math;

enum LightningSourceMode {
  event,
  scan;

  static LightningSourceMode fromJson(dynamic value) =>
      switch (value?.toString().trim().toLowerCase()) {
        'scan' => LightningSourceMode.scan,
        _ => LightningSourceMode.event,
      };
}

enum LightningStreamEvent {
  snapshot,
  lightning,
  reset,
  status,
  unknown;

  static LightningStreamEvent fromSseName(String value) =>
      switch (value.trim().toLowerCase()) {
        'snapshot' => LightningStreamEvent.snapshot,
        'lightning' => LightningStreamEvent.lightning,
        'reset' => LightningStreamEvent.reset,
        'status' => LightningStreamEvent.status,
        _ => LightningStreamEvent.unknown,
      };
}

final class LightningBounds {
  LightningBounds({
    required this.west,
    required this.south,
    required this.east,
    required this.north,
  }) {
    final longitudeSpan = _lightningLongitudeSpan(west, east);
    if (![west, south, east, north].every((value) => value.isFinite) ||
        west < -180 ||
        west > 180 ||
        east < -180 ||
        east > 180 ||
        south < -90 ||
        south > 90 ||
        north < -90 ||
        north > 90 ||
        south >= north ||
        longitudeSpan <= 0 ||
        longitudeSpan > maxLightningLongitudeSpan ||
        north - south > maxLightningLatitudeSpan) {
      throw ArgumentError('Invalid lightning viewport bounds.');
    }
  }

  final double west;
  final double south;
  final double east;
  final double north;

  /// A west value greater than east intentionally describes an
  /// antimeridian-crossing viewport.
  String get queryValue => [
    west,
    south,
    east,
    north,
  ].map((value) => value.toStringAsFixed(4)).join(',');

  @override
  bool operator ==(Object other) =>
      other is LightningBounds &&
      west == other.west &&
      south == other.south &&
      east == other.east &&
      north == other.north;

  @override
  int get hashCode => Object.hash(west, south, east, north);
}

const double maxLightningLongitudeSpan = 160;
const double maxLightningLatitudeSpan = 80;

/// Builds a stable, padded subscription around the visible map while honoring
/// the API's bounded-query contract. When the viewport itself is wider than
/// that contract, [focusLongitude] and [focusLatitude] keep the subscription
/// centered on the part of the world the user is navigating.
LightningBounds lightningSubscriptionBounds({
  required double west,
  required double south,
  required double east,
  required double north,
  double? focusLongitude,
  double? focusLatitude,
}) {
  if (![west, south, east, north].every((value) => value.isFinite) ||
      west < -180 ||
      west > 180 ||
      east < -180 ||
      east > 180 ||
      south < -90 ||
      south > 90 ||
      north < -90 ||
      north > 90 ||
      south >= north) {
    throw ArgumentError('Invalid visible lightning viewport.');
  }

  final visibleLongitudeSpan = _lightningLongitudeSpan(west, east);
  final longitudePadding = math.max(0.75, visibleLongitudeSpan * 0.3);
  final subscriptionLongitudeSpan = math.min(
    maxLightningLongitudeSpan,
    (visibleLongitudeSpan + longitudePadding * 2).ceilToDouble(),
  );
  final longitudeCenter =
      visibleLongitudeSpan >= maxLightningLongitudeSpan &&
          focusLongitude != null &&
          focusLongitude.isFinite
      ? _normalizeLongitude(focusLongitude)
      : _normalizeLongitude(west + visibleLongitudeSpan / 2);
  final subscriptionWest = _normalizeLongitude(
    longitudeCenter - subscriptionLongitudeSpan / 2,
  );
  final subscriptionEast = _normalizeLongitude(
    longitudeCenter + subscriptionLongitudeSpan / 2,
  );

  final visibleLatitudeSpan = north - south;
  final latitudePadding = math.max(0.5, visibleLatitudeSpan * 0.3);
  final subscriptionLatitudeSpan = math.min(
    maxLightningLatitudeSpan,
    (visibleLatitudeSpan + latitudePadding * 2).ceilToDouble(),
  );
  final preferredLatitudeCenter =
      visibleLatitudeSpan >= maxLightningLatitudeSpan &&
          focusLatitude != null &&
          focusLatitude.isFinite
      ? focusLatitude
      : (south + north) / 2;
  final halfLatitudeSpan = subscriptionLatitudeSpan / 2;
  final latitudeCenter = preferredLatitudeCenter.clamp(
    -90 + halfLatitudeSpan,
    90 - halfLatitudeSpan,
  );

  return LightningBounds(
    west: subscriptionWest,
    south: latitudeCenter - halfLatitudeSpan,
    east: subscriptionEast,
    north: latitudeCenter + halfLatitudeSpan,
  );
}

double _lightningLongitudeSpan(double west, double east) {
  if (!west.isFinite || !east.isFinite) return double.nan;
  return west <= east ? east - west : 180 - west + east + 180;
}

double _normalizeLongitude(double longitude) {
  var normalized = longitude;
  while (normalized > 180) {
    normalized -= 360;
  }
  while (normalized < -180) {
    normalized += 360;
  }
  return normalized;
}

final class LightningStrike {
  const LightningStrike({
    required this.id,
    required this.latitude,
    required this.longitude,
    required this.observedAt,
    required this.kind,
    this.receivedAt,
    this.satellite,
  });

  final String id;
  final double latitude;
  final double longitude;
  final DateTime observedAt;
  final DateTime? receivedAt;
  final String kind;
  final String? satellite;

  static LightningStrike? tryFromFeature(Map<String, dynamic> feature) {
    final geometry = _asMap(feature['geometry']);
    if (geometry['type']?.toString().toLowerCase() != 'point') return null;
    final coordinates = geometry['coordinates'];
    if (coordinates is! List || coordinates.length < 2) return null;
    final longitude = _number(coordinates[0]);
    final latitude = _number(coordinates[1]);
    if (longitude == null ||
        latitude == null ||
        !longitude.isFinite ||
        !latitude.isFinite ||
        longitude < -180 ||
        longitude > 180 ||
        latitude < -90 ||
        latitude > 90) {
      return null;
    }

    final properties = _asMap(feature['properties']);
    final observedAt = _date(
      properties['observedAt'] ??
          properties['observed_at'] ??
          properties['timestamp'],
    );
    if (observedAt == null) return null;
    final kind = _string(properties['kind']) ?? 'lightning flash';
    final suppliedId =
        _string(feature['id']) ??
        _string(properties['id']) ??
        _string(properties['strikeId']);
    final id =
        suppliedId ??
        '${observedAt.microsecondsSinceEpoch}:'
            '${latitude.toStringAsFixed(5)}:'
            '${longitude.toStringAsFixed(5)}:$kind';

    return LightningStrike(
      id: id,
      latitude: latitude,
      longitude: longitude,
      observedAt: observedAt,
      receivedAt: _date(properties['receivedAt'] ?? properties['received_at']),
      kind: kind,
      satellite: _string(properties['satellite']),
    );
  }

  Map<String, dynamic> toGeoJsonFeature({required double opacity}) => {
    'type': 'Feature',
    'id': id,
    'properties': {
      'id': id,
      'kind': kind,
      'observed_at': observedAt.toUtc().toIso8601String(),
      'opacity': opacity.clamp(0.0, 1.0),
      'satellite': ?satellite,
    },
    'geometry': {
      'type': 'Point',
      'coordinates': [longitude, latitude],
    },
  };
}

final class LightningSnapshot {
  const LightningSnapshot({
    required this.mode,
    required this.generation,
    required this.strikes,
    this.observedAt,
    this.checkedAt,
    this.stale = false,
    this.available = true,
    this.attribution,
    this.retention = const Duration(seconds: 30),
  });

  final LightningSourceMode mode;
  final String generation;
  final List<LightningStrike> strikes;
  final DateTime? observedAt;
  final DateTime? checkedAt;
  final bool stale;
  final bool available;
  final String? attribution;
  final Duration retention;

  factory LightningSnapshot.fromJson(Map<String, dynamic> json) {
    final nestedSnapshot = _asMap(json['snapshot']);
    final source = nestedSnapshot.isEmpty ? json : nestedSnapshot;
    final data = _asMap(source['data']);
    final collection = data.isEmpty ? source : data;
    final rawFeatures = switch (collection['features']) {
      final List<dynamic> features => features,
      _ => switch (source['strikes']) {
        final List<dynamic> strikes => strikes,
        _ => const <dynamic>[],
      },
    };
    final strikes = <LightningStrike>[];
    final ids = <String>{};
    for (final candidate in rawFeatures) {
      if (candidate is! Map) continue;
      final strike = LightningStrike.tryFromFeature(
        Map<String, dynamic>.from(candidate),
      );
      if (strike != null && ids.add(strike.id)) strikes.add(strike);
    }
    final retentionMs = _integer(
      source['retentionMs'] ?? source['retention_ms'],
    );
    return LightningSnapshot(
      mode: LightningSourceMode.fromJson(source['mode']),
      generation: _string(source['generation']) ?? '',
      strikes: List.unmodifiable(strikes),
      observedAt: _date(source['observedAt'] ?? source['observed_at']),
      checkedAt: _date(source['checkedAt'] ?? source['checked_at']),
      stale: source['stale'] == true,
      available: source['available'] != false,
      attribution: _attribution(source['attribution']),
      retention: retentionMs == null || retentionMs <= 0
          ? const Duration(seconds: 30)
          : Duration(milliseconds: retentionMs.clamp(1000, 3600000)),
    );
  }
}

final class LightningUpdate {
  const LightningUpdate({required this.event, required this.snapshot, this.id});

  final LightningStreamEvent event;
  final LightningSnapshot? snapshot;
  final String? id;
}

Map<String, dynamic> lightningFeatureCollection(
  Iterable<Map<String, dynamic>> features,
) => UnmodifiableMapView({
  'type': 'FeatureCollection',
  'features': List<Map<String, dynamic>>.unmodifiable(features),
});

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

String? _string(dynamic value) {
  if (value == null) return null;
  final result = value.toString().trim();
  return result.isEmpty ? null : result;
}

double? _number(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}

int? _integer(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

DateTime? _date(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final integer = value.toInt();
    final milliseconds = integer.abs() < 100000000000
        ? integer * 1000
        : integer;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
  }
  return DateTime.tryParse(value.toString())?.toUtc();
}

String? _attribution(dynamic value) {
  if (value is String) return _string(value);
  if (value is Map) {
    return _string(value['label'] ?? value['name'] ?? value['text']);
  }
  if (value is List) {
    final labels = value.map(_attribution).whereType<String>().toList();
    return labels.isEmpty ? null : labels.join(', ');
  }
  return null;
}
