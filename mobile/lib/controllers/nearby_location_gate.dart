/// Rejects stale or unusably coarse GPS samples before they can switch the
/// radar used by location-follow mode.
final class NearbyLocationGate {
  NearbyLocationGate({this.maximumAccuracyMeters = 20000});

  final double maximumAccuracyMeters;
  DateTime? _latestAcceptedAt;

  bool accept({required DateTime timestamp, double? horizontalAccuracy}) {
    final latest = _latestAcceptedAt;
    if (latest != null && !timestamp.isAfter(latest)) return false;
    if (horizontalAccuracy != null &&
        (!horizontalAccuracy.isFinite ||
            horizontalAccuracy < 0 ||
            horizontalAccuracy > maximumAccuracyMeters)) {
      return false;
    }
    _latestAcceptedAt = timestamp;
    return true;
  }
}
