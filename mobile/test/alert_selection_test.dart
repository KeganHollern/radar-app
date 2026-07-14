import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/models/alert_selection.dart';
import 'package:radar_mobile/models/radar_models.dart';

void main() {
  test('overlapping rendered alerts are ordered and de-duplicated', () {
    final first = _alert('first', 'Flood Warning');
    final second = _alert('second', 'Tornado Warning');
    final hidden = _alert('hidden', 'Air Quality Alert');

    final resolved = resolveAlertsAtTap(
      renderedFeatures: const [
        {
          'properties': {'id': 'second'},
        },
        {'id': 'first'},
        {'id': 'second'},
        {'id': 'hidden'},
      ],
      visibleAlerts: [first, second],
      fallbackId: 'first',
    );

    expect(resolved, [second, first]);
    expect(resolved, isNot(contains(hidden)));
  });

  test('original tapped id is used when rendered query is empty', () {
    final alert = _alert('only', 'Severe Thunderstorm Warning');

    final resolved = resolveAlertsAtTap(
      renderedFeatures: const [],
      visibleAlerts: [alert],
      fallbackId: 'only',
    );

    expect(resolved, [alert]);
  });
}

WeatherAlert _alert(String id, String event) => WeatherAlert.fromFeature({
  'type': 'Feature',
  'id': id,
  'properties': {'event': event},
  'geometry': {
    'type': 'Polygon',
    'coordinates': [
      [
        [-94, 41],
        [-93, 41],
        [-93, 42],
        [-94, 41],
      ],
    ],
  },
});
