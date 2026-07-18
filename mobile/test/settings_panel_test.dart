import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/theme/flexoki_theme.dart';
import 'package:radar_mobile/widgets/alert_type_picker.dart';
import 'package:radar_mobile/widgets/landscape_side_panel.dart';
import 'package:radar_mobile/widgets/settings_panel.dart';

void main() {
  testWidgets('landing page drills into grouped lazy map alert pickers', (
    tester,
  ) async {
    final visible = <String>{'Air Quality Alert', 'Tornado Warning'};
    String? changedType;
    bool? changedVisibility;

    await tester.pumpWidget(
      MaterialApp(
        theme: Flexoki.darkTheme,
        home: Scaffold(
          body: RadarSettingsPanel(
            alertTypes: const [
              'Air Quality Alert',
              'Tornado Warning',
              'Unrecognized Local Statement',
            ],
            alertTypeCounts: const {
              'Air Quality Alert': 3,
              'Tornado Warning': 1,
            },
            isAlertTypeVisible: visible.contains,
            onAlertTypeChanged: (type, isVisible) {
              changedType = type;
              changedVisibility = isVisible;
              isVisible ? visible.add(type) : visible.remove(type);
            },
            onShowAllAlertTypes: () => visible.addAll(const [
              'Air Quality Alert',
              'Tornado Warning',
              'Unrecognized Local Statement',
            ]),
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('settings-page-home')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-destination-map-alerts')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('alert-type-Air Quality Alert')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('settings-destination-map-alerts')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('map-alert-category-heat-fire-air')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('map-alert-category-storms-wind')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('map-alert-category-other')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const ValueKey('map-alert-category-heat-fire-air')),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('alert-type-Air Quality Alert')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('alert-type-Tornado Warning')),
      findsNothing,
    );
    expect(find.text('3 active alerts'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('alert-type-Air Quality Alert')),
    );
    await tester.pumpAndSettle();

    expect(changedType, 'Air Quality Alert');
    expect(changedVisibility, isFalse);
    expect(visible, isNot(contains('Air Quality Alert')));

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-page-map-alerts')),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-page-home')), findsOneWidget);
  });

  testWidgets('map alert Show all lives inside its submenu', (tester) async {
    final visible = <String>{'Tornado Warning'};
    await tester.pumpWidget(
      MaterialApp(
        theme: Flexoki.darkTheme,
        home: Scaffold(
          body: RadarSettingsPanel(
            alertTypes: const ['Air Quality Alert', 'Tornado Warning'],
            alertTypeCounts: const {},
            isAlertTypeVisible: visible.contains,
            onAlertTypeChanged: (type, shown) =>
                shown ? visible.add(type) : visible.remove(type),
            onShowAllAlertTypes: () =>
                visible.addAll(const ['Air Quality Alert', 'Tornado Warning']),
          ),
        ),
      ),
    );

    expect(find.text('Show all'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('settings-destination-map-alerts')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Show all'), findsOneWidget);

    await tester.tap(find.text('Show all'));
    await tester.pump();
    expect(visible, containsAll(['Air Quality Alert', 'Tornado Warning']));
    expect(
      tester
          .widget<TextButton>(
            find.byKey(const ValueKey('show-all-map-alert-types')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('generic destinations plug into the landing page and go back', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Flexoki.darkTheme,
        home: Scaffold(
          body: RadarSettingsPanel(
            alertTypes: const [],
            alertTypeCounts: const {},
            isAlertTypeVisible: (_) => true,
            onAlertTypeChanged: (_, _) {},
            onShowAllAlertTypes: () {},
            additionalDestinations: [
              RadarSettingsDestination(
                id: 'map-layers',
                icon: Icons.layers_outlined,
                title: 'Map layers',
                summary: () => '1 layer shown',
                pageBuilder: (context, controller, onBack) => ListView(
                  controller: controller,
                  children: [
                    SettingsPageHeader(title: 'Map layers', onBack: onBack),
                    const Text('Layer controls'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(
      find.byKey(const ValueKey('settings-destination-map-layers')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Layer controls'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-page-home')), findsOneWidget);
  });

  testWidgets('generic destination can be opened directly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: Flexoki.darkTheme,
        home: Scaffold(
          body: RadarSettingsPanel(
            alertTypes: const [],
            alertTypeCounts: const {},
            isAlertTypeVisible: (_) => true,
            onAlertTypeChanged: (_, _) {},
            onShowAllAlertTypes: () {},
            initialDestinationId: 'layers',
            additionalDestinations: [
              RadarSettingsDestination(
                id: 'layers',
                icon: Icons.layers_outlined,
                title: 'Map layers',
                summary: () => 'Lightning off',
                pageBuilder: (context, scrollController, onBack) => ListView(
                  controller: scrollController,
                  children: [
                    SettingsPageHeader(title: 'Map layers', onBack: onBack),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('settings-page-home')), findsNothing);
    expect(find.text('Map layers'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-page-home')), findsOneWidget);
  });

  testWidgets('landscape settings stay scrollable and swipe dismissible', (
    tester,
  ) async {
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
      'Tornado Warning',
      'Severe Thunderstorm Warning',
      'Extreme Wind Warning',
      'High Wind Warning',
      'Dust Storm Warning',
      'Hail Warning',
      'Damaging Wind Statement',
      'Strong Wind Advisory',
    ];
    final visible = types.toSet();
    String? changedType;

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
                      isVisible ? visible.add(type) : visible.remove(type);
                    },
                    onShowAllAlertTypes: () => visible.addAll(types),
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
    await tester.tap(
      find.byKey(const ValueKey('settings-destination-map-alerts')),
    );
    await tester.pumpAndSettle();
    final category = find.byKey(
      const ValueKey('map-alert-category-storms-wind'),
    );
    await tester.drag(
      find.byKey(const ValueKey('settings-page-map-alerts')),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(category);
    await tester.tap(category);
    await tester.pumpAndSettle();

    final last = find.byKey(const ValueKey('alert-type-Strong Wind Advisory'));
    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, -900),
      1200,
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(last), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(last.hitTestable(), findsOneWidget);
    await tester.tap(last);
    await tester.pumpAndSettle();
    expect(changedType, 'Strong Wind Advisory');

    final panel = find.byKey(const ValueKey('landscape-side-panel'));
    await tester.drag(panel, const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tester.takeException(), isNull);
  });
}
