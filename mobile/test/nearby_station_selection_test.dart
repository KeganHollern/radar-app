import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radar_mobile/controllers/nearby_station_selection.dart';
import 'package:radar_mobile/controllers/radar_controller.dart';
import 'package:radar_mobile/models/radar_models.dart';
import 'package:radar_mobile/services/radar_api.dart';

void main() {
  test('nearest station selection is reflectivity-only and dateline-safe', () {
    final selected = nearestNearbyReflectivityStation(
      stations: [
        _station(
          id: 'KOLD',
          latitude: 0,
          longitude: 179.95,
          reflectivity: false,
        ),
        _station(id: 'TXYZ', latitude: 0, longitude: 179.99),
        _station(id: 'KDEN', latitude: 0, longitude: 170),
        _station(id: 'PABC', latitude: 0, longitude: -179.8),
      ],
      latitude: 0,
      longitude: 179.9,
    );

    expect(selected?.id, 'PABC');
  });

  test(
    'current station wins small boundary jitter but not a clear crossing',
    () {
      final west = _station(id: 'KAAA', latitude: 0, longitude: 0);
      final east = _station(id: 'KBBB', latitude: 0, longitude: 2);

      expect(
        nearestNearbyReflectivityStation(
          stations: [west, east],
          latitude: 0,
          longitude: 1.05,
          currentStation: west,
        )?.id,
        'KAAA',
      );
      expect(
        nearestNearbyReflectivityStation(
          stations: [west, east],
          latitude: 0,
          longitude: 1.2,
          currentStation: west,
        )?.id,
        'KBBB',
      );
    },
  );

  test(
    'camera center saved before stations selects after catalog refresh',
    () async {
      final requests = _SelectionRequests();
      final controller = RadarController(api: requests.api);

      expect(
        controller.updateNearbyDetailStation(latitude: 40, longitude: -100),
        isFalse,
      );
      expect(controller.nearbyDetailStation, isNull);
      expect(requests.latestStations, isEmpty);

      await controller.refreshStations();
      await pumpEventQueue(times: 20);

      expect(controller.nearbyDetailStation?.id, 'KAAA');
      expect(requests.latestStations, ['KAAA']);
      expect(requests.updateStations, ['KAAA']);
      expect(controller.radarLayerKey, contains(':KAAA:'));
      expect(controller.activeTileTemplate, contains('/aggregate/KAAA/'));
      controller.dispose();
    },
  );

  test(
    'camera station zones refresh only when the station ID changes',
    () async {
      final requests = _SelectionRequests();
      final controller = RadarController(api: requests.api);

      controller.updateNearbyDetailStation(latitude: 40, longitude: -100);
      await controller.refreshStations();
      await pumpEventQueue(times: 20);
      expect(controller.nearbyDetailStation?.id, 'KAAA');
      expect(requests.latestStations, ['KAAA']);

      expect(
        controller.updateNearbyDetailStation(latitude: 40.2, longitude: -99.8),
        isFalse,
      );
      await controller.refreshStations();
      await pumpEventQueue(times: 20);
      expect(requests.latestStations, ['KAAA']);
      expect(requests.updateStations, ['KAAA']);

      expect(
        controller.updateNearbyDetailStation(latitude: 40, longitude: -80.2),
        isTrue,
      );
      await pumpEventQueue(times: 20);
      expect(controller.nearbyDetailStation?.id, 'KBBB');
      expect(requests.latestStations, ['KAAA', 'KBBB']);
      expect(requests.updateStations, ['KAAA', 'KBBB']);
      expect(controller.radarLayerKey, contains(':KBBB:'));
      controller.dispose();
    },
  );

  test('Nearby detail station stays independent from station mode', () async {
    final requests = _SelectionRequests();
    final controller = RadarController(api: requests.api);

    controller.updateNearbyDetailStation(latitude: 40, longitude: -100);
    await controller.refreshStations();
    await pumpEventQueue(times: 20);
    expect(controller.nearbyDetailStation?.id, 'KAAA');

    controller.selectStationById('KBBB');
    await pumpEventQueue(times: 20);

    expect(controller.mode, RadarMode.stationReflectivity);
    expect(controller.selectedStation?.id, 'KBBB');
    expect(controller.nearbyDetailStation?.id, 'KAAA');
    expect(requests.latestProducts.last, 'reflectivity');
    expect(requests.latestStations.last, 'KBBB');

    final latestCount = requests.latestStations.length;
    controller.updateNearbyDetailStation(latitude: 40, longitude: -80);
    await pumpEventQueue(times: 20);
    expect(controller.selectedStation?.id, 'KBBB');
    expect(controller.nearbyDetailStation?.id, 'KBBB');
    expect(requests.latestStations, hasLength(latestCount));
    controller.dispose();
  });

  test(
    'prolonged detail failure downgrades an existing layer without a blank',
    () async {
      final requests = _SelectionRequests();
      final controller = RadarController(api: requests.api);

      controller.updateNearbyDetailStation(latitude: 40, longitude: -100);
      await controller.refreshStations();
      await pumpEventQueue(times: 20);
      final firstSnapshot = controller.snapshot;
      expect(firstSnapshot, isNotNull);
      expect(controller.radarLayerKey, contains(':KAAA:'));

      requests.failLatestStations.add('KBBB');
      controller.updateNearbyDetailStation(latitude: 40, longitude: -80);
      await pumpEventQueue(times: 20);

      expect(controller.nearbyDetailStation?.id, 'KBBB');
      expect(controller.snapshot, isNotNull);
      expect(identical(controller.snapshot, firstSnapshot), isFalse);
      expect(controller.radarLayerKey, contains(':_:'));
      expect(controller.activeTileTemplate, contains('/aggregate/regional/'));
      expect(controller.radarError, isNull);

      await controller.refreshRadar();
      expect(requests.latestStations, ['KAAA', 'KBBB', null, 'KBBB', null]);
      expect(controller.snapshot, isNotNull);
      expect(controller.radarLayerKey, contains(':_:'));
      expect(controller.activeTileTemplate, contains('/aggregate/regional/'));
      controller.dispose();
    },
  );

  test(
    'detail and regional failure preserve the last rendered layer',
    () async {
      final requests = _SelectionRequests();
      final controller = RadarController(api: requests.api);

      controller.updateNearbyDetailStation(latitude: 40, longitude: -100);
      await controller.refreshStations();
      await pumpEventQueue(times: 20);
      final firstSnapshot = controller.snapshot;
      final firstLayerKey = controller.radarLayerKey;
      expect(firstSnapshot, isNotNull);
      expect(firstLayerKey, contains(':KAAA:'));

      requests.failLatestStations.add('KBBB');
      requests.failLatestStations.add(null);
      controller.updateNearbyDetailStation(latitude: 40, longitude: -80);
      await pumpEventQueue(times: 20);

      expect(controller.nearbyDetailStation?.id, 'KBBB');
      expect(identical(controller.snapshot, firstSnapshot), isTrue);
      expect(controller.radarLayerKey, firstLayerKey);
      expect(controller.activeTileTemplate, contains('/aggregate/KAAA/'));
      expect(controller.radarError, isNotNull);
      controller.dispose();
    },
  );

  test(
    'cold detail failure renders regional fallback while retaining request',
    () async {
      final requests = _SelectionRequests()..failLatestStations.add('KAAA');
      final controller = RadarController(api: requests.api);

      controller.updateNearbyDetailStation(latitude: 40, longitude: -100);
      await controller.refreshStations();
      await pumpEventQueue(times: 20);

      expect(controller.nearbyDetailStation?.id, 'KAAA');
      expect(requests.latestStations, ['KAAA', null]);
      expect(requests.updateStations, ['KAAA']);
      expect(controller.snapshot, isNotNull);
      expect(controller.radarLayerKey, contains(':_:'));
      expect(controller.activeTileTemplate, contains('/aggregate/regional/'));
      expect(controller.radarError, isNull);
      controller.dispose();
    },
  );
}

