import 'dart:math';

import '../models/radar_models.dart';

/// Selects one radar for the entire Nearby viewport.
///
/// Distance is measured on a sphere and normalizes longitude deltas across the
/// antimeridian. Ties are resolved by station ID so a reordered catalog cannot
/// make an otherwise unchanged camera choose a different source.
RadarStation? nearestNearbyReflectivityStation({
  required Iterable<RadarStation> stations,
  required double latitude,
  required double longitude,
  RadarStation? currentStation,
  double switchHysteresisMeters = 20000,
}) {
  if (!latitude.isFinite ||
      !longitude.isFinite ||
      latitude < -90 ||
      latitude > 90) {
    return null;
  }

  final latitudeRadians = _radians(latitude);
  RadarStation? nearest;
  var nearestDistance = double.infinity;
  RadarStation? current;
  var currentDistance = double.infinity;

  for (final station in stations) {
    if (!station.supportsReflectivity ||
        !_isWSR88D(station.id) ||
        !station.latitude.isFinite ||
        !station.longitude.isFinite ||
        station.latitude < -90 ||
        station.latitude > 90) {
      continue;
    }

    final stationLatitude = _radians(station.latitude);
    final latitudeDelta = stationLatitude - latitudeRadians;
    final rawLongitudeDelta = _radians(station.longitude - longitude);
    final longitudeDelta = atan2(
      sin(rawLongitudeDelta),
      cos(rawLongitudeDelta),
    );
    final latitudeHalfSin = sin(latitudeDelta / 2);
    final longitudeHalfSin = sin(longitudeDelta / 2);
    final haversine =
        latitudeHalfSin * latitudeHalfSin +
        cos(latitudeRadians) *
            cos(stationLatitude) *
            longitudeHalfSin *
            longitudeHalfSin;
    final distance =
        2 *
        atan2(
          sqrt(haversine.clamp(0.0, 1.0)),
          sqrt((1 - haversine).clamp(0.0, 1.0)),
        ) *
        _earthRadiusMeters;

    if (station.id == currentStation?.id) {
      current = station;
      currentDistance = distance;
    }

    if (distance < nearestDistance ||
        (distance == nearestDistance &&
            (nearest == null || station.id.compareTo(nearest.id) < 0))) {
      nearest = station;
      nearestDistance = distance;
    }
  }

  if (current != null &&
      nearest?.id != current.id &&
      nearestDistance + max(0, switchHysteresisMeters) >= currentDistance) {
    return current;
  }
  return nearest;
}

const _earthRadiusMeters = 6371008.8;

double _radians(double degrees) => degrees * pi / 180;

bool _isWSR88D(String id) {
  final normalized = id.trim().toUpperCase();
  return normalized == 'TJUA' ||
      (normalized.length == 4 &&
          (normalized.startsWith('K') || normalized.startsWith('P')));
}
