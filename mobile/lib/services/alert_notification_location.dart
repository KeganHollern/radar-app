import 'package:geolocator/geolocator.dart';

import 'alert_notification_api.dart';

abstract interface class AlertNotificationLocationSource {
  Future<AlertNotificationPoint?> currentLocation();
}

abstract interface class AlertNotificationPositionGateway {
  Future<bool> servicesEnabled();

  Future<LocationPermission> permission();

  Future<Position> currentPosition();

  Future<Position?> lastKnownPosition();
}

final class GeolocatorAlertNotificationPositionGateway
    implements AlertNotificationPositionGateway {
  @override
  Future<bool> servicesEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> permission() => Geolocator.checkPermission();

  @override
  Future<Position> currentPosition() => Geolocator.getCurrentPosition(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.medium,
      timeLimit: Duration(seconds: 12),
    ),
  );

  @override
  Future<Position?> lastKnownPosition() => Geolocator.getLastKnownPosition();
}

final class GeolocatorAlertNotificationLocationSource
    implements AlertNotificationLocationSource {
  GeolocatorAlertNotificationLocationSource({
    AlertNotificationPositionGateway? gateway,
    this.maximumCachedAge = const Duration(minutes: 10),
    this.maximumAccuracyMeters = 5000,
  }) : _gateway = gateway ?? GeolocatorAlertNotificationPositionGateway();

  final AlertNotificationPositionGateway _gateway;
  final Duration maximumCachedAge;
  final double maximumAccuracyMeters;

  @override
  Future<AlertNotificationPoint?> currentLocation() async {
    try {
      if (!await _gateway.servicesEnabled()) return null;
      if (await _gateway.permission() != LocationPermission.always) {
        return null;
      }

      try {
        final current = await _gateway.currentPosition();
        if (_isUsable(current, DateTime.now())) return _point(current);
      } catch (_) {
        // A recent platform fix remains a bounded fallback when Android cannot
        // produce a fresh background fix before WorkManager's time budget.
      }
      final cached = await _gateway.lastKnownPosition();
      final now = DateTime.now();
      return cached != null && _isUsable(cached, now) ? _point(cached) : null;
    } catch (_) {
      return null;
    }
  }

  bool _isUsable(Position position, DateTime now) {
    if (!position.latitude.isFinite ||
        !position.longitude.isFinite ||
        position.latitude < -90 ||
        position.latitude > 90 ||
        position.longitude < -180 ||
        position.longitude > 180 ||
        !position.accuracy.isFinite ||
        position.accuracy < 0 ||
        position.accuracy > maximumAccuracyMeters) {
      return false;
    }
    final age = now.difference(position.timestamp);
    return !age.isNegative && age <= maximumCachedAge;
  }

  AlertNotificationPoint _point(Position position) => AlertNotificationPoint(
    latitude: position.latitude,
    longitude: position.longitude,
    observedAt: position.timestamp,
    accuracyMeters: position.accuracy,
  );
}
