import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:radar_mobile/controllers/radar_controller.dart';
import 'package:radar_mobile/models/radar_models.dart';
import 'package:radar_mobile/screens/radar_map_screen.dart';
import 'package:radar_mobile/services/radar_api.dart';

void main() {
  testWidgets('elevation selection repaints while the mode panel stays open', (
    tester,
  ) async {
    final radar = RadarController(
      api: RadarApi(
        baseUrl: 'https://radar.test',
        client: MockClient(
          (_) async => http.Response('{"version":"test"}', 200),
        ),
      ),
    );
    radar.mode = RadarMode.stationReflectivity;
    radar.selectedStation = const RadarStation(
      id: 'KAAA',
      name: 'Test station',
      latitude: 40,
      longitude: -100,
      reflectivityElevations: ['0.5', '1.5'],
      velocityElevations: ['0.5'],
      supportsReflectivity: true,
      supportsVelocity: true,
    );
    radar.selectedElevation = '0.5';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RadarModePanel(radar: radar)),
      ),
    );

    await tester.tap(find.text('1.5°'));
    await tester.pump();

    final selected = tester
        .widgetList<ChoiceChip>(find.byType(ChoiceChip))
        .where((chip) => chip.selected);
    expect(selected, hasLength(1));
    expect((selected.single.label as Text).data, '1.5°');
    await tester.pumpWidget(const SizedBox.shrink());
    radar.dispose();
  });
}
