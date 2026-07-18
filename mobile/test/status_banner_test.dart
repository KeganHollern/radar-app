import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/widgets/status_banner.dart';

void main() {
  testWidgets('idle banner is accessible and responds once per tap', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatusBanner(
            icon: Icons.warning_amber_rounded,
            message: 'Cached weather alerts — tap to retry',
            onTap: () => taps++,
          ),
        ),
      ),
    );

    final banner = find.byKey(const ValueKey('status-banner-action'));
    expect(tester.getSize(banner).height, greaterThanOrEqualTo(48));
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    final node = tester.getSemantics(find.byType(StatusBanner));
    final flags = node.getSemanticsData().flagsCollection;
    expect(node.label, 'Cached weather alerts — tap to retry');
    expect(flags.isButton, isTrue);
    expect(flags.isEnabled, Tristate.isTrue);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);

    await tester.tap(banner);
    expect(taps, 1);
    semantics.dispose();
  });

  testWidgets('loading banner shows progress and blocks repeated taps', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatusBanner(
            icon: Icons.warning_amber_rounded,
            message: 'Refreshing weather alerts…',
            loading: true,
            loadingSemanticLabel: 'Refreshing weather alerts',
            onTap: () => taps++,
          ),
        ),
      ),
    );

    final banner = find.byKey(const ValueKey('status-banner-action'));
    final progress = find.byKey(const ValueKey('status-banner-progress'));
    expect(progress, findsOneWidget);
    expect(tester.getSize(progress), const Size.square(18));
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);

    final node = tester.getSemantics(find.byType(StatusBanner));
    final flags = node.getSemanticsData().flagsCollection;
    expect(node.label, 'Refreshing weather alerts');
    expect(flags.isLiveRegion, isTrue);
    expect(flags.isButton, isTrue);
    expect(flags.isEnabled, Tristate.isFalse);
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);

    await tester.tap(banner);
    await tester.tap(banner);
    expect(taps, 0);
    semantics.dispose();
  });
}
