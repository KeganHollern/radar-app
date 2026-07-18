import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/models/lightning_models.dart';

void main() {
  test('parses the versioned backend GeoJSON envelope', () {
    final snapshot = LightningSnapshot.fromJson({
      'schemaVersion': '1',
      'mode': 'event',
      'generation': 'goes-19:123',
      'observedAt': '2026-07-18T12:00:00Z',
      'checkedAt': '2026-07-18T12:00:20Z',
      'stale': false,
      'available': false,
      'attribution': 'NOAA GOES-R GLM',
      'retentionMs': 45000,
      'data': {
        'type': 'FeatureCollection',
        'features': [
          _feature('flash-1'),
          _feature('flash-1'),
          {
            'type': 'Feature',
            'id': 'bad-point',
            'properties': {'observedAt': '2026-07-18T12:00:00Z'},
            'geometry': {
              'type': 'Point',
              'coordinates': [-200, 30],
            },
          },
        ],
      },
    });

    expect(snapshot.mode, LightningSourceMode.event);
    expect(snapshot.generation, 'goes-19:123');
    expect(snapshot.checkedAt, DateTime.utc(2026, 7, 18, 12, 0, 20));
    expect(snapshot.retention, const Duration(seconds: 45));
    expect(snapshot.attribution, 'NOAA GOES-R GLM');
    expect(snapshot.available, isFalse);
    expect(snapshot.strikes, hasLength(1));
    expect(snapshot.strikes.single.id, 'flash-1');
    expect(snapshot.strikes.single.latitude, 30.27);
    expect(snapshot.strikes.single.longitude, -97.74);
    expect(snapshot.strikes.single.satellite, 'GOES-19');
  });

  test('missing provider id gets a deterministic fallback identity', () {
    final feature = _feature(null);
    final first = LightningStrike.tryFromFeature(feature);
    final second = LightningStrike.tryFromFeature(feature);

    expect(first, isNotNull);
    expect(first!.id, second!.id);
    expect(first.id, contains('lightning flash'));
  });

  test('bounds validate ranges and preserve antimeridian viewports', () {
    final bounds = LightningBounds(west: 170, south: 20, east: -170, north: 50);
    expect(bounds.queryValue, '170.0000,20.0000,-170.0000,50.0000');
    expect(
      () => LightningBounds(west: -100, south: 50, east: -90, north: 40),
      throwsArgumentError,
    );
    expect(
      () => LightningBounds(west: -180, south: 0, east: 180, north: 40),
      throwsArgumentError,
    );
    expect(
      () => LightningBounds(west: -100, south: -50, east: -90, north: 50),
      throwsArgumentError,
    );
  });

  test('subscription padding is capped to the backend query limits', () {
    final bounds = lightningSubscriptionBounds(
      west: -180,
      south: -85,
      east: 180,
      north: 85,
      focusLongitude: -98,
      focusLatitude: 39,
    );

    expect(bounds.west, -178);
    expect(bounds.east, -18);
    expect(bounds.south, -1);
    expect(bounds.north, 79);
    expect(bounds.queryValue, '-178.0000,-1.0000,-18.0000,79.0000');
  });

  test('subscription padding crosses the antimeridian safely', () {
    final bounds = lightningSubscriptionBounds(
      west: 170,
      south: 20,
      east: -170,
      north: 50,
    );

    expect(bounds.west, 164);
    expect(bounds.east, -164);
    expect(bounds.south, 11);
    expect(bounds.north, 59);
  });
}

Map<String, dynamic> _feature(String? id) => {
  'type': 'Feature',
  'id': ?id,
  'properties': {
    'kind': 'satellite-detected lightning flash',
    'observedAt': '2026-07-18T12:00:00Z',
    'receivedAt': '2026-07-18T12:00:20Z',
    'satellite': 'GOES-19',
  },
  'geometry': {
    'type': 'Point',
    'coordinates': [-97.74, 30.27],
  },
};
