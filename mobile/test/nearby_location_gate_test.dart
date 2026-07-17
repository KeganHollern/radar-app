import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/controllers/nearby_location_gate.dart';

void main() {
  test('follow location gate rejects stale and extremely coarse fixes', () {
    final first = DateTime.utc(2026, 7, 14, 14, 30);
    final gate = NearbyLocationGate(
      clock: () => first.add(const Duration(minutes: 2)),
    );

    expect(gate.accept(timestamp: first, horizontalAccuracy: 12), isTrue);
    expect(
      gate.accept(
        timestamp: first.subtract(const Duration(seconds: 1)),
        horizontalAccuracy: 5,
      ),
      isFalse,
    );
    expect(
      gate.accept(
        timestamp: first.add(const Duration(seconds: 1)),
        horizontalAccuracy: 25000,
      ),
      isFalse,
    );
    expect(
      gate.accept(
        timestamp: first.add(const Duration(seconds: 2)),
        horizontalAccuracy: 15,
      ),
      isTrue,
    );
  });

  test('rejects old cached and implausibly future native fixes', () {
    final now = DateTime.utc(2026, 7, 17, 14, 30);
    final gate = NearbyLocationGate(clock: () => now);

    expect(
      gate.accept(
        timestamp: now.subtract(const Duration(minutes: 6)),
        horizontalAccuracy: 10,
      ),
      isFalse,
    );
    expect(
      gate.accept(
        timestamp: now.add(const Duration(minutes: 2)),
        horizontalAccuracy: 10,
      ),
      isFalse,
    );
    expect(
      gate.accept(
        timestamp: now.subtract(const Duration(seconds: 5)),
        horizontalAccuracy: 10,
      ),
      isTrue,
    );
  });
}
