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

  test('aggregate snapshot query survives mobile cache-busting', () {
    const version = '0123456789abcdef01234567';
    final token =
        '${List.filled(76, 'A').join()}.${List.filled(22, 'B').join()}';
    final api = RadarApi(baseUrl: 'https://radar.lystic.dev');
    final snapshot = RadarSnapshot(
      observedAt: DateTime.utc(2026, 7, 12),
      version: version,
      tileTemplate:
          'https://radar.lystic.dev/api/v1/radar/tiles/aggregate/conus/'
          '0.5/{z}/{x}/{y}.png?timestamp=$version&snapshot=$token',
    );

    final result = api.tileTemplate(
      mode: RadarMode.aggregate,
      snapshot: snapshot,
    );
    final parsed = Uri.parse(result);

    expect(parsed.queryParameters['timestamp'], version);
    expect(parsed.queryParameters['snapshot'], token);
    expect(parsed.queryParameters['v'], version);
    expect(result, contains('/{z}/{x}/{y}.png'));
    expect(result.length, lessThan(512));
    api.close();
  });

  test(
    'aggregate latest and updates encode the detail station query',
    () async {
      final requestedUris = <Uri>[];
      final api = RadarApi(
        baseUrl: 'https://radar.lystic.dev',
        client: MockClient((request) async {
          requestedUris.add(request.url);
          if (request.url.path == '/api/v1/updates') {
            return http.Response(
              'retry: 5000\n\n',
              200,
              headers: {'Content-Type': 'text/event-stream'},
            );
          }
          return http.Response(
            '{"observedAt":"2026-07-14T14:32:03Z","version":"scan"}',
            200,
          );
        }),
      );
      final detailStation = _testStation('K A/&?');

      await api.fetchLatest(mode: RadarMode.aggregate, station: detailStation);
      await api
          .watchUpdates(mode: RadarMode.aggregate, station: detailStation)
          .drain<void>();

      expect(requestedUris, hasLength(2));
      for (final uri in requestedUris) {
        expect(uri.queryParameters['product'], 'aggregate');
        expect(uri.queryParameters['station'], detailStation.id);
        expect(uri.query, contains('station=K+A%2F%26%3F'));
      }
      api.close();
    },
  );

  test('aggregate tile template retains its detail station', () {
    final api = RadarApi(baseUrl: 'https://radar.lystic.dev');
    final snapshot = RadarSnapshot(
      observedAt: DateTime.utc(2026, 7, 14),
      version: 'scan',
      tileTemplate:
          '/api/v1/radar/tiles/aggregate/{station}/0.5/'
          '{z}/{x}/{y}.png?timestamp=scan',
    );

    final template = api.tileTemplate(
      mode: RadarMode.aggregate,
      snapshot: snapshot,
      station: _testStation('KMAF'),
    );

    expect(template, contains('/aggregate/KMAF/0.5/'));
    expect(template, isNot(contains('/aggregate/_/')));
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
            headers: {
              'X-Radar-Cache': 'STALE',
              'X-Data-Fetched-At': '2026-07-17T23:42:10-05:00',
            },
          ),
        ),
      );

      final result = await api.fetchAlerts();

      expect(result.stale, isTrue);
      expect(result.alerts, hasLength(1));
      expect(result.checkedAt, DateTime.utc(2026, 7, 18, 4, 42, 10));
      api.close();
    },
  );

  test('alert checked-at header takes precedence over fetched-at', () async {
    final api = RadarApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient(
        (_) async => http.Response(
          _alertCollection,
          200,
          headers: {
            'X-Data-Checked-At': '2026-07-18T05:12:34.567Z',
            'X-Data-Fetched-At': '2026-07-18T05:00:00Z',
          },
        ),
      ),
    );

    final result = await api.fetchAlerts();

    expect(result.checkedAt, DateTime.utc(2026, 7, 18, 5, 12, 34, 567));
    api.close();
  });

  test('conditional alert 304 retains data and reports check time', () async {
    var request = 0;
    final api = RadarApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient((requestData) async {
        request++;
        if (request == 2) {
          expect(requestData.headers['If-None-Match'], 'W/"alerts-1"');
          return http.Response(
            '',
            304,
            headers: {
              'ETag': 'W/"alerts-1"',
              'X-Data-Checked-At': '2026-07-18T05:30:00Z',
              'X-Data-Fetched-At': '2026-07-18T05:00:00Z',
            },
          );
        }
        return http.Response(
          _alertCollection,
          200,
          headers: {
            'ETag': 'W/"alerts-1"',
            'X-Data-Checked-At': '2026-07-18T05:00:00Z',
          },
        );
      }),
    );

    final initial = await api.fetchAlerts();
    final unchanged = await api.fetchAlerts();

    expect(request, 2);
    expect(initial.changed, isTrue);
    expect(unchanged.changed, isFalse);
    expect(unchanged.alerts, same(initial.alerts));
    expect(unchanged.checkedAt, DateTime.utc(2026, 7, 18, 5, 30));
    api.close();
  });

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

RadarStation _testStation(String id) => RadarStation(
  id: id,
  name: id,
  latitude: 31.94,
  longitude: -102.19,
  reflectivityElevations: const ['0.5'],
  velocityElevations: const ['0.5'],
  supportsReflectivity: true,
  supportsVelocity: true,
);
