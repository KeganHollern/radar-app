import 'package:maplibre_gl/maplibre_gl.dart';

/// Coordinates the map's one-time startup focus without turning on follow mode.
///
/// The native map and its first user-location update become ready independently.
/// This small state machine lets either arrive first, prevents duplicate camera
/// animations, and permanently yields when the user starts interacting with the
/// map or explicitly enables location following.
final class StartupCameraFocus {
  static const double zoom = 8;

  LatLng? _latestLocation;
  _StartupFocusState _state = _StartupFocusState.pending;

  void updateLocation(LatLng location) {
    if (_state != _StartupFocusState.pending) return;
    _latestLocation = location;
  }

  /// Returns the location to focus exactly once when both inputs are ready.
  LatLng? takeTarget({required bool mapReady}) {
    if (!mapReady || _state != _StartupFocusState.pending) return null;
    final target = _latestLocation;
    if (target == null) return null;
    _state = _StartupFocusState.focusing;
    return target;
  }

  /// Records whether the native camera accepted the requested animation.
  ///
  /// A rejected animation may be retried on a later location update. Once the
  /// focus succeeds, later GPS updates never move the camera unless follow mode
  /// is separately enabled by the user.
  void finish({required bool succeeded}) {
    if (_state != _StartupFocusState.focusing) return;
    _state = succeeded
        ? _StartupFocusState.completed
        : _StartupFocusState.pending;
  }

  /// Permanently gives camera ownership to the user for this screen instance.
  void abandon() {
    _state = _StartupFocusState.abandoned;
    _latestLocation = null;
  }
}

enum _StartupFocusState { pending, focusing, completed, abandoned }
