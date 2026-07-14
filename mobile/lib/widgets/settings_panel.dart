import 'package:flutter/material.dart';

import '../theme/flexoki_theme.dart';

/// Reusable application settings content for a modal sheet or full page.
class RadarSettingsPanel extends StatelessWidget {
  const RadarSettingsPanel({
    required this.alertTypes,
    required this.alertTypeCounts,
    required this.isAlertTypeVisible,
    required this.onAlertTypeChanged,
    required this.onShowAllAlertTypes,
    this.scrollController,
    super.key,
  });

  final List<String> alertTypes;
  final Map<String, int> alertTypeCounts;
  final bool Function(String alertType) isAlertTypeVisible;
  final void Function(String alertType, bool visible) onAlertTypeChanged;
  final VoidCallback onShowAllAlertTypes;
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final hasHiddenType = alertTypes.any((type) => !isAlertTypeVisible(type));
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            TextButton(
              onPressed: hasHiddenType ? onShowAllAlertTypes : null,
              child: const Text('Show all'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'WEATHER ALERTS',
          style: TextStyle(
            color: Flexoki.base500,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: 5),
        const Text(
          'Choose which alert types appear on the map and in the active-alert count.',
          style: TextStyle(color: Flexoki.base500, fontSize: 13),
        ),
        const SizedBox(height: 12),
        if (alertTypes.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'Alert types will appear after live alerts are loaded.',
                style: TextStyle(color: Flexoki.base500),
              ),
            ),
          )
        else
          DecoratedBox(
            decoration: BoxDecoration(
              color: Flexoki.base100,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Flexoki.base200),
            ),
            child: Column(
              children: [
                for (var index = 0; index < alertTypes.length; index++) ...[
                  if (index > 0)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  _AlertTypeSwitch(
                    alertType: alertTypes[index],
                    activeCount: alertTypeCounts[alertTypes[index]] ?? 0,
                    visible: isAlertTypeVisible(alertTypes[index]),
                    onChanged: (visible) =>
                        onAlertTypeChanged(alertTypes[index], visible),
                  ),
                ],
              ],
            ),
          ),
        const SizedBox(height: 14),
        const Text(
          'Hidden alerts remain active National Weather Service products; this setting only changes their display in Anvil.',
          style: TextStyle(color: Flexoki.base500, fontSize: 12),
        ),
      ],
    );
  }
}

class _AlertTypeSwitch extends StatelessWidget {
  const _AlertTypeSwitch({
    required this.alertType,
    required this.activeCount,
    required this.visible,
    required this.onChanged,
  });

  final String alertType;
  final int activeCount;
  final bool visible;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      key: ValueKey('alert-type-$alertType'),
      value: visible,
      onChanged: onChanged,
      title: Text(
        alertType,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(
        activeCount == 0
            ? 'No active alerts'
            : '$activeCount active ${activeCount == 1 ? 'alert' : 'alerts'}',
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
    );
  }
}
