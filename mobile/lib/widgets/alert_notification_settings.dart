import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/alert_notification_controller.dart';
import '../models/alert_notification_models.dart';
import '../theme/flexoki_theme.dart';

class AlertNotificationSettingsSection extends StatelessWidget {
  const AlertNotificationSettingsSection({
    required this.controller,
    required this.learnedAlertTypes,
    this.landscape = false,
    super.key,
  });

  final AlertNotificationController controller;
  final Iterable<String> learnedAlertTypes;
  final bool landscape;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preferences = controller.preferences;
        final permission = controller.permission;
        final types = controller.alertTypes(learnedAlertTypes);
        final notificationControlsEnabled =
            permission.supported &&
            permission.notificationsGranted &&
            !controller.busy;
        return Column(
          key: const ValueKey('alert-notification-settings'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: _SectionLabel('NOTIFICATIONS')),
                TextButton(
                  key: const ValueKey('disable-all-alert-notifications'),
                  onPressed:
                      notificationControlsEnabled &&
                          preferences.enabledTypes.isNotEmpty
                      ? () => unawaited(controller.disableAll())
                      : null,
                  child: const Text('Turn off all'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            const Text(
              'Choose alert types and whether checks cover your current area or the entire U.S.',
              style: TextStyle(color: Flexoki.base500, fontSize: 13),
            ),
            const SizedBox(height: 10),
            if (permission.supported) ...[
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Flexoki.base100,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: Flexoki.base200),
                ),
                child: SwitchListTile.adaptive(
                  key: const ValueKey('alert-notification-master'),
                  value: preferences.monitoringEnabled,
                  onChanged: notificationControlsEnabled
                      ? (enabled) =>
                            unawaited(controller.setMonitoringEnabled(enabled))
                      : null,
                  title: const Text(
                    'Background notifications',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: const Text(
                    'Master switch for periodic alert checks.',
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            if (!permission.supported)
              const _PermissionCard(
                icon: Icons.phone_android_rounded,
                title: 'Android background alerts',
                body:
                    'Background weather notifications are currently available on Android.',
              )
            else if (!permission.notificationsGranted)
              _PermissionCard(
                icon: Icons.notifications_off_outlined,
                title: 'Notifications are disabled',
                body:
                    'Enable notification permission before choosing background weather alerts.',
                actionLabel: controller.busy
                    ? 'Opening…'
                    : 'Enable permissions',
                onAction: controller.busy
                    ? null
                    : () => unawaited(controller.enableNotifications()),
              )
            else if (!permission.backgroundLocationGranted)
              _PermissionCard(
                icon: Icons.location_off_outlined,
                title: preferences.scope == AlertNotificationScope.nearby
                    ? 'Nearby monitoring is paused'
                    : 'Enable Near me alerts',
                body: preferences.scope == AlertNotificationScope.nearby
                    ? 'Choose Allow all the time so HyprRadar can check where you are while closed, or select Nationwide.'
                    : 'Nationwide alerts are active without location. Enable Allow all the time only if you want to use Near me.',
                actionLabel: controller.busy
                    ? 'Opening…'
                    : 'Enable background location',
                onAction: controller.busy
                    ? null
                    : () => unawaited(controller.enableBackgroundLocation()),
              ),
            if (permission.supported) ...[
              const SizedBox(height: 12),
              Text(
                'ALERT AREA',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Flexoki.base500,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.9,
                ),
              ),
              const SizedBox(height: 7),
              SegmentedButton<AlertNotificationScope>(
                key: const ValueKey('alert-notification-scope'),
                segments: [
                  ButtonSegment(
                    value: AlertNotificationScope.nearby,
                    enabled:
                        notificationControlsEnabled &&
                        permission.backgroundLocationGranted,
                    icon: const Icon(Icons.my_location_rounded, size: 18),
                    label: const Text('Near me'),
                  ),
                  ButtonSegment(
                    value: AlertNotificationScope.nationwide,
                    enabled: notificationControlsEnabled,
                    icon: const Icon(Icons.public_rounded, size: 18),
                    label: const Text('Nationwide'),
                  ),
                ],
                selected: {preferences.scope},
                onSelectionChanged: notificationControlsEnabled
                    ? (selection) {
                        if (selection.isNotEmpty) {
                          unawaited(controller.setScope(selection.first));
                        }
                      }
                    : null,
              ),
              const SizedBox(height: 12),
              Text(
                'ALERT TYPES',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Flexoki.base500,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.9,
                ),
              ),
              const SizedBox(height: 7),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Flexoki.base100,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Flexoki.base200),
                ),
                child: landscape
                    ? _LandscapeNotificationTypes(
                        types: types,
                        controller: controller,
                        enabled: notificationControlsEnabled,
                      )
                    : Column(
                        children: [
                          for (
                            var index = 0;
                            index < types.length;
                            index++
                          ) ...[
                            if (index > 0)
                              const Divider(
                                height: 1,
                                indent: 16,
                                endIndent: 16,
                              ),
                            _NotificationTypeSwitch(
                              type: types[index],
                              selected: controller.isAlertTypeEnabled(
                                types[index],
                              ),
                              enabled: notificationControlsEnabled,
                              onChanged: (selected) => unawaited(
                                controller.setAlertTypeEnabled(
                                  types[index],
                                  selected,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
              const SizedBox(height: 10),
              Text(
                _statusText(controller),
                key: const ValueKey('alert-notification-status'),
                style: const TextStyle(color: Flexoki.base500, fontSize: 12),
              ),
            ],
            const SizedBox(height: 18),
            const Divider(height: 1),
            const SizedBox(height: 16),
          ],
        );
      },
    );
  }
}

String _statusText(AlertNotificationController controller) {
  final preferences = controller.preferences;
  if (!preferences.monitoringEnabled) {
    return 'Background notifications are off. No location or network checks are scheduled.';
  }
  if (preferences.enabledTypes.isEmpty) {
    return 'All notifications are off. No background alert checks are scheduled.';
  }
  if (!controller.backgroundWorkEnabled) {
    return 'Background checks are paused until the required permissions are enabled.';
  }
  if (!controller.backgroundWorkActive) {
    return 'Android could not schedule background checks. Reopen HyprRadar or change a notification setting to retry.';
  }
  final count = preferences.enabledTypes.length;
  final scope = preferences.scope == AlertNotificationScope.nearby
      ? 'near your latest location'
      : 'nationwide';
  return '$count ${count == 1 ? 'type' : 'types'} enabled $scope. Android checks about every 15 minutes and may delay work to save battery.';
}

class _LandscapeNotificationTypes extends StatelessWidget {
  const _LandscapeNotificationTypes({
    required this.types,
    required this.controller,
    required this.enabled,
  });

  final List<String> types;
  final AlertNotificationController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final rows = (types.length / 2).ceil();
    return Column(
      children: [
        for (var row = 0; row < rows; row++) ...[
          if (row > 0) const Divider(height: 1, indent: 12, endIndent: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var column = 0; column < 2; column++)
                Expanded(
                  child: row * 2 + column < types.length
                      ? _NotificationTypeSwitch(
                          type: types[row * 2 + column],
                          selected: controller.isAlertTypeEnabled(
                            types[row * 2 + column],
                          ),
                          enabled: enabled,
                          compact: true,
                          onChanged: (selected) => unawaited(
                            controller.setAlertTypeEnabled(
                              types[row * 2 + column],
                              selected,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _NotificationTypeSwitch extends StatelessWidget {
  const _NotificationTypeSwitch({
    required this.type,
    required this.selected,
    required this.enabled,
    required this.onChanged,
    this.compact = false,
  });

  final String type;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      key: ValueKey('notification-alert-type-$type'),
      value: selected,
      onChanged: enabled ? onChanged : null,
      dense: compact,
      visualDensity: compact
          ? const VisualDensity(horizontal: -1, vertical: -2)
          : null,
      title: Text(
        type,
        maxLines: compact ? 2 : null,
        overflow: compact ? TextOverflow.ellipsis : null,
        style: TextStyle(
          fontSize: compact ? 12 : null,
          fontWeight: FontWeight.w700,
        ),
      ),
      contentPadding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 14,
        vertical: compact ? 0 : 2,
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Flexoki.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Flexoki.orange.withValues(alpha: 0.55)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: Flexoki.orange, size: 21),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    body,
                    style: const TextStyle(
                      color: Flexoki.base700,
                      fontSize: 12,
                    ),
                  ),
                  if (actionLabel != null) ...[
                    const SizedBox(height: 7),
                    OutlinedButton(
                      key: ValueKey('alert-permission-$actionLabel'),
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        color: Flexoki.base500,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.1,
      ),
    );
  }
}
