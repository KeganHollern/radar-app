import 'package:geolocator/geolocator.dart';

enum LocationAccess {
  checking,
  granted,
  servicesDisabled,
  denied,
  deniedForever,
}

final class LocationService {
  Future<LocationAccess> requestAccess() async {
    // Some Android emulator/system-image combinations surface a disabled
    // provider as a platform exception instead of returning `false`. Treat it
    // like the normal disabled-service state so lifecycle resumes never leak
    // an unhandled asynchronous exception.
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        return LocationAccess.servicesDisabled;
      }
    } catch (_) {
      return LocationAccess.servicesDisabled;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return switch (permission) {
      LocationPermission.always ||
      LocationPermission.whileInUse => LocationAccess.granted,
      LocationPermission.deniedForever => LocationAccess.deniedForever,
      _ => LocationAccess.denied,
    };
  }

  Future<bool> openSettings(LocationAccess access) =>
      access == LocationAccess.servicesDisabled
      ? Geolocator.openLocationSettings()
      : Geolocator.openAppSettings();
}
