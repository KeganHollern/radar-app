import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/controllers/lightning_controller.dart';
import 'package:radar_mobile/models/lightning_models.dart';
import 'package:radar_mobile/services/lightning_api.dart';
import 'package:radar_mobile/services/lightning_visibility_store.dart';
import 'package:radar_mobile/theme/flexoki_theme.dart';
import 'package:radar_mobile/widgets/lightning_settings.dart';

void main() {
  testWidgets('map layers explains and enables foreground lightning', (
    tester,
  ) async {
    final api = _LightningApi();
    final store = _LightningStore();
    final controller = LightningController(api: api, store: store);
    await controller.initialize();
    await controller.setBounds(
      LightningBounds(west: -110, south: 20, east: -90, north: 40),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: Flexoki.darkTheme,
        home: Scaffold(
          body: LightningSettingsPage(controller: controller, onBack: () {}),
        ),
      ),
    );

    expect(find.text('Map layers'), findsOneWidget);
    expect(find.textContaining('not exact ground strikes'), findsOneWidget);
    expect(lightningSettingsSummary(controller), 'Off');

    await tester.tap(find.byKey(const ValueKey('lightning-layer-toggle')));
    await tester.pumpAndSettle();

    expect(store.enabled, isTrue);
    expect(api.latestCalls, 1);
    expect(api.watchCalls, 1);
    expect(controller.status, LightningStatus.live);
    expect(lightningSettingsSummary(controller), 'On · live');
  });
}

final class _LightningStore implements LightningVisibilityStore {
  bool enabled = false;

  @override
  Future<bool> load() async => enabled;

  @override
  Future<void> save(bool enabled) async => this.enabled = enabled;
}

final class _LightningApi implements LightningDataSource {
  final StreamController<LightningUpdate> updates =
      StreamController<LightningUpdate>.broadcast();
  int latestCalls = 0;
  int watchCalls = 0;

  @override
  Future<LightningSnapshot> fetchLatest({LightningBounds? bounds}) async {
    latestCalls++;
    return const LightningSnapshot(
      mode: LightningSourceMode.event,
      generation: 'empty-live-generation',
      strikes: [],
    );
  }

  @override
  Stream<LightningUpdate> watchUpdates({
    LightningBounds? bounds,
    String? lastEventId,
  }) {
    watchCalls++;
    return updates.stream;
  }

  @override
  void close() => unawaited(updates.close());
}
