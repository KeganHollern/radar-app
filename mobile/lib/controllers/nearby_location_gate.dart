/// Rejects stale or unusably coarse GPS samples before they can switch the
/// radar used by location-follow mode.
final class NearbyLocationGate {
  NearbyLocationGate({
    this.maximumAccuracyMeters = 20000,
    this.maximumAge = const Duration(minutes: 5),
    this.maximumFutureSkew = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final double maximumAccuracyMeters;
  final Duration maximumAge;
  final Duration maximumFutureSkew;
  final DateTime Function() _clock;
  DateTime? _latestAcceptedAt;

  bool accept({required DateTime timestamp, double? horizontalAccuracy}) {
    final observedAt = timestamp.toUtc();
    final now = _clock().toUtc();
    if (observedAt.isBefore(now.subtract(maximumAge)) ||
        observedAt.isAfter(now.add(maximumFutureSkew))) {
      return false;
    }
    final latest = _latestAcceptedAt;
    if (latest != null && !observedAt.isAfter(latest)) return false;
    if (horizontalAccuracy != null &&
        (!horizontalAccuracy.isFinite ||
            horizontalAccuracy < 0 ||
            horizontalAccuracy > maximumAccuracyMeters)) {
      return false;
    }
    _latestAcceptedAt = observedAt;
    return true;
  }
}
