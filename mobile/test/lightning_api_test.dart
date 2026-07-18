import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radar_mobile/models/lightning_models.dart';
import 'package:radar_mobile/services/lightning_api.dart';

void main() {
  test(
    'fetchLatest sends validated bbox and parses the backend envelope',
    () async {
      Uri? requested;
      final api = LightningApi(
        baseUrl: 'https://radar.lystic.dev/',
        client: MockClient((request) async {
          requested = request.url;
          return http.Response(jsonEncode(_envelope('generation-1')), 200);
        }),
      );

      final snapshot = await api.fetchLatest(
        bounds: LightningBounds(west: -100, south: 25, east: -90, north: 35),
      );

      expect(requested?.path, '/api/v1/lightning/latest');
      expect(
        requested?.queryParameters['bbox'],
        '-100.0000,25.0000,-90.0000,35.0000',
      );
      expect(snapshot.generation, 'generation-1');
      expect(snapshot.strikes.single.id, 'flash-generation-1');
      api.close();
    },
  );

  test(
    'SSE supports snapshots, full lightning generations, and resume id',
    () async {
      String? lastEventId;
      final sse = [
        ': heartbeat',
        'event: snapshot',
        'id: generation-1',
        'data: ${jsonEncode(_envelope('generation-1'))}',
        '',
        'event: lightning',
        'id: generation-2',
        'data: ${jsonEncode(_envelope('generation-2'))}',
        '',
        'event: lightning',
        'data: not-json',
        '',
      ].join('\n');
      final api = LightningApi(
        baseUrl: 'https://radar.lystic.dev',
        client: MockClient((request) async {
          lastEventId = request.headers['Last-Event-ID'];
          return http.Response(
            sse,
            200,
            headers: {'Content-Type': 'text/event-stream'},
          );
        }),
      );

      final updates = await api
          .watchUpdates(lastEventId: 'previous-generation')
          .toList();

      expect(lastEventId, 'previous-generation');
      expect(updates, hasLength(2));
      expect(updates.first.event, LightningStreamEvent.snapshot);
      expect(updates.first.id, 'generation-1');
      expect(updates.last.event, LightningStreamEvent.lightning);
      expect(updates.last.snapshot?.generation, 'generation-2');
      api.close();
    },
  );

  test('unavailable responses retain status for settings recovery', () async {
    final api = LightningApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient(
        (_) async => http.Response(
          '{"error":{"message":"Lightning source is disabled"}}',
          503,
        ),
      ),
    );

    await expectLater(
      api.fetchLatest(),
      throwsA(
        isA<LightningApiException>()
            .having((error) => error.statusCode, 'statusCode', 503)
            .having(
              (error) => error.indicatesUnavailable,
              'indicatesUnavailable',
              isTrue,
            ),
      ),
    );
    api.close();
  });

  test('a stalled SSE connection times out so it can reconnect', () async {
    final body = StreamController<List<int>>();
    final api = LightningApi(
      baseUrl: 'https://radar.lystic.dev',
      streamIdleTimeout: const Duration(milliseconds: 30),
      client: MockClient.streaming(
        (_, _) async => http.StreamedResponse(
          body.stream,
          200,
          headers: {'Content-Type': 'text/event-stream'},
        ),
      ),
    );

    await expectLater(
      api.watchUpdates().drain<void>(),
      throwsA(
        isA<LightningApiException>().having(
          (error) => error.message,
          'message',
          contains('stopped responding'),
        ),
      ),
    );

    await body.close();
    api.close();
  });
}

Map<String, dynamic> _envelope(String generation) => {
  'schemaVersion': '1',
  'mode': 'event',
  'generation': generation,
  'observedAt': '2026-07-18T12:00:00Z',
  'checkedAt': '2026-07-18T12:00:20Z',
  'stale': false,
  'attribution': 'NOAA GOES-R GLM',
  'retentionMs': 30000,
  'data': {
    'type': 'FeatureCollection',
    'features': [
      {
        'type': 'Feature',
        'id': 'flash-$generation',
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
      },
    ],
  },
};
