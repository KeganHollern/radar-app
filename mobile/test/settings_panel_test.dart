import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/theme/flexoki_theme.dart';
import 'package:radar_mobile/widgets/landscape_side_panel.dart';
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

  testWidgets('landscape settings use compact two-column rows', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(640, 320);
    tester.view.padding = const FakeViewPadding(
      left: 32,
      top: 8,
      right: 24,
      bottom: 16,
    );
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetPadding);

    const types = [
      'Air Quality Alert',
      'Tornado Warning',
      'Severe Thunderstorm Warning',
      'Flash Flood Warning',
      'Special Weather Statement',
      'Flood Advisory',
      'Winter Storm Warning',
      'Extreme Wind Warning',
    ];
    final visible = types.toSet();
    String? changedType;
    bool? changedVisibility;

    await tester.pumpWidget(
      MaterialApp(
        theme: Flexoki.darkTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showLandscapeSidePanel<void>(
                  context: context,
                  barrierLabel: 'Close settings',
                  builder: (context, scrollController) => RadarSettingsPanel(
                    landscape: true,
                    scrollController: scrollController,
                    alertTypes: types,
                    alertTypeCounts: const {},
                    isAlertTypeVisible: visible.contains,
                    onAlertTypeChanged: (type, isVisible) {
                      changedType = type;
                      changedVisibility = isVisible;
                    },
                    onShowAllAlertTypes: () {},
                  ),
                ),
                child: const Text('Open settings'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('landscape-side-panel')), findsOneWidget);

    final first = find.byKey(const ValueKey('alert-type-Air Quality Alert'));
    final second = find.byKey(const ValueKey('alert-type-Tornado Warning'));
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(tester.getTopLeft(first).dx, lessThan(tester.getTopLeft(second).dx));
    expect(find.text('Show all'), findsOneWidget);

    final last = find.byKey(const ValueKey('alert-type-Extreme Wind Warning'));
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('settings-alert-types-scroll')),
      matching: find.byType(Scrollable),
    );
    final position = tester.state<ScrollableState>(scrollable).position;
    await tester.drag(scrollable, Offset(0, -position.viewportDimension));
    await tester.pumpAndSettle();
    expect(last.hitTestable(), findsOneWidget);
    await tester.tap(last);
    await tester.pump();

    expect(changedType, 'Extreme Wind Warning');
    expect(changedVisibility, isFalse);
    expect(tester.takeException(), isNull);
  });
}