RadarStation _station({
  required String id,
  required double latitude,
  required double longitude,
  bool reflectivity = true,
}) => RadarStation(
  id: id,
  name: id,
  latitude: latitude,
  longitude: longitude,
  reflectivityElevations: reflectivity ? const ['0.5'] : const [],
  velocityElevations: const ['0.5'],
  supportsReflectivity: reflectivity,
  supportsVelocity: true,
);

final class _SelectionRequests {
  _SelectionRequests() {
    api = RadarApi(
      baseUrl: 'https://radar.test',
      client: MockClient((request) async {
        switch (request.url.path) {
          case '/api/v1/stations':
            return http.Response(_stations, 200);
          case '/api/v1/radar/latest':
            final product = request.url.queryParameters['product']!;
            final station = request.url.queryParameters['station'];
            latestProducts.add(product);
            latestStations.add(station);
            if (failLatestStations.contains(station)) {
              return http.Response(
                '{"error":{"message":"replacement unavailable"}}',
                503,
              );
            }
            return http.Response(
              jsonEncode({
                'observedAt': '2026-07-14T14:32:03Z',
                'version': '$product-${station ?? 'regional'}',
                'tileTemplate':
                    '/tiles/$product/${station ?? 'regional'}/0.5/'
                    '{z}/{x}/{y}.png',
              }),
              200,
            );
          case '/api/v1/updates':
            updateStations.add(request.url.queryParameters['station']);
            return http.Response(
              'retry: 5000\n\n',
              200,
              headers: {'Content-Type': 'text/event-stream'},
            );
          default:
            return http.Response('not found', 404);
        }
      }),
    );
  }

  late final RadarApi api;
  final List<String> latestProducts = [];
  final List<String?> latestStations = [];
  final List<String?> updateStations = [];
  final Set<String?> failLatestStations = {};
}

const _stations = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "id": "KAAA",
      "properties": {
        "id": "KAAA",
        "name": "West",
        "supports_reflectivity": true,
        "supports_velocity": true,
        "reflectivity_elevations": ["0.5"],
        "velocity_elevations": ["0.5"]
      },
      "geometry": {"type": "Point", "coordinates": [-100, 40]}
    },
    {
      "type": "Feature",
      "id": "KBBB",
      "properties": {
        "id": "KBBB",
        "name": "East",
        "supports_reflectivity": true,
        "supports_velocity": true,
        "reflectivity_elevations": ["0.5"],
        "velocity_elevations": ["0.5"]
      },
      "geometry": {"type": "Point", "coordinates": [-80, 40]}
    }
  ]
}
''';
