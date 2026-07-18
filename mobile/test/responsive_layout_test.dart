import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/controllers/radar_controller.dart';
import 'package:radar_mobile/models/radar_models.dart';
import 'package:radar_mobile/screens/radar_map_screen.dart';
import 'package:radar_mobile/theme/flexoki_theme.dart';
import 'package:radar_mobile/widgets/landscape_side_panel.dart';
import 'package:radar_mobile/widgets/responsive_map_chrome.dart';

void main() {
  testWidgets('portrait map chrome keeps the approved top and bottom layout', (
    tester,
  ) async {
    await _pumpChrome(tester, const Size(412, 915));

    expect(find.byKey(const ValueKey('portrait-map-chrome')), findsOneWidget);
    expect(find.byKey(const ValueKey('landscape-map-chrome')), findsNothing);
    expect(find.byKey(const ValueKey('settings-control')), findsNothing);

    final status = tester.getRect(find.byKey(const ValueKey('status-control')));
    final legend = tester.getRect(find.byKey(const ValueKey('legend-control')));
    final radar = tester.getRect(find.byKey(const ValueKey('radar-control')));
    final info = tester.getRect(find.byKey(const ValueKey('info-control')));
    final pin = tester.getRect(find.byKey(const ValueKey('pin-control')));

    expect(status.top, lessThan(40));
    expect(legend.top, lessThan(radar.top));
    expect(info.top, lessThan(pin.top));
    expect(radar.bottom, greaterThan(800));
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(915, 412),
    const Size(640, 320),
    const Size(568, 320),
  ]) {
    testWidgets('landscape map chrome uses safe side rails at $size', (
      tester,
    ) async {
      await _pumpChrome(tester, size, textScaleFactor: 1.3);

      expect(find.byKey(const ValueKey('portrait-map-chrome')), findsNothing);
      expect(
        find.byKey(const ValueKey('landscape-map-chrome')),
        findsOneWidget,
      );

      final left = tester.getRect(
        find.byKey(const ValueKey('landscape-status-rail')),
      );
      final right = tester.getRect(
        find.byKey(const ValueKey('landscape-controls-rail')),
      );
      expect(right.left - left.right, greaterThanOrEqualTo(100));
      expect(right.right, lessThanOrEqualTo(size.width - 8));
      expect(left.left, greaterThanOrEqualTo(8));

      for (final key in const [
        'settings-control',
        'info-control',
        'pin-control',
      ]) {
        final finder = find.byKey(ValueKey(key));
        expect(finder, findsOneWidget);
        expect(finder.hitTestable(), findsOneWidget);
        expect(tester.getSize(finder), const Size.square(52));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('landscape radar panel exposes every primary mode', (
    tester,
  ) async {
    await _setSurfaceSize(
      tester,
      const Size(640, 320),
      padding: const FakeViewPadding(left: 32, top: 8, right: 24, bottom: 16),
    );
    final radar = RadarController();
    addTearDown(radar.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: Flexoki.darkTheme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showLandscapeSidePanel<void>(
                  context: context,
                  barrierLabel: 'Close live radar controls',
                  builder: (context, scrollController) => RadarModePanel(
                    radar: radar,
                    scrollController: scrollController,
                  ),
                ),
                child: const Text('Open radar controls'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open radar controls'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('landscape-side-panel')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('landscape-side-panel')),
        matching: find.byType(Divider),
      ),
      findsNothing,
    );
    final panel = tester.getRect(
      find.byKey(const ValueKey('landscape-side-panel')),
    );
    expect(panel.top, greaterThanOrEqualTo(8));
    expect(panel.right, lessThanOrEqualTo(640 - 24));
    expect(panel.bottom, lessThanOrEqualTo(320 - 16));
    expect(
      tester.getSize(find.byKey(const ValueKey('landscape-side-panel-close'))),
      const Size.square(48),
    );
    expect(find.byKey(const ValueKey('radar-mode-panel')), findsOneWidget);
    for (final key in const [
      'mode-nearby',
      'mode-station-reflectivity',
      'mode-station-velocity',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget);
      expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const ValueKey('mode-station-reflectivity')));
    await tester.pumpAndSettle();
    expect(radar.mode, RadarMode.stationReflectivity);
    expect(find.byKey(const ValueKey('landscape-side-panel')), findsNothing);
  });
}

Future<void> _pumpChrome(
  WidgetTester tester,
  Size size, {
  double textScaleFactor = 1,
}) async {
  await _setSurfaceSize(tester, size);
  Widget control(String key, double height, Color color) {
    return SizedBox(
      key: ValueKey(key),
      width: double.infinity,
      height: height,
      child: ColoredBox(color: color),
    );
  }

  Widget utility(String key) {
    return SizedBox.square(
      key: ValueKey(key),
      dimension: 52,
      child: const ColoredBox(color: Flexoki.base100),
    );
  }

  await tester.pumpWidget(
    MaterialApp(
      theme: Flexoki.darkTheme,
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
          textScaler: TextScaler.linear(textScaleFactor),
        ),
        child: Scaffold(
          body: ResponsiveMapChrome(
            status: control('status-control', 82, Flexoki.base50),
            statusBanners: [control('status-banner', 48, Flexoki.base100)],
            legend: control('legend-control', 64, Flexoki.base50),
            radarControls: control('radar-control', 96, Flexoki.base50),
            settingsButton: utility('settings-control'),
            attributionButton: utility('info-control'),
            pinButton: utility('pin-control'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _setSurfaceSize(
  WidgetTester tester,
  Size size, {
  FakeViewPadding padding = FakeViewPadding.zero,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.view.padding = padding;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetPadding);
}
