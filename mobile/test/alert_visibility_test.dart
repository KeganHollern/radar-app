import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radar_mobile/controllers/radar_controller.dart';
import 'package:radar_mobile/services/alert_visibility_store.dart';
import 'package:radar_mobile/services/radar_api.dart';

void main() {
  test(
    'persisted alert type visibility filters count and map together',
    () async {
      final store = _MemoryVisibilityStore(
        const AlertVisibilityPreferences(
          hiddenTypes: {'air quality alert'},
          knownTypes: {'Air Quality Alert'},
        ),
      );
      final api = RadarApi(
        baseUrl: 'https://radar.lystic.dev',
        client: MockClient((_) async => http.Response(_alerts, 200)),
      );
      final controller = RadarController(api: api, alertVisibilityStore: store);

      await controller.loadAlertVisibility();
      await controller.refreshAlerts();

      expect(controller.allAlerts, hasLength(2));
      expect(controller.alerts.map((alert) => alert.event), [
        'Tornado Warning',
      ]);
      expect(controller.knownAlertTypes, [
        'Air Quality Alert',
        'Tornado Warning',
      ]);
      expect(controller.alertTypeCounts['Air Quality Alert'], 1);
      expect(controller.alertTypeCounts['Tornado Warning'], 1);
      expect(
        (controller.alertGeoJson['features'] as List).map(
          (feature) => feature['id'],
        ),
        ['tornado'],
      );
      final originalTornadoFeature =
          (controller.alertGeoJson['features'] as List).single;

      final revision = controller.alertRevision;
      controller.setAlertTypeVisible('Air Quality Alert', true);
      await Future<void>.delayed(Duration.zero);

      expect(controller.alerts, hasLength(2));
      expect(controller.alertGeoJson['features'], hasLength(2));
      expect(
        (controller.alertGeoJson['features'] as List).last,
        same(originalTornadoFeature),
      );
      expect(controller.alertRevision, revision + 1);
      expect(store.saved.hiddenTypes, isEmpty);
      controller.dispose();
    },
  );
}

final class _MemoryVisibilityStore implements AlertVisibilityStore {
  _MemoryVisibilityStore(this.saved);

  AlertVisibilityPreferences saved;

  @override
  Future<AlertVisibilityPreferences> load() async => saved;

  @override
  Future<void> save({
    required Set<String> hiddenTypes,
    required Set<String> knownTypes,
  }) async {
    saved = AlertVisibilityPreferences(
      hiddenTypes: Set.of(hiddenTypes),
      knownTypes: Set.of(knownTypes),
    );
  }
}

const _alerts = '''
{
  "type": "FeatureCollection",
  "features": [
    {
      "type": "Feature",
      "id": "air-quality",
      "properties": {"event": "Air Quality Alert"},
      "geometry": {
        "type": "Polygon",
        "coordinates": [[[-94, 41], [-93, 41], [-93, 42], [-94, 41]]]
      }
    },
    {
      "type": "Feature",
      "id": "tornado",
      "properties": {"event": "Tornado Warning"},
      "geometry": {
        "type": "Polygon",
        "coordinates": [[[-95, 40], [-94, 40], [-94, 41], [-95, 40]]]
      }
    }
  ]
}
''';
