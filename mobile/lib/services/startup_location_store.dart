import 'dart:async';
import 'dart:convert';

import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _startupLocationKey = 'map.startup_location.v1';

/// A recent device fix that can seed the map before live GPS is available.
final class StartupLocation {
  const StartupLocation({required this.position, required this.observedAt});

  final LatLng position;
  final DateTime observedAt;
}

abstract interface class StartupLocationStore {
  Future<StartupLocation?> load();

  Future<void> save(StartupLocation location);
}

/// Keeps the last accepted device location on the device for startup only.
///
/// One JSON value is used so a terminated write cannot combine coordinates and
/// timestamps from different fixes. Invalid, future, and old records fail
/// closed to the normal national startup view.
final class SharedPreferencesStartupLocationStore
    implements StartupLocationStore {
  SharedPreferencesStartupLocationStore({
    DateTime Function()? clock,
    this.maximumAge = const Duration(days: 30),
    this.maximumFutureSkew = const Duration(minutes: 5),
  }) : _clock = clock ?? DateTime.now;

  static const double maximumMapLatitude = 85.05112878;

  final DateTime Function() _clock;
  final Duration maximumAge;
  final Duration maximumFutureSkew;

  @override
  Future<StartupLocation?> load() async {
    try {
      final preferences = await SharedPreferences.getInstance();
      final encoded = preferences.getString(_startupLocationKey);
      if (encoded == null) return null;

      final decoded = jsonDecode(encoded);
      if (decoded is! Map<String, dynamic> || decoded['schema'] != 1) {
        return null;
      }
      final latitude = decoded['latitude'];
      final longitude = decoded['longitude'];
      final observedAtMillis = decoded['observedAtMillis'];
      if (latitude is! num || longitude is! num || observedAtMillis is! int) {
        return null;
      }

      final lat = latitude.toDouble();
      final lon = longitude.toDouble();
      if (!lat.isFinite ||
          !lon.isFinite ||
          lat < -maximumMapLatitude ||
          lat > maximumMapLatitude ||
          lon < -180 ||
          lon > 180) {
        return null;
      }

      final observedAt = DateTime.fromMillisecondsSinceEpoch(
        observedAtMillis,
        isUtc: true,
      );
      final now = _clock().toUtc();
      if (observedAt.isAfter(now.add(maximumFutureSkew)) ||
          now.difference(observedAt) > maximumAge) {
        return null;
      }

      return StartupLocation(
        position: LatLng(lat, lon),
        observedAt: observedAt,
      );
    } catch (_) {
      // Startup location is an optimization. Preference/plugin/JSON failures
      // must never prevent the map from opening.
      return null;
    }
  }

  @override
  Future<void> save(StartupLocation location) async {
    final lat = location.position.latitude;
    final lon = location.position.longitude;
    if (!lat.isFinite ||
        !lon.isFinite ||
        lat < -maximumMapLatitude ||
        lat > maximumMapLatitude ||
        lon < -180 ||
        lon > 180) {
      return;
    }

    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      _startupLocationKey,
      jsonEncode({
        'schema': 1,
        'latitude': lat,
        'longitude': lon,
        'observedAtMillis': location.observedAt.toUtc().millisecondsSinceEpoch,
      }),
    );
  }
}

/// Serializes and rate-limits location writes while retaining the newest fix.
final class StartupLocationWriter {
  StartupLocationWriter(
    this._store, {
    this.writeInterval = const Duration(seconds: 30),
  });

  final StartupLocationStore _store;
  final Duration writeInterval;

  StartupLocation? _latest;
  DateTime? _lastQueuedAt;
  Future<void> _writeTail = Future<void>.value();

  void record(StartupLocation location) {
    final latest = _latest;
    if (latest != null && !location.observedAt.isAfter(latest.observedAt)) {
      return;
    }
    _latest = location;

    final lastQueuedAt = _lastQueuedAt;
    if (lastQueuedAt == null ||
        location.observedAt.difference(lastQueuedAt) >= writeInterval) {
      _queue(location);
    }
  }

  /// Persists a throttled fix before the app backgrounds or the screen closes.
  Future<void> flush() {
    final latest = _latest;
    if (latest != null && latest.observedAt != _lastQueuedAt) {
      _queue(latest);
    }
    return _writeTail;
  }

  void _queue(StartupLocation location) {
    _lastQueuedAt = location.observedAt;
    _writeTail = _writeTail.then((_) async {
      try {
        await _store.save(location);
      } catch (_) {
        // A local preference failure should not affect live location or map
        // behavior, and later writes should remain eligible to run.
      }
    });
  }
}
