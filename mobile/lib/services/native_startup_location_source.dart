import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import 'startup_location_store.dart';

typedef LocationPermissionReader = Future<LocationPermission> Function();
typedef LastKnownPositionReader = Future<Position?> Function();

abstract interface class NativeStartupLocationSource {
  Future<StartupLocation?> load();
}

/// Reads the operating system's cached fix without requesting permission.
///
/// This covers the first launch after upgrading from a build that did not yet
/// persist an app-local startup location. Permission prompting remains owned by
/// the location service, so this lookup cannot start a second permission request
/// while the app is resuming or the Android permission dialog is visible.
final class GeolocatorNativeStartupLocationSource
    implements NativeStartupLocationSource {
  GeolocatorNativeStartupLocationSource({
    LocationPermissionReader? checkPermission,
    LastKnownPositionReader? getLastKnownPosition,
    DateTime Function()? clock,
    this.maximumAge = const Duration(days: 30),
    this.maximumFutureSkew = const Duration(minutes: 5),
    this.maximumAccuracyMeters = 20000,
    this.lookupTimeout = const Duration(milliseconds: 500),
  }) : _checkPermission = checkPermission ?? Geolocator.checkPermission,
       _getLastKnownPosition =
           getLastKnownPosition ?? (() => Geolocator.getLastKnownPosition()),
       _clock = clock ?? DateTime.now;

  final LocationPermissionReader _checkPermission;
  final LastKnownPositionReader _getLastKnownPosition;
  final DateTime Function() _clock;
  final Duration maximumAge;
  final Duration maximumFutureSkew;
  final double maximumAccuracyMeters;
  final Duration lookupTimeout;

  @override
  Future<StartupLocation?> load() async {
    try {
      return await _load().timeout(lookupTimeout);
    } catch (_) {
      // A native cache miss, plugin failure, or timeout is an optional startup
      // optimization and must never prevent the map from opening.
      return null;
    }
  }

  Future<StartupLocation?> _load() async {
    final permission = await _checkPermission();
    if (permission != LocationPermission.always &&
        permission != LocationPermission.whileInUse) {
      return null;
    }

    final position = await _getLastKnownPosition();
    if (position == null) return null;

    final latitude = position.latitude;
    final longitude = position.longitude;
    final accuracy = position.accuracy;
    if (!latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -SharedPreferencesStartupLocationStore.maximumMapLatitude ||
        latitude > SharedPreferencesStartupLocationStore.maximumMapLatitude ||
        longitude < -180 ||
        longitude > 180 ||
        !accuracy.isFinite ||
        accuracy < 0 ||
        accuracy > maximumAccuracyMeters) {
      return null;
    }

    final observedAt = position.timestamp.toUtc();
    final now = _clock().toUtc();
    if (observedAt.isAfter(now.add(maximumFutureSkew)) ||
        now.difference(observedAt) > maximumAge) {
      return null;
    }

    return StartupLocation(
      position: LatLng(latitude, longitude),
      observedAt: observedAt,
    );
  }
}
