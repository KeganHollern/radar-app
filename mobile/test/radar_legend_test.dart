import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/models/radar_models.dart';
import 'package:radar_mobile/widgets/radar_legend.dart';

void main() {
  Future<void> pumpLegend(WidgetTester tester, RadarMode mode) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RadarLegend(mode: mode)),
      ),
    );
  }

  testWidgets('reflectivity legend communicates intensity and units', (
    tester,
  ) async {
    await pumpLegend(tester, RadarMode.aggregate);

    expect(find.text('REFLECTIVITY'), findsOneWidget);
    expect(find.text('dBZ'), findsOneWidget);
    expect(find.text('-20 · weak'), findsOneWidget);
    expect(find.text('70 · intense'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('radar-legend-color-bar'))).width,
      greaterThan(100),
    );
    expect(
      find.bySemanticsLabel(
        'Reflectivity color scale in dBZ, from light echoes to intense echoes.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('station reflectivity legend discloses the clutter threshold', (
    tester,
  ) async {
    await pumpLegend(tester, RadarMode.stationReflectivity);

    expect(find.text('dBZ · <15 hidden'), findsOneWidget);
    expect(find.text('15 · light'), findsOneWidget);
    expect(find.text('-20 · weak'), findsNothing);
    expect(
      find.bySemanticsLabel(
        'Station reflectivity color scale in dBZ, from light echoes to intense echoes. Weak returns below 15 dBZ are hidden.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('velocity legend explains direction relative to radar', (
    tester,
  ) async {
    await pumpLegend(tester, RadarMode.stationVelocity);

    expect(find.text('RADIAL VELOCITY'), findsOneWidget);
    expect(find.text('knots · RF = unresolved'), findsOneWidget);
    expect(find.text('RF'), findsOneWidget);
    expect(find.text('-100 · toward'), findsOneWidget);
    expect(find.text('+100 · away'), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('radar-legend-rf-swatch'))).height,
      greaterThan(0),
    );
    expect(
      find.bySemanticsLabel(
        'Radial velocity color scale in knots. Negative values mean motion toward the radar, zero is in the center, and positive values mean motion away from the radar. The separate RF swatch means range-folded or unresolved data, not a velocity value.',
      ),
      findsOneWidget,
    );
  });
}
