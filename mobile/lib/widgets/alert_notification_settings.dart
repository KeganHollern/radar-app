import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/alert_notification_controller.dart';
import '../models/alert_notification_models.dart';
import '../models/alert_type_category.dart';
import '../theme/flexoki_theme.dart';
import 'alert_type_picker.dart';

String alertNotificationSettingsSummary(
  AlertNotificationController controller,
) {
  final permission = controller.permission;
  final preferences = controller.preferences;
  if (!permission.supported) return 'Unavailable on this device';
  if (!permission.notificationsGranted) return 'Permission required';
  final count = preferences.enabledTypes.length;
  final selected = '$count ${count == 1 ? 'type' : 'types'} selected';
  if (!preferences.monitoringEnabled) return 'Off · $selected';
  return 'On · ${preferences.scope.label} · $selected';
}

class AlertNotificationSettingsPage extends StatelessWidget {
  const AlertNotificationSettingsPage({
    required this.controller,
    required this.learnedAlertTypes,
    required this.scrollController,
    required this.onBack,
    required this.onCategorySelected,
    super.key,
  });

  final AlertNotificationController controller;
  final Iterable<String> learnedAlertTypes;
  final ScrollController? scrollController;
  final VoidCallback onBack;
  final ValueChanged<AlertTypeCategory> onCategorySelected;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final preferences = controller.preferences;
        final permission = controller.permission;
        final groups = groupAlertTypes(
          controller.alertTypes(learnedAlertTypes),
        );
        final controlsEnabled =
            permission.supported &&
            permission.notificationsGranted &&
            !controller.busy;
        return ListView(
          key: const ValueKey('settings-page-notifications'),
          controller: scrollController,
          padding: const EdgeInsets.only(bottom: 28),
          children: [
            SettingsPageHeader(
              title: 'Background notifications',
              onBack: onBack,
              action: TextButton(
                key: const ValueKey('disable-all-alert-notifications'),
                onPressed:
                    controlsEnabled && preferences.enabledTypes.isNotEmpty
                    ? () => unawaited(controller.disableAll())
                    : null,
                child: const Text('Turn off all'),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Column(
                key: const ValueKey('alert-notification-settings'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Choose which alerts can notify you while HyprRadar is closed.',
                    style: TextStyle(color: Flexoki.base500, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
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
                        onChanged: controlsEnabled
                            ? (enabled) => unawaited(
                                controller.setMonitoringEnabled(enabled),
                              )
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
                          : () => unawaited(
                              controller.enableBackgroundLocation(),
                            ),
                    ),
                  if (permission.supported) ...[
                    const SizedBox(height: 16),
                    const _SectionLabel('ALERT AREA'),
                    const SizedBox(height: 7),
                    SegmentedButton<AlertNotificationScope>(
                      key: const ValueKey('alert-notification-scope'),
                      segments: [
                        ButtonSegment(
                          value: AlertNotificationScope.nearby,
                          enabled:
                              controlsEnabled &&
                              permission.backgroundLocationGranted,
                          icon: const Icon(Icons.my_location_rounded, size: 18),
                          label: const Text('Near me'),
                        ),
                        ButtonSegment(
                          value: AlertNotificationScope.nationwide,
                          enabled: controlsEnabled,
                          icon: const Icon(Icons.public_rounded, size: 18),
                          label: const Text('Nationwide'),
                        ),
                      ],
                      selected: {preferences.scope},
                      onSelectionChanged: controlsEnabled
                          ? (selection) {
                              if (selection.isNotEmpty) {
                                unawaited(controller.setScope(selection.first));
                              }
                            }
                          : null,
                    ),
                    const SizedBox(height: 18),
                    const _SectionLabel('ALERT TYPES'),
                    const SizedBox(height: 4),
                    const Text(
                      'Open a group to choose the alert types that can notify you.',
                      style: TextStyle(color: Flexoki.base500, fontSize: 13),
                    ),
                    const SizedBox(height: 10),
                    for (final group in groups)
                      AlertTypeCategoryTile(
                        category: group.category,
                        keyPrefix: 'notification-alert-category',
                        summary: _selectionSummary(
                          group.types,
                          controller.isAlertTypeEnabled,
                        ),
                        onTap: () => onCategorySelected(group.category),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      _statusText(controller),
                      key: const ValueKey('alert-notification-status'),
                      style: const TextStyle(
                        color: Flexoki.base500,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class AlertNotificationTypePickerPage extends StatelessWidget {
  const AlertNotificationTypePickerPage({
    required this.controller,
    required this.learnedAlertTypes,
    required this.category,
    required this.scrollController,
    required this.onBack,
    super.key,
  });

  final AlertNotificationController controller;
  final Iterable<String> learnedAlertTypes;
  final AlertTypeCategory category;
  final ScrollController? scrollController;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final group = groupAlertTypes(
          controller.alertTypes(learnedAlertTypes),
        ).where((group) => group.category == category).firstOrNull;
        final permission = controller.permission;
        final enabled =
            permission.supported &&
            permission.notificationsGranted &&
            !controller.busy;
        return AlertTypePicker(
          key: ValueKey('settings-page-notification-${category.storageKey}'),
          controller: scrollController,
          header: SettingsPageHeader(
            title: category.label,
            onBack: onBack,
            backTooltip: 'Back to background notifications',
          ),
          category: category,
          types: group?.types ?? const [],
          isSelected: controller.isAlertTypeEnabled,
          enabled: enabled,
          semanticAction: 'Notify for',
          toggleKeyPrefix: 'notification-alert-type',
          onChanged: controller.setAlertTypeEnabled,
          footer: Text(
            enabled
                ? 'Notification choices do not change which alerts appear on the map.'
                : 'Enable notification permission to change these choices.',
            style: const TextStyle(color: Flexoki.base500, fontSize: 12),
          ),
        );
      },
    );
  }
}

String _selectionSummary(
  Iterable<String> types,
  bool Function(String) isSelected,
) {
  final typeList = types.toList(growable: false);
  final selected = typeList.where(isSelected).length;
  return '$selected of ${typeList.length} selected';
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
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Flexoki.base500,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.9,
      ),
    );
  }
}
