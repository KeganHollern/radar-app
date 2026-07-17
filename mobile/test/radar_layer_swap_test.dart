import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/controllers/radar_layer_swap.dart';

void main() {
  test('first snapshot installs directly into the primary slot', () {
    final swaps = RadarLayerSwapCoordinator();

    final transition = swaps.reconcile(key: 'nearby:one', resampling: 'linear');

    expect(transition.kind, RadarLayerTransitionKind.install);
    expect(transition.candidate?.slot, RadarLayerSlot.primary);
    expect(transition.candidate?.sourceId, 'live-radar-source-primary');
    expect(transition.candidate?.layerId, 'live-radar-layer-primary');
    expect(transition.retired, isEmpty);
    expect(swaps.active?.key, 'nearby:one');
    expect(swaps.pending, isNull);
  });

  test('new snapshot stages in the other slot without retiring active', () {
    final swaps = RadarLayerSwapCoordinator()
      ..reconcile(key: 'nearby:one', resampling: 'linear');

    final transition = swaps.reconcile(key: 'nearby:two', resampling: 'linear');

    expect(transition.kind, RadarLayerTransitionKind.stage);
    expect(transition.candidate?.slot, RadarLayerSlot.secondary);
    expect(transition.retired, isEmpty);
    expect(swaps.active?.key, 'nearby:one');
    expect(swaps.pending?.key, 'nearby:two');
  });

  test('newer snapshot supersedes only the hidden pending candidate', () {
    final swaps = RadarLayerSwapCoordinator()
      ..reconcile(key: 'nearby:one', resampling: 'linear')
      ..reconcile(key: 'nearby:two', resampling: 'linear');

    final transition = swaps.reconcile(
      key: 'nearby:three',
      resampling: 'linear',
    );

    expect(transition.kind, RadarLayerTransitionKind.supersede);
    expect(transition.retired.single.key, 'nearby:two');
    expect(transition.candidate?.slot, RadarLayerSlot.secondary);
    expect(swaps.active?.key, 'nearby:one');
    expect(swaps.pending?.key, 'nearby:three');
  });

  test('promotion makes pending active and retires the old visible slot', () {
    final swaps = RadarLayerSwapCoordinator()
      ..reconcile(key: 'nearby:one', resampling: 'linear')
      ..reconcile(key: 'velocity:two', resampling: 'nearest');

    final transition = swaps.promote();

    expect(transition.kind, RadarLayerTransitionKind.promote);
    expect(transition.candidate?.key, 'velocity:two');
    expect(transition.candidate?.resampling, 'nearest');
    expect(transition.retired.single.key, 'nearby:one');
    expect(swaps.active?.key, 'velocity:two');
    expect(swaps.active?.slot, RadarLayerSlot.secondary);
    expect(swaps.pending, isNull);

    final next = swaps.reconcile(key: 'nearby:three', resampling: 'linear');
    expect(next.kind, RadarLayerTransitionKind.stage);
    expect(next.candidate?.slot, RadarLayerSlot.primary);
  });

  test('returning to active key discards only a hidden pending candidate', () {
    final swaps = RadarLayerSwapCoordinator()
      ..reconcile(key: 'nearby:one', resampling: 'linear')
      ..reconcile(key: 'nearby:two', resampling: 'linear');

    final transition = swaps.reconcile(key: 'nearby:one', resampling: 'linear');

    expect(transition.kind, RadarLayerTransitionKind.discardPending);
    expect(transition.retired.single.key, 'nearby:two');
    expect(swaps.active?.key, 'nearby:one');
    expect(swaps.pending, isNull);
  });

  test('empty key resets both active and pending slots', () {
    final swaps = RadarLayerSwapCoordinator()
      ..reconcile(key: 'nearby:one', resampling: 'linear')
      ..reconcile(key: 'nearby:two', resampling: 'linear');

    final transition = swaps.reconcile(key: '', resampling: 'linear');

    expect(transition.kind, RadarLayerTransitionKind.reset);
    expect(transition.retired.map((candidate) => candidate.key).toSet(), {
      'nearby:one',
      'nearby:two',
    });
    expect(swaps.hasLayers, isFalse);
  });

  test('reset is idempotent', () {
    final swaps = RadarLayerSwapCoordinator();

    expect(swaps.reset().kind, RadarLayerTransitionKind.none);
    swaps.reconcile(key: 'nearby:one', resampling: 'linear');
    expect(swaps.reset().kind, RadarLayerTransitionKind.reset);
    expect(swaps.reset().kind, RadarLayerTransitionKind.none);
  });

  test('discarding a failed stage preserves the visible active slot', () {
    final swaps = RadarLayerSwapCoordinator()
      ..reconcile(key: 'nearby:one', resampling: 'linear')
      ..reconcile(key: 'nearby:two', resampling: 'linear');

    final transition = swaps.discardPending();

    expect(transition.kind, RadarLayerTransitionKind.discardPending);
    expect(transition.retired.single.key, 'nearby:two');
    expect(swaps.active?.key, 'nearby:one');
    expect(swaps.pending, isNull);
  });
}
