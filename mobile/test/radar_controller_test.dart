import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:radar_mobile/controllers/radar_controller.dart';
import 'package:radar_mobile/models/radar_models.dart';
import 'package:radar_mobile/services/alert_visibility_store.dart';
import 'package:radar_mobile/services/radar_api.dart';

void main() {
  for (final failed in [false, true]) {
    test(
      'a delayed HTTP ${failed ? 'failure' : 'scan'} preserves newer SSE',
      () async {
        final client = _RadarClient();
        final pending = Completer<http.Response>();
        client.latest = (_) => pending.future;
        final controller = _controller(client);
        addTearDown(controller.dispose);
        controller.selectStation(RadarStation.fromJson(_station()));
        await pumpEventQueue();

        client.emit(_snapshot('live', 12));
        await pumpEventQueue();
        expect(controller.snapshot?.version, 'live');

        pending.complete(
          failed
              ? http.Response('{"error":"unavailable"}', 503)
              : http.Response(jsonEncode(_snapshot('old-http', 10)), 200),
        );
        await pumpEventQueue();

        expect(controller.snapshot?.version, 'live');
        expect(controller.radarError, isNull);
        expect(controller.isLoadingRadar, isFalse);
      },
    );
  }

  test('an older stream event cannot replace the HTTP scan', () async {
    final client = _RadarClient();
    final controller = _controller(client);
    addTearDown(controller.dispose);
    controller.selectStation(RadarStation.fromJson(_station()));
    await pumpEventQueue();
    final current = controller.snapshot;

    client.emit(_snapshot('old-stream', 10));
    await pumpEventQueue();

    expect(controller.snapshot, same(current));
  });

  test('newer HTTP scans still replace a concurrent stream scan', () async {
    final client = _RadarClient();
    final pending = Completer<http.Response>();
    client.latest = (_) => pending.future;
    final controller = _controller(client);
    addTearDown(controller.dispose);
    controller.selectStation(RadarStation.fromJson(_station()));
    await pumpEventQueue();

    client.emit(_snapshot('stream', 12));
    await pumpEventQueue();
    pending.complete(http.Response(jsonEncode(_snapshot('http', 13)), 200));
    await pumpEventQueue();

    expect(controller.snapshot?.version, 'http');
  });

  test(
    'aggregate generations can restore an older contributing scan',
    () async {
      final client = _RadarClient();
      final controller = _controller(client);
      addTearDown(controller.dispose);
      await controller.resume();
      await pumpEventQueue();

      client.latest = (_) async =>
          http.Response(jsonEncode(_snapshot('restored-http', 11)), 200);
      await controller.refreshRadar();
      expect(controller.snapshot?.version, 'restored-http');

      client.emit(_snapshot('restored-stream', 10));
      await pumpEventQueue();
      expect(controller.snapshot?.version, 'restored-stream');
    },
  );

  test(
    'aggregate stream changes supersede an in-flight HTTP generation',
    () async {
      final client = _RadarClient();
      final controller = _controller(client);
      addTearDown(controller.dispose);
      await controller.resume();
      await pumpEventQueue();
      final pending = Completer<http.Response>();
      client.latest = (_) => pending.future;
      final refresh = controller.refreshRadar();

      client.emit(_snapshot('restored-region', 10));
      await pumpEventQueue();
      pending.complete(
        http.Response(jsonEncode(_snapshot('old-partial', 12)), 200),
      );
      await refresh;
      expect(controller.snapshot?.version, 'restored-region');
    },
  );

  test('catalog elevation changes replace both manifest and stream', () async {
    final client = _RadarClient();
    final controller = _controller(client);
    addTearDown(controller.dispose);
    await controller.refreshStations();
    controller.selectStationById('KAAA');
    await pumpEventQueue();
    expect(controller.selectedElevation, '0.5');

    client.stations = [_station(elevation: '1.5')];
    await controller.refreshStations();
    await pumpEventQueue();

    expect(controller.selectedElevation, '1.5');
    expect(client.latestRequests.last.queryParameters['elevation'], '1.5');
    expect(client.updateRequests.last.queryParameters['elevation'], '1.5');
    expect(controller.snapshot?.version, 'reflectivity-1.5');
  });

  test('catalog removal clears selected radar and stops its stream', () async {
    final client = _RadarClient();
    final controller = _controller(client);
    addTearDown(controller.dispose);
    await controller.refreshStations();
    controller.selectStationById('KAAA');
    await pumpEventQueue();
    expect(client.streams.single.hasListener, isTrue);

    client.stations = [];
    await controller.refreshStations();
    await pumpEventQueue();

    expect(controller.selectedStation, isNull);
    expect(controller.snapshot, isNull);
    expect(controller.radarError, 'Select a radar station on the map.');
    expect(client.streams.single.hasListener, isFalse);
  });

  test(
    'catalog capability removal switches velocity to reflectivity',
    () async {
      final client = _RadarClient();
      final controller = _controller(client);
      addTearDown(controller.dispose);
      await controller.refreshStations();
      controller.selectStationById('KAAA');
      await pumpEventQueue();
      controller.selectMode(RadarMode.stationVelocity);
      await pumpEventQueue();

      client.stations = [_station(velocity: false)];
      await controller.refreshStations();
      await pumpEventQueue();

      expect(controller.mode, RadarMode.stationReflectivity);
      expect(
        client.latestRequests.last.queryParameters['product'],
        'reflectivity',
      );
      expect(
        client.updateRequests.last.queryParameters['product'],
        'reflectivity',
      );
    },
  );

  testWidgets('disposal during preference load does not start timers', (
    tester,
  ) async {
    final store = _DelayedVisibilityStore();
    final client = _RadarClient();
    final controller = RadarController(
      api: RadarApi(baseUrl: 'https://radar.test', client: client),
      alertVisibilityStore: store,
    );
    final initialization = controller.initialize();
    controller.dispose();
    store.loaded.complete(const AlertVisibilityPreferences());
    await initialization;
    expect(client.latestRequests, isEmpty);
    expect(client.updateRequests, isEmpty);
    // Flutter verifies that no periodic timer remains after this widget test.
  });
}

