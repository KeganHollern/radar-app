import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/widgets/settings_panel.dart';

void main() {
  testWidgets('each alert type has an independent visibility switch', (
    tester,
  ) async {
    final visible = <String>{'Air Quality Alert', 'Tornado Warning'};
    String? changedType;
    bool? changedVisibility;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RadarSettingsPanel(
            alertTypes: const ['Air Quality Alert', 'Tornado Warning'],
            alertTypeCounts: const {
              'Air Quality Alert': 3,
              'Tornado Warning': 1,
            },
            isAlertTypeVisible: visible.contains,
            onAlertTypeChanged: (type, isVisible) {
              changedType = type;
              changedVisibility = isVisible;
            },
            onShowAllAlertTypes: () {},
          ),
        ),
      ),
    );

    expect(find.text('3 active alerts'), findsOneWidget);
    expect(find.text('1 active alert'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('alert-type-Air Quality Alert')),
    );
    await tester.pump();

    expect(changedType, 'Air Quality Alert');
    expect(changedVisibility, isFalse);
  });
}
