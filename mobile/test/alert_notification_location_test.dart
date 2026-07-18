import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:radar_mobile/services/alert_notification_location.dart';

void main() {
  test('fresh background position wins without reading the cache', () async {
    final now = DateTime.now();
    final gateway = _FakePositionGateway(
      current: _position(latitude: 31, timestamp: now),
      cached: _position(latitude: 30, timestamp: now),
    );
    final source = GeolocatorAlertNotificationLocationSource(gateway: gateway);

    final point = await source.currentLocation();

    expect(point?.latitude, 31);
    expect(gateway.calls, ['services', 'permission', 'current']);
  });

  test('a recent cached fix is used only after a fresh lookup fails', () async {
    final now = DateTime.now();
    final gateway = _FakePositionGateway(
      currentError: StateError('timeout'),
      cached: _position(
        latitude: 30,
        timestamp: now.subtract(const Duration(minutes: 5)),
      ),
    );
    final source = GeolocatorAlertNotificationLocationSource(gateway: gateway);

    final point = await source.currentLocation();

    expect(point?.latitude, 30);
    expect(gateway.calls, ['services', 'permission', 'current', 'cached']);
  });

  test(
    'an old cached position is rejected after a fresh lookup fails',
    () async {
      final gateway = _FakePositionGateway(
        currentError: StateError('timeout'),
        cached: _position(
          latitude: 30,
          timestamp: DateTime.now().subtract(const Duration(minutes: 11)),
        ),
      );
      final source = GeolocatorAlertNotificationLocationSource(
        gateway: gateway,
      );

      expect(await source.currentLocation(), isNull);
    },
  );
}

Position _position({required double latitude, required DateTime timestamp}) =>
    Position(
      latitude: latitude,
      longitude: -97.7431,
      timestamp: timestamp,
      accuracy: 12,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

final class _FakePositionGateway implements AlertNotificationPositionGateway {
  _FakePositionGateway({this.current, this.currentError, this.cached});

  final Position? current;
  final Object? currentError;
  final Position? cached;
  final List<String> calls = [];

  @override
  Future<Position> currentPosition() async {
    calls.add('current');
    if (currentError case final error?) throw error;
    return current!;
  }

  @override
  Future<Position?> lastKnownPosition() async {
    calls.add('cached');
    return cached;
  }

  @override
  Future<LocationPermission> permission() async {
    calls.add('permission');
    return LocationPermission.always;
  }

  @override
  Future<bool> servicesEnabled() async {
    calls.add('services');
    return true;
  }
}
