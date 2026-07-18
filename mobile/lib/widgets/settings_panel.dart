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
    this.landscape = false,
    super.key,
  });

  final List<String> alertTypes;
  final Map<String, int> alertTypeCounts;
  final bool Function(String alertType) isAlertTypeVisible;
  final void Function(String alertType, bool visible) onAlertTypeChanged;
  final VoidCallback onShowAllAlertTypes;
  final ScrollController? scrollController;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    final hasHiddenType = alertTypes.any((type) => !isAlertTypeVisible(type));
    if (landscape) {
      return _buildLandscape(context, hasHiddenType);
    }
    return ListView(
      key: const ValueKey('radar-settings-panel'),
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
          'Hidden alerts remain active National Weather Service products; this setting only changes their display in HyprRadar.',
          style: TextStyle(color: Flexoki.base500, fontSize: 12),
        ),
      ],
    );
  }

  Widget _buildLandscape(BuildContext context, bool hasHiddenType) {
    final rowCount = (alertTypes.length / 2).ceil();
    return Column(
      key: const ValueKey('radar-settings-panel'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
          child: Row(
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
        ),
        const Divider(height: 1),
        Expanded(
          child: alertTypes.isEmpty
              ? ListView(
                  key: const ValueKey('settings-alert-types-scroll'),
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                  children: [
                    _landscapeAlertIntro(),
                    const Padding(
                      padding: EdgeInsets.only(top: 24),
                      child: Center(
                        child: Text(
                          'Alert types will appear after live alerts are loaded.',
                          style: TextStyle(color: Flexoki.base500),
                        ),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  key: const ValueKey('settings-alert-types-scroll'),
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
                  itemCount: rowCount + 2,
                  itemBuilder: (context, itemIndex) {
                    if (itemIndex == 0) {
                      return _landscapeAlertIntro();
                    }
                    if (itemIndex == rowCount + 1) {
                      return const Padding(
                        padding: EdgeInsets.only(top: 6),
                        child: Text(
                          'Hidden alerts remain active National Weather Service products; this setting only changes their display in HyprRadar.',
                          style: TextStyle(
                            color: Flexoki.base500,
                            fontSize: 12,
                          ),
                        ),
                      );
                    }
                    final rowIndex = itemIndex - 1;
                    final firstIndex = rowIndex * 2;
                    final secondIndex = firstIndex + 1;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: _LandscapeAlertTypeTile(
                                alertType: alertTypes[firstIndex],
                                activeCount:
                                    alertTypeCounts[alertTypes[firstIndex]] ??
                                    0,
                                visible: isAlertTypeVisible(
                                  alertTypes[firstIndex],
                                ),
                                onChanged: (visible) => onAlertTypeChanged(
                                  alertTypes[firstIndex],
                                  visible,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: secondIndex < alertTypes.length
                                  ? _LandscapeAlertTypeTile(
                                      alertType: alertTypes[secondIndex],
                                      activeCount:
                                          alertTypeCounts[alertTypes[secondIndex]] ??
                                          0,
                                      visible: isAlertTypeVisible(
                                        alertTypes[secondIndex],
                                      ),
                                      onChanged: (visible) =>
                                          onAlertTypeChanged(
                                            alertTypes[secondIndex],
                                            visible,
                                          ),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _landscapeAlertIntro() {
    return const Padding(
      padding: EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'WEATHER ALERTS',
            style: TextStyle(
              color: Flexoki.base500,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          SizedBox(height: 3),
          Text(
            'Choose which alert types appear on the map.',
            style: TextStyle(color: Flexoki.base500, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _LandscapeAlertTypeTile extends StatelessWidget {
  const _LandscapeAlertTypeTile({
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Flexoki.base100,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: Flexoki.base200),
      ),
      child: _AlertTypeSwitch(
        alertType: alertType,
        activeCount: activeCount,
        visible: visible,
        compact: true,
        onChanged: onChanged,
      ),
    );
  }
}

class _AlertTypeSwitch extends StatelessWidget {
  const _AlertTypeSwitch({
    required this.alertType,
    required this.activeCount,
    required this.visible,
    required this.onChanged,
    this.compact = false,
  });

  final String alertType;
  final int activeCount;
  final bool visible;
  final ValueChanged<bool> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      key: ValueKey('alert-type-$alertType'),
      value: visible,
      onChanged: onChanged,
      dense: compact,
      visualDensity: compact
          ? const VisualDensity(horizontal: -1, vertical: -2)
          : null,
      title: Text(
        alertType,
        maxLines: compact ? 2 : null,
        overflow: compact ? TextOverflow.ellipsis : null,
        style: TextStyle(
          fontSize: compact ? 13 : null,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: compact && activeCount == 0
          ? null
          : Text(
              activeCount == 0
                  ? 'No active alerts'
                  : '$activeCount active ${activeCount == 1 ? 'alert' : 'alerts'}',
              maxLines: compact ? 1 : null,
              overflow: compact ? TextOverflow.ellipsis : null,
              style: compact ? const TextStyle(fontSize: 11) : null,
            ),
      contentPadding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 14,
        vertical: compact ? 0 : 2,
      ),
    );
  }
}
