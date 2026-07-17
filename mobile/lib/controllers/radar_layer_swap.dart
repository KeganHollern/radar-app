/// The two native source/layer slots used to replace radar imagery without
/// removing the currently visible layer first.
enum RadarLayerSlot {
  primary,
  secondary;

  RadarLayerSlot get other => switch (this) {
    RadarLayerSlot.primary => RadarLayerSlot.secondary,
    RadarLayerSlot.secondary => RadarLayerSlot.primary,
  };

  String get sourceId => 'live-radar-source-$name';
  String get layerId => 'live-radar-layer-$name';
}

final class RadarLayerCandidate {
  const RadarLayerCandidate({
    required this.slot,
    required this.key,
    required this.resampling,
  });

  final RadarLayerSlot slot;
  final String key;
  final String resampling;

  String get sourceId => slot.sourceId;
  String get layerId => slot.layerId;
}

enum RadarLayerTransitionKind {
  none,
  install,
  stage,
  supersede,
  discardPending,
  promote,
  reset,
}

final class RadarLayerTransition {
  const RadarLayerTransition._({
    required this.kind,
    this.candidate,
    this.retired = const [],
  });

  const RadarLayerTransition.none()
    : this._(kind: RadarLayerTransitionKind.none);

  final RadarLayerTransitionKind kind;
  final RadarLayerCandidate? candidate;
  final List<RadarLayerCandidate> retired;
}

/// Pure state machine for double-buffering native raster layers.
///
/// The active slot remains visible while the other slot loads. A newer
/// snapshot may replace only that hidden pending slot. The caller promotes a
/// pending candidate after MapLibre reports that the map is idle.
final class RadarLayerSwapCoordinator {
  RadarLayerCandidate? _active;
  RadarLayerCandidate? _pending;

  RadarLayerCandidate? get active => _active;
  RadarLayerCandidate? get pending => _pending;
  bool get hasLayers => _active != null || _pending != null;

  RadarLayerTransition reconcile({
    required String key,
    required String resampling,
  }) {
    if (key.isEmpty) return reset();

    final active = _active;
    final pending = _pending;

    if (active?.key == key) {
      if (pending == null) return const RadarLayerTransition.none();
      _pending = null;
      return RadarLayerTransition._(
        kind: RadarLayerTransitionKind.discardPending,
        retired: [pending],
      );
    }
    if (pending?.key == key) return const RadarLayerTransition.none();

    if (active == null) {
      final candidate = RadarLayerCandidate(
        slot: RadarLayerSlot.primary,
        key: key,
        resampling: resampling,
      );
      _active = candidate;
      _pending = null;
      return RadarLayerTransition._(
        kind: RadarLayerTransitionKind.install,
        candidate: candidate,
        retired: pending == null ? const [] : [pending],
      );
    }

    final candidate = RadarLayerCandidate(
      slot: active.slot.other,
      key: key,
      resampling: resampling,
    );
    _pending = candidate;
    return RadarLayerTransition._(
      kind: pending == null
          ? RadarLayerTransitionKind.stage
          : RadarLayerTransitionKind.supersede,
      candidate: candidate,
      retired: pending == null ? const [] : [pending],
    );
  }

  RadarLayerTransition promote() {
    final pending = _pending;
    if (pending == null) return const RadarLayerTransition.none();

    final previous = _active;
    _active = pending;
    _pending = null;
    return RadarLayerTransition._(
      kind: RadarLayerTransitionKind.promote,
      candidate: pending,
      retired: previous == null ? const [] : [previous],
    );
  }

  RadarLayerTransition discardPending() {
    final pending = _pending;
    if (pending == null) return const RadarLayerTransition.none();
    _pending = null;
    return RadarLayerTransition._(
      kind: RadarLayerTransitionKind.discardPending,
      retired: [pending],
    );
  }

  RadarLayerTransition reset() {
    final retired = <RadarLayerCandidate>[?_active, ?_pending];
    _active = null;
    _pending = null;
    if (retired.isEmpty) return const RadarLayerTransition.none();
    return RadarLayerTransition._(
      kind: RadarLayerTransitionKind.reset,
      retired: retired,
    );
  }
}