RadarController _controller(_RadarClient client) => RadarController(
  api: RadarApi(baseUrl: 'https://radar.test', client: client),
);

Map<String, dynamic> _station({
  String elevation = '0.5',
  bool velocity = true,
}) => {
  'id': 'KAAA',
  'name': 'Test station',
  'latitude': 40,
  'longitude': -100,
  'supports_reflectivity': true,
  'supports_velocity': velocity,
  'reflectivity_elevations': [elevation],
  'velocity_elevations': velocity ? [elevation] : [],
};

Map<String, dynamic> _snapshot(String version, int hour) => {
  'observedAt': DateTime.utc(2026, 9, 6, hour).toIso8601String(),
  'version': version,
};

final class _RadarClient extends http.BaseClient {
  List<Map<String, dynamic>> stations = [_station()];
  final latestRequests = <Uri>[];
  final updateRequests = <Uri>[];
  final streams = <StreamController<List<int>>>[];
  Future<http.Response> Function(Uri)? latest;

  void emit(Map<String, dynamic> snapshot) {
    streams.last.add(
      utf8.encode(
        'event: radar\ndata: ${jsonEncode({'radar': snapshot, 'radarChanged': true})}\n\n',
      ),
    );
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final uri = request.url;
    if (uri.path == '/api/v1/updates') {
      updateRequests.add(uri);
      final stream = StreamController<List<int>>();
      streams.add(stream);
      return http.StreamedResponse(stream.stream, 200);
    }
    final http.Response response;
    if (uri.path == '/api/v1/stations') {
      response = http.Response(jsonEncode({'stations': stations}), 200);
    } else if (uri.path == '/api/v1/radar/latest') {
      latestRequests.add(uri);
      response = latest == null
          ? http.Response(
              jsonEncode(
                _snapshot(
                  '${uri.queryParameters['product']}-${uri.queryParameters['elevation']}',
                  12,
                ),
              ),
              200,
            )
          : await latest!(uri);
    } else {
      response = http.Response('{"features":[]}', 200);
    }
    return http.StreamedResponse(
      Stream.value(response.bodyBytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() {
    for (final stream in streams) {
      unawaited(stream.close());
    }
  }
}

final class _DelayedVisibilityStore implements AlertVisibilityStore {
  final loaded = Completer<AlertVisibilityPreferences>();

  @override
  Future<AlertVisibilityPreferences> load() => loaded.future;

  @override
  Future<void> save({
    required Set<String> hiddenTypes,
    required Set<String> knownTypes,
  }) async {}
}
