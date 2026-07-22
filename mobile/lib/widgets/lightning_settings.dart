import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/lightning_controller.dart';
import '../theme/flexoki_theme.dart';
import 'alert_type_picker.dart';

String lightningSettingsSummary(LightningController controller) {
  if (!controller.initialized ||
      (controller.enabled && controller.status == LightningStatus.connecting)) {
    return controller.enabled ? 'On · connecting' : 'Loading…';
  }
  if (!controller.enabled) return 'Off';
  return switch (controller.status) {
    LightningStatus.live => 'On · live',
    LightningStatus.stale => 'On · data delayed',
    LightningStatus.unavailable => 'On · source unavailable',
    LightningStatus.error => 'On · reconnecting',
    LightningStatus.connecting => 'On · connecting',
    LightningStatus.disabled => 'Off',
  };
}

class LightningSettingsPage extends StatelessWidget {
  const LightningSettingsPage({
    required this.controller,
    required this.onBack,
    this.scrollController,
    super.key,
  });

  final LightningController controller;
  final VoidCallback onBack;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.uiState,
      builder: (context, _) => ListView(
        key: const ValueKey('settings-page-lightning'),
        controller: scrollController,
        padding: const EdgeInsets.only(bottom: 28),
        children: [
          SettingsPageHeader(title: 'Map layers', onBack: onBack),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Flexoki.base100,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Flexoki.base200),
                  ),
                  child: SwitchListTile.adaptive(
                    key: const ValueKey('lightning-layer-toggle'),
                    value: controller.enabled,
                    onChanged: (enabled) =>
                        unawaited(controller.setEnabled(enabled)),
                    secondary: const Icon(
                      Icons.bolt_rounded,
                      color: Flexoki.yellow,
                    ),
                    title: const Text(
                      'Show lightning flashes',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: const Text(
                      'Animate new satellite detections over the live radar map.',
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                _LightningStatusCard(controller: controller),
                const SizedBox(height: 14),
                const Text(
                  'ABOUT THIS LAYER',
                  style: TextStyle(
                    color: Flexoki.base500,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                  ),
                ),
                const SizedBox(height: 7),
                const Text(
                  'NOAA GOES satellites detect total lightning, including flashes within and between clouds as well as cloud-to-ground lightning. Each white bolt marks an approximate optical flash centroid and fades after about one second.',
                  style: TextStyle(color: Flexoki.base700, fontSize: 13),
                ),
                const SizedBox(height: 10),
                const Text(
                  'NOAA publishes detections in roughly 20-second batches. HyprRadar plays each batch across about 20 seconds to reduce bursts, which adds presentation delay and does not make the source truly real time.',
                  style: TextStyle(color: Flexoki.base700, fontSize: 13),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Locations are delayed and approximate—not exact ground strikes, a proximity alarm, or a substitute for official warnings and safe-driving judgment.',
                  style: TextStyle(
                    color: Flexoki.orange,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'The lightning connection runs only while HyprRadar is open and this optional layer is enabled.',
                  style: TextStyle(color: Flexoki.base500, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LightningStatusCard extends StatelessWidget {
  const _LightningStatusCard({required this.controller});

  final LightningController controller;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (controller.status) {
      LightningStatus.disabled => (
        Icons.layers_clear_outlined,
        Flexoki.base500,
        'Layer is off',
      ),
      LightningStatus.connecting => (
        Icons.sync_rounded,
        Flexoki.cyan,
        'Connecting to live lightning…',
      ),
      LightningStatus.live => (
        Icons.bolt_rounded,
        Flexoki.yellow,
        'Receiving live NOAA lightning data',
      ),
      LightningStatus.stale => (
        Icons.schedule_rounded,
        Flexoki.orange,
        'Lightning data is delayed',
      ),
      LightningStatus.unavailable => (
        Icons.cloud_off_rounded,
        Flexoki.orange,
        'Lightning source is unavailable',
      ),
      LightningStatus.error => (
        Icons.sync_problem_rounded,
        Flexoki.orange,
        'Connection interrupted; retrying automatically',
      ),
    };
    return Semantics(
      liveRegion: true,
      label: label,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.42)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  label,
                  key: const ValueKey('lightning-layer-status'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
