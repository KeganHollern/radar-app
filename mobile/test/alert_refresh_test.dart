import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radar_mobile/controllers/radar_controller.dart';
import 'package:radar_mobile/services/radar_api.dart';

void main() {
  test(
    'a user refresh during an automatic request queues one reliable retry',
    () async {
      final responses = <Completer<http.Response>>[];
      var requestCount = 0;
      final api = RadarApi(
        baseUrl: 'https://radar.lystic.dev',
        client: MockClient((request) {
          requestCount++;
          final response = Completer<http.Response>();
          responses.add(response);
          return response.future;
        }),
      );
      final controller = RadarController(
        api: api,
        alertsRefreshInterval: const Duration(hours: 1),
      );
      final loadingStates = <bool>[];
      controller.addListener(() {
        loadingStates.add(controller.isLoadingAlerts);
      });

      final automatic = controller.refreshAlerts();
      await _waitFor(() => requestCount == 1);
      expect(controller.isLoadingAlerts, isTrue);

      final manual = controller.refreshAlerts(userInitiated: true);
      final repeatTaps = List.generate(
        8,
        (_) => controller.refreshAlerts(userInitiated: true),
      );
      expect(identical(manual, automatic), isTrue);
      expect(
        repeatTaps.every((future) => identical(future, automatic)),
        isTrue,
      );

      var completedEarly = false;
      unawaited(manual.then((_) => completedEarly = true));
      responses.single.complete(
        http.Response(
          _alertCollection,
          200,
          headers: {
            'ETag': '"alerts-1"',
            'X-Data-Checked-At': '2026-07-17T14:00:00Z',
          },
        ),
      );

      await _waitFor(() => requestCount == 2);
      expect(completedEarly, isFalse);
      expect(controller.isLoadingAlerts, isTrue);

      responses.last.complete(
        http.Response(
          '',
          304,
          headers: {
            'ETag': '"alerts-1"',
            'X-Data-Checked-At': '2026-07-17T14:00:30Z',
          },
        ),
      );
      await Future.wait([automatic, manual, ...repeatTaps]);

      expect(requestCount, 2);
      expect(controller.isLoadingAlerts, isFalse);
      expect(controller.alertsError, isNull);
      expect(controller.alertsUpdatedAt, DateTime.utc(2026, 7, 17, 14, 0, 30));
      expect(loadingStates.first, isTrue);
      expect(loadingStates.last, isFalse);
      controller.dispose();
    },
  );

  test('automatic alert signals are throttled unless data is stale', () async {
    var requestCount = 0;
    final api = RadarApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient((_) async {
        requestCount++;
        return http.Response(
          _alertCollection,
          200,
          headers: {'ETag': '"alerts-$requestCount"'},
        );
      }),
    );
    final controller = RadarController(
      api: api,
      alertsRefreshInterval: const Duration(hours: 1),
    );

    await controller.refreshAlerts();
    await controller.refreshAlertsIfDue();
    expect(requestCount, 1);

    controller.alertsStale = true;
    await controller.refreshAlertsIfDue();
    expect(requestCount, 2);
    controller.dispose();
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out waiting for asynchronous test condition.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
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
