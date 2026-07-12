import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radar_mobile/controllers/radar_controller.dart';
import 'package:radar_mobile/models/radar_models.dart';
import 'package:radar_mobile/services/radar_api.dart';

void main() {
  test('parses backend latest-scan camelCase metadata', () {
    final snapshot = RadarSnapshot.fromJson({
      'observedAt': '2026-07-12T18:42:00Z',
      'tileTemplate': '/api/v1/tiles/{z}/{x}/{y}.png',
      'version': 'scan-42',
      'stale': true,
      'ageSeconds': 420,
    });

    expect(snapshot.observedAt, DateTime.utc(2026, 7, 12, 18, 42));
    expect(snapshot.tileTemplate, '/api/v1/tiles/{z}/{x}/{y}.png');
    expect(snapshot.version, 'scan-42');
    expect(snapshot.stale, isTrue);
    expect(snapshot.ageSeconds, 420);
  });

  test('station capabilities control velocity and elevation choices', () {
    final station = RadarStation.fromJson({
      'id': 'KDMX',
      'name': 'Des Moines',
      'latitude': 41.73,
      'longitude': -93.72,
      'elevations': ['0.5', 1.5],
      'supports_velocity': true,
      'supports_reflectivity': true,
    });

    expect(station.id, 'KDMX');
    expect(station.reflectivityElevations, ['0.5', '1.5']);
    expect(station.velocityElevations, ['0.5', '1.5']);
    expect(station.supportsVelocity, isTrue);
  });

  test('tile URL stays latest-only and cache-busts by scan version', () {
    final api = RadarApi(baseUrl: 'https://radar.lystic.dev/');
    final snapshot = RadarSnapshot(
      observedAt: DateTime.utc(2026, 7, 12),
      version: 'new scan',
      tileTemplate: '/tiles/{product}/{z}/{x}/{y}.png',
    );

    final result = api.tileTemplate(
      mode: RadarMode.aggregate,
      snapshot: snapshot,
    );

    expect(
      result,
      'https://radar.lystic.dev/tiles/aggregate/{z}/{x}/{y}.png?v=new+scan',
    );
    api.close();
  });

  test('backend error envelopes expose their readable message', () async {
    final api = RadarApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient(
        (_) async => http.Response(
          '{"error":{"code":"invalid_selection","message":"Choose a station"}}',
          400,
        ),
      ),
    );

    await expectLater(
      api.fetchLatest(mode: RadarMode.stationReflectivity),
      throwsA(
        isA<RadarApiException>().having(
          (error) => error.message,
          'message',
          'Choose a station',
        ),
      ),
    );
    api.close();
  });

  test('alert styling honors the color assigned by the backend', () {
    final alert = WeatherAlert.fromFeature({
      'type': 'Feature',
      'id': 'alert-1',
      'properties': {
        'event': 'Tornado Warning',
        'radarColor': '#8b7ec8',
        'radarGeometryPartial': true,
        'radarGeometryZonesRequested': 4,
        'radarGeometryZonesResolved': 3,
      },
      'geometry': {
        'type': 'Polygon',
        'coordinates': [
          [
            [-94.0, 41.0],
            [-93.0, 41.0],
            [-93.0, 42.0],
            [-94.0, 41.0],
          ],
        ],
      },
    });

    expect(alert.colorHex, '#8B7EC8');
    expect(alert.hasMapGeometry, isTrue);
    expect(alert.radarGeometryPartial, isTrue);
    expect(alert.requestedZoneCount, 4);
    expect(alert.resolvedZoneCount, 3);
    expect(alert.toGeoJsonFeature()['properties'], {
      'id': 'alert-1',
      'alert_color': '#8B7EC8',
      'event': 'Tornado Warning',
    });
  });

  test(
    'alert response reports stale cache headers while preserving data',
    () async {
      final api = RadarApi(
        baseUrl: 'https://radar.lystic.dev',
        client: MockClient(
          (_) async => http.Response(
            _alertCollection,
            200,
            headers: {'X-Radar-Cache': 'STALE'},
          ),
        ),
      );

      final result = await api.fetchAlerts();

      expect(result.stale, isTrue);
      expect(result.alerts, hasLength(1));
      api.close();
    },
  );

  test('failed alert refresh retains polygons until a fresh success', () async {
    var request = 0;
    final api = RadarApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient((_) async {
        request++;
        if (request == 2) throw Exception('network unavailable');
        return http.Response(_alertCollection, 200);
      }),
    );
    final controller = RadarController(api: api);

    await controller.refreshAlerts();
    expect(controller.alerts, hasLength(1));
    expect(controller.alertsStale, isFalse);
    expect(controller.alertRevision, 1);
    expect(identical(controller.alertGeoJson, controller.alertGeoJson), isTrue);

    await controller.refreshAlerts();
    expect(controller.alerts, hasLength(1));
    expect(controller.alertsStale, isTrue);
    expect(controller.alertsError, contains('network unavailable'));
    expect(controller.alertRevision, 1);

    await controller.refreshAlerts();
    expect(controller.alerts, hasLength(1));
    expect(controller.alertsStale, isFalse);
    expect(controller.alertsError, isNull);
    expect(controller.alertRevision, 2);
    controller.dispose();
  });

  test('unchanged alert ETag does not advance the map revision', () async {
    var request = 0;
    final api = RadarApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient((requestData) async {
        request++;
        if (request == 2) {
          expect(requestData.headers['If-None-Match'], '"alerts-1"');
          return http.Response('', 304, headers: {'ETag': '"alerts-1"'});
        }
        return http.Response(
          _alertCollection,
          200,
          headers: {'ETag': '"alerts-1"'},
        );
      }),
    );
    final controller = RadarController(api: api);

    await controller.refreshAlerts();
    final firstGeoJson = controller.alertGeoJson;
    await controller.refreshAlerts();

    expect(controller.alertRevision, 1);
    expect(identical(controller.alertGeoJson, firstGeoJson), isTrue);
    expect(controller.alerts, hasLength(1));
    controller.dispose();
  });

  test('station GeoJSON is cached behind a monotonic revision', () async {
    final api = RadarApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient((_) async => http.Response(_stationCollection, 200)),
    );
    final controller = RadarController(api: api);

    await controller.refreshStations();
    final firstGeoJson = controller.stationGeoJson;

    expect(controller.stationRevision, 1);
    expect(identical(controller.stationGeoJson, firstGeoJson), isTrue);
    expect(firstGeoJson['features'], hasLength(1));
    controller.dispose();
  });
}

const _alertCollection = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "id": "alert-1",
      "properties": {"event": "Tornado Warning"},
      "geometry": {
        "type": "Polygon",
        "coordinates": [[[-94, 41], [-93, 41], [-93, 42], [-94, 41]]]
      }
    }
  ]
}
''';

const _stationCollection = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "id": "KDMX",
      "properties": {
        "id": "KDMX",
        "name": "Des Moines",
        "supports_reflectivity": true,
        "supports_velocity": true
      },
      "geometry": {"type": "Point", "coordinates": [-93.72, 41.73]}
    }
  ]
}
''';
