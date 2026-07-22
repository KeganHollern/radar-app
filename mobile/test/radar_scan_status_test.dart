import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/models/radar_models.dart';
import 'package:radar_mobile/widgets/radar_scan_status.dart';

void main() {
  final observedAt = DateTime(2026, 7, 22, 13, 30);
  final now = DateTime(2026, 7, 22, 13, 33);

  RadarSnapshot snapshot({bool stale = false}) => RadarSnapshot(
    observedAt: observedAt,
    version: 'scan-1330',
    tileTemplate: 'https://example.com/{z}/{x}/{y}.png',
    stale: stale,
  );

  test('live status includes rendered scan clock time and relative age', () {
    final status = radarScanStatusPresentation(
      renderedSnapshot: snapshot(),
      isLoading: false,
      unavailable: false,
      now: now,
    );

    expect(status.text, 'Scan 1:30 PM · 3m ago');
    expect(status.semanticLabel, 'Radar scan at 1:30 PM, 3 minutes ago');
  });

  test('refreshing keeps copy tied to the snapshot already rendered', () {
    final status = radarScanStatusPresentation(
      renderedSnapshot: snapshot(),
      isLoading: true,
      unavailable: false,
      now: now,
    );

    expect(status.text, 'Scan 1:30 PM · 3m ago');
  });

  test('stale and offline copy retain rendered scan time and age', () {
    final stale = radarScanStatusPresentation(
      renderedSnapshot: snapshot(stale: true),
      isLoading: false,
      unavailable: false,
      now: now,
    );
    final offline = radarScanStatusPresentation(
      renderedSnapshot: snapshot(stale: true),
      isLoading: false,
      unavailable: true,
      now: now,
    );

    expect(stale.text, 'Stale scan 1:30 PM · 3m ago');
    expect(stale.semanticLabel, 'Stale radar scan at 1:30 PM, 3 minutes ago');
    expect(offline.text, 'Last scan 1:30 PM · 3m ago');
    expect(
      offline.semanticLabel,
      'Last rendered radar scan at 1:30 PM, 3 minutes ago',
    );
  });

  test('empty status distinguishes connecting from waiting', () {
    final connecting = radarScanStatusPresentation(
      renderedSnapshot: null,
      isLoading: true,
      unavailable: false,
      now: now,
    );
    final waiting = radarScanStatusPresentation(
      renderedSnapshot: null,
      isLoading: false,
      unavailable: true,
      now: now,
    );

    expect(connecting.text, 'Connecting…');
    expect(connecting.semanticLabel, 'Connecting to live radar');
    expect(waiting.text, 'Waiting for live scan');
    expect(waiting.semanticLabel, 'Waiting for a live radar scan');
  });

  test('clock formatting handles midnight and noon', () {
    RadarScanStatusPresentation statusAt(DateTime time) =>
        radarScanStatusPresentation(
          renderedSnapshot: RadarSnapshot(
            observedAt: time,
            version: 'scan',
            tileTemplate: null,
          ),
          isLoading: false,
          unavailable: false,
          now: time,
        );

    expect(
      statusAt(DateTime(2026, 7, 22, 0, 5)).text,
      'Scan 12:05 AM · just now',
    );
    expect(
      statusAt(DateTime(2026, 7, 22, 12, 5)).text,
      'Scan 12:05 PM · just now',
    );
  });

  testWidgets('status semantics are readable and age refreshes while open', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var currentTime = now;

    await tester.pumpWidget(
      MaterialApp(
        home: RadarScanStatusText(
          renderedSnapshot: snapshot(),
          isLoading: false,
          unavailable: false,
          now: () => currentTime,
        ),
      ),
    );

    expect(find.text('Scan 1:30 PM · 3m ago'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Radar scan at 1:30 PM, 3 minutes ago'),
      findsOneWidget,
    );

    currentTime = DateTime(2026, 7, 22, 13, 34);
    await tester.pump(const Duration(seconds: 10));

    expect(find.text('Scan 1:30 PM · 4m ago'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Radar scan at 1:30 PM, 4 minutes ago'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });
}
