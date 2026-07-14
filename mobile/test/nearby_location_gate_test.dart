import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/controllers/nearby_location_gate.dart';

void main() {
  test('follow location gate rejects stale and extremely coarse fixes', () {
    final gate = NearbyLocationGate();
    final first = DateTime.utc(2026, 7, 14, 14, 30);

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
}
