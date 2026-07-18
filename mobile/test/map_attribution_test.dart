import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/config/app_config.dart';
import 'package:radar_mobile/models/data_attribution.dart';
import 'package:radar_mobile/widgets/map_attribution.dart';

void main() {
  test('utility controls align with the default Nearby stack', () {
    expect(mapUtilityButtonDimension, greaterThanOrEqualTo(48));
    expect(mapUtilityButtonDimension * 2 + 8, 112);
  });

  testWidgets('compact source button is accessible and responds to taps', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapAttributionButton(
            credit: '© OpenStreetMap',
            onPressed: () => pressed = true,
          ),
        ),
      ),
    );

    expect(find.byIcon(Icons.info_outline_rounded), findsOneWidget);
    expect(
      find.bySemanticsLabel('© OpenStreetMap; map and weather data sources'),
      findsOneWidget,
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('map-attribution-button'))),
      const Size.square(mapUtilityButtonDimension),
    );

    await tester.tap(find.byKey(const ValueKey('map-attribution-button')));
    expect(pressed, isTrue);
    semantics.dispose();
  });

  testWidgets('attribution panel names configured map and weather providers', (
    tester,
  ) async {
    Uri? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MapAttributionPanel(
            mapAttributions: const [
              DataAttribution(
                label: 'OpenFreeMap',
                url: 'https://openfreemap.org/',
              ),
              DataAttribution(
                label: '© OpenMapTiles',
                url: 'https://openmaptiles.org/',
              ),
              DataAttribution(
                label: '© OpenStreetMap contributors',
                url: 'https://www.openstreetmap.org/copyright',
              ),
            ],
            onOpenLink: (uri) async => opened = uri,
          ),
        ),
      ),
    );

    expect(find.text('Data sources'), findsOneWidget);
    expect(find.text('OpenFreeMap'), findsOneWidget);
    expect(find.text('© OpenMapTiles'), findsOneWidget);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(find.text('NOAA / National Weather Service'), findsOneWidget);
    expect(find.text('NOAA GOES-R GLM'), findsOneWidget);
    expect(
      find.textContaining('not exact ground strikes or a proximity alarm'),
      findsOneWidget,
    );
    expect(
      find.textContaining('not affiliated with or endorsed'),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(
        const ValueKey('attribution-link-© OpenStreetMap contributors'),
      ),
    );
    await tester.pump();

    expect(opened, Uri.parse('https://www.openstreetmap.org/copyright'));
  });

  test('default map credits match the default OpenFreeMap style', () {
    expect(AppConfig.mapStyleUrl, contains('tiles.openfreemap.org'));
    expect(AppConfig.mapAttributionCompact, '© OpenStreetMap');
    expect(AppConfig.mapAttributions.map((credit) => credit.label), [
      'OpenFreeMap',
      '© OpenMapTiles',
      '© OpenStreetMap contributors',
    ]);
  });
}
