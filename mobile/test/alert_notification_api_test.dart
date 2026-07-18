import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radar_mobile/models/alert_notification_models.dart';
import 'package:radar_mobile/services/alert_notification_api.dart';

void main() {
  test('nearby checks send only a rounded point to the radar API', () async {
    Uri? requested;
    final api = HttpAlertNotificationApi(
      baseUrl: 'https://radar.lystic.dev/',
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(_alerts, 200);
      }),
    );

    final result = await api.fetchActiveAlerts(
      scope: AlertNotificationScope.nearby,
      point: AlertNotificationPoint(
        latitude: 30.267153,
        longitude: -97.743057,
        observedAt: DateTime.utc(2026, 7, 17),
      ),
    );

    expect(requested?.path, '/api/v1/alerts');
    expect(requested?.queryParameters, {'point': '30.267,-97.743'});
    expect(result.alerts.single.id, 'test-alert');
    api.close();
  });

  test('nationwide checks never include a location query', () async {
    Uri? requested;
    final api = HttpAlertNotificationApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient((request) async {
        requested = request.url;
        return http.Response(_alerts, 200);
      }),
    );

    await api.fetchActiveAlerts(scope: AlertNotificationScope.nationwide);

    expect(requested?.query, isEmpty);
    api.close();
  });

  test('server failures are classified for WorkManager retry', () async {
    final api = HttpAlertNotificationApi(
      baseUrl: 'https://radar.lystic.dev',
      client: MockClient((_) async => http.Response('', 503)),
    );

    await expectLater(
      api.fetchActiveAlerts(scope: AlertNotificationScope.nationwide),
      throwsA(
        isA<AlertNotificationApiException>().having(
          (error) => error.transient,
          'transient',
          isTrue,
        ),
      ),
    );
    api.close();
  });

  test('unchanged nationwide checks use ETag and skip body decoding', () async {
    final state = _MemoryRequestStateStore();
    var requests = 0;
    final api = HttpAlertNotificationApi(
      baseUrl: 'https://radar.lystic.dev',
      requestStateStore: state,
      client: MockClient((request) async {
        requests++;
        if (requests == 1) {
          expect(request.headers, isNot(contains('If-None-Match')));
          return http.Response(_alerts, 200, headers: {'etag': '"alerts-v1"'});
        }
        expect(request.headers['If-None-Match'], '"alerts-v1"');
        return http.Response('not json', 304);
      }),
    );

    final first = await api.fetchActiveAlerts(
      scope: AlertNotificationScope.nationwide,
    );
    expect(first.alerts, hasLength(1));
    expect(state.state, isNull);
    await api.acknowledge(first);
    expect(state.state?.etag, '"alerts-v1"');

    final second = await api.fetchActiveAlerts(
      scope: AlertNotificationScope.nationwide,
    );
    expect(second.notModified, isTrue);
    expect(second.alerts, isEmpty);
    expect(requests, 2);
    api.close();
  });

  test('nearby checks never persist or send a conditional validator', () async {
    final state = _MemoryRequestStateStore()
      ..state = const AlertNotificationRequestState(etag: '"national"');
    final api = HttpAlertNotificationApi(
      baseUrl: 'https://radar.lystic.dev',
      requestStateStore: state,
      client: MockClient((request) async {
        expect(request.headers, isNot(contains('If-None-Match')));
        return http.Response(_alerts, 200, headers: {'etag': '"nearby"'});
      }),
    );

    final result = await api.fetchActiveAlerts(
      scope: AlertNotificationScope.nearby,
      point: AlertNotificationPoint(
        latitude: 30.267153,
        longitude: -97.743057,
        observedAt: DateTime.utc(2026, 7, 17),
      ),
    );
    await api.acknowledge(result);

    expect(state.state?.etag, '"national"');
    api.close();
  });

  test('bypassing cache forces a full nationwide response', () async {
    final state = _MemoryRequestStateStore()
      ..state = const AlertNotificationRequestState(etag: '"old"');
    final api = HttpAlertNotificationApi(
      baseUrl: 'https://radar.lystic.dev',
      requestStateStore: state,
      client: MockClient((request) async {
        expect(request.headers, isNot(contains('If-None-Match')));
        return http.Response(_alerts, 200, headers: {'etag': '"new"'});
      }),
    );

    final result = await api.fetchActiveAlerts(
      scope: AlertNotificationScope.nationwide,
      bypassCache: true,
    );
    expect(result.alerts, hasLength(1));
    await api.acknowledge(result);
    expect(state.state?.etag, '"new"');
    api.close();
  });

  test('invalid alert bodies do not advance the saved ETag', () async {
    final state = _MemoryRequestStateStore()
      ..state = const AlertNotificationRequestState(etag: '"old"');
    final api = HttpAlertNotificationApi(
      baseUrl: 'https://radar.lystic.dev',
      requestStateStore: state,
      client: MockClient(
        (_) async => http.Response(
          '{"type":"FeatureCollection"}',
          200,
          headers: {'etag': '"uncommitted"'},
        ),
      ),
    );

    await expectLater(
      api.fetchActiveAlerts(
        scope: AlertNotificationScope.nationwide,
        bypassCache: true,
      ),
      throwsA(isA<AlertNotificationApiException>()),
    );
    expect(state.state?.etag, '"old"');
    api.close();
  });
}

final class _MemoryRequestStateStore
    implements AlertNotificationRequestStateStore {
  AlertNotificationRequestState? state;

  @override
  Future<AlertNotificationRequestState?> load() async => state;

  @override
  Future<void> save(AlertNotificationRequestState value) async {
    state = value;
  }
}

const _alerts = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "id": "test-alert",
      "properties": {
        "event": "Tornado Warning",
        "headline": "Test warning"
      },
      "geometry": null
    }
  ]
}
''';
