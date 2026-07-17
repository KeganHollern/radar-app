import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:radar_mobile/services/native_startup_location_source.dart';

void main() {
  final now = DateTime.utc(2026, 7, 17, 15);

  test('returns a valid authorized operating-system cache entry', () async {
    final source = GeolocatorNativeStartupLocationSource(
      checkPermission: () async => LocationPermission.whileInUse,
      getLastKnownPosition: () async =>
          _position(timestamp: now.subtract(const Duration(minutes: 2))),
      clock: () => now,
    );

    final location = await source.load();

    expect(location, isNotNull);
    expect(location!.position.latitude, 30.2672);
    expect(location.position.longitude, -97.7431);
    expect(location.observedAt, now.subtract(const Duration(minutes: 2)));
  });

  test(
    'checks permission without reading location when not authorized',
    () async {
      var readLastKnownPosition = false;
      final source = GeolocatorNativeStartupLocationSource(
        checkPermission: () async => LocationPermission.denied,
        getLastKnownPosition: () async {
          readLastKnownPosition = true;
          return _position(timestamp: now);
        },
        clock: () => now,
      );

      expect(await source.load(), isNull);
      expect(readLastKnownPosition, isFalse);
    },
  );

  test('returns null for missing and failed platform cache lookups', () async {
    final missing = GeolocatorNativeStartupLocationSource(
      checkPermission: () async => LocationPermission.always,
      getLastKnownPosition: () async => null,
      clock: () => now,
    );
    final failedPermission = GeolocatorNativeStartupLocationSource(
      checkPermission: () async => throw StateError('plugin unavailable'),
      getLastKnownPosition: () async => _position(timestamp: now),
      clock: () => now,
    );
    final failedLookup = GeolocatorNativeStartupLocationSource(
      checkPermission: () async => LocationPermission.whileInUse,
      getLastKnownPosition: () async => throw StateError('cache unavailable'),
      clock: () => now,
    );

    expect(await missing.load(), isNull);
    expect(await failedPermission.load(), isNull);
    expect(await failedLookup.load(), isNull);
  });

  test('rejects invalid coordinates, timestamp, and accuracy', () async {
    final invalidPositions = <Position>[
      _position(latitude: double.nan, timestamp: now),
      _position(latitude: 86, timestamp: now),
      _position(longitude: 181, timestamp: now),
      _position(timestamp: now.subtract(const Duration(days: 31))),
      _position(timestamp: now.add(const Duration(minutes: 6))),
      _position(accuracy: double.nan, timestamp: now),
      _position(accuracy: -1, timestamp: now),
      _position(accuracy: 20001, timestamp: now),
    ];

    for (final position in invalidPositions) {
      final source = GeolocatorNativeStartupLocationSource(
        checkPermission: () async => LocationPermission.whileInUse,
        getLastKnownPosition: () async => position,
        clock: () => now,
      );

      expect(await source.load(), isNull);
    }
  });

  test('bounds a platform call that never completes', () async {
    final pending = Completer<Position?>();
    final source = GeolocatorNativeStartupLocationSource(
      checkPermission: () async => LocationPermission.whileInUse,
      getLastKnownPosition: () => pending.future,
      clock: () => now,
      lookupTimeout: const Duration(milliseconds: 5),
    );

    expect(await source.load(), isNull);
  });
}

Position _position({
  double latitude = 30.2672,
  double longitude = -97.7431,
  double accuracy = 12,
  required DateTime timestamp,
}) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: timestamp,
  accuracy: accuracy,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);
