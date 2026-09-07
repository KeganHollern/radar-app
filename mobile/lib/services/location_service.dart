import 'package:geolocator/geolocator.dart';

enum LocationAccess {
  checking,
  granted,
  servicesDisabled,
  denied,
  deniedForever,
}

final class LocationService {
  /// Reads the current location setting without opening a permission prompt.
  Future<LocationAccess> checkAccess() => _access(request: false);

  /// Opens Android's foreground-location prompt when access is not yet granted.
  Future<LocationAccess> requestAccess() => _access(request: true);

  Future<LocationAccess> _access({required bool request}) async {
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
    try {
      var permission = await Geolocator.checkPermission();
      if (request && permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      return switch (permission) {
        LocationPermission.always ||
        LocationPermission.whileInUse => LocationAccess.granted,
        LocationPermission.deniedForever => LocationAccess.deniedForever,
        _ => LocationAccess.denied,
      };
    } catch (_) {
      // Permission checks and prompts can also fail, including while Android
      // recreates the activity. Keep the map usable and allow a later retry.
      return LocationAccess.denied;
    }
  }

  Future<bool> openSettings(LocationAccess access) =>
      access == LocationAccess.servicesDisabled
      ? Geolocator.openLocationSettings()
      : Geolocator.openAppSettings();
}
