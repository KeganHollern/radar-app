import 'package:flutter/material.dart';

import '../controllers/alert_notification_controller.dart';
import '../models/alert_type_category.dart';
import '../theme/flexoki_theme.dart';
import 'alert_notification_settings.dart';
import 'alert_type_picker.dart';

typedef RadarSettingsDestinationPageBuilder =
    Widget Function(
      BuildContext context,
      ScrollController? scrollController,
      VoidCallback onBack,
    );

/// An optional settings destination supplied by a map feature.
///
/// This keeps the landing page extensible without placing feature-specific
/// controls in the already compact top-level menu.
class RadarSettingsDestination {
  const RadarSettingsDestination({
    required this.id,
    required this.icon,
    required this.title,
    required this.summary,
    required this.pageBuilder,
    this.listenable,
  });

  final String id;
  final IconData icon;
  final String title;
  final String Function() summary;
  final RadarSettingsDestinationPageBuilder pageBuilder;
  final Listenable? listenable;
}

/// Reusable application settings content for a modal sheet or side panel.
class RadarSettingsPanel extends StatefulWidget {
  const RadarSettingsPanel({
    required this.alertTypes,
    required this.alertTypeCounts,
    required this.isAlertTypeVisible,
    required this.onAlertTypeChanged,
    required this.onShowAllAlertTypes,
    this.notificationController,
    this.additionalDestinations = const [],
    this.initialDestinationId,
    this.scrollController,
    this.landscape = false,
    super.key,
  });

  final List<String> alertTypes;
  final Map<String, int> alertTypeCounts;
  final bool Function(String alertType) isAlertTypeVisible;
  final void Function(String alertType, bool visible) onAlertTypeChanged;
  final VoidCallback onShowAllAlertTypes;
  final AlertNotificationController? notificationController;
  final List<RadarSettingsDestination> additionalDestinations;
  final String? initialDestinationId;
  final ScrollController? scrollController;
  final bool landscape;

  @override
  State<RadarSettingsPanel> createState() => _RadarSettingsPanelState();
}

enum _SettingsPage {
  home,
  mapAlerts,
  mapAlertTypes,
  notifications,
  notificationAlertTypes,
  additional,
}

class _RadarSettingsPanelState extends State<RadarSettingsPanel> {
  _SettingsPage _page = _SettingsPage.home;
  AlertTypeCategory? _category;
  RadarSettingsDestination? _additionalDestination;

  @override
  void initState() {
    super.initState();
    final initialId = widget.initialDestinationId;
    if (initialId == null) return;
    for (final destination in widget.additionalDestinations) {
      if (destination.id != initialId) continue;
      _additionalDestination = destination;
      _page = _SettingsPage.additional;
      break;
    }
  }

  void _open(_SettingsPage page, {AlertTypeCategory? category}) {
    setState(() {
      _page = page;
      _category = category;
      if (page != _SettingsPage.additional) _additionalDestination = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = widget.scrollController;
      if (controller?.hasClients ?? false) controller!.jumpTo(0);
    });
  }

  void _back() {
    switch (_page) {
      case _SettingsPage.mapAlertTypes:
        _open(_SettingsPage.mapAlerts);
      case _SettingsPage.notificationAlertTypes:
        _open(_SettingsPage.notifications);
      case _SettingsPage.mapAlerts || _SettingsPage.notifications:
        _open(_SettingsPage.home);
      case _SettingsPage.additional:
        _open(_SettingsPage.home);
      case _SettingsPage.home:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _page == _SettingsPage.home,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _back();
      },
      child: KeyedSubtree(
        key: const ValueKey('radar-settings-panel'),
        child: switch (_page) {
          _SettingsPage.home => _buildHome(context),
          _SettingsPage.mapAlerts => _buildMapAlerts(context),
          _SettingsPage.mapAlertTypes => _buildMapAlertTypes(),
          _SettingsPage.notifications => _buildNotifications(),
          _SettingsPage.notificationAlertTypes =>
            _buildNotificationAlertTypes(),
          _SettingsPage.additional => _buildAdditionalDestination(context),
        },
      ),
    );
  }

  Widget _buildHome(BuildContext context) {
    final visibleCount = widget.alertTypes
        .where(widget.isAlertTypeVisible)
        .length;
    return ListView(
      key: const ValueKey('settings-page-home'),
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const SettingsPageHeader(title: 'Settings'),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Choose a section to change map layers, alert display, and background notifications.',
                style: TextStyle(color: Flexoki.base500, fontSize: 13),
              ),
              const SizedBox(height: 14),
              _SettingsDestinationTile(
                key: const ValueKey('settings-destination-map-alerts'),
                icon: Icons.warning_amber_rounded,
                title: 'Map alerts',
                summary: widget.alertTypes.isEmpty
                    ? 'Alert types appear after live alerts load'
                    : '$visibleCount of ${widget.alertTypes.length} types shown',
                onTap: () => _open(_SettingsPage.mapAlerts),
              ),
              for (final destination in widget.additionalDestinations) ...[
                const SizedBox(height: 10),
                _buildAdditionalDestinationTile(destination),
              ],
              if (widget.notificationController case final controller?) ...[
                const SizedBox(height: 10),
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => _SettingsDestinationTile(
                    key: const ValueKey('settings-destination-notifications'),
                    icon: Icons.notifications_outlined,
                    title: 'Background notifications',
                    summary: alertNotificationSettingsSummary(controller),
                    onTap: () => _open(_SettingsPage.notifications),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAdditionalDestinationTile(RadarSettingsDestination destination) {
    Widget tile() => _SettingsDestinationTile(
      key: ValueKey('settings-destination-${destination.id}'),
      icon: destination.icon,
      title: destination.title,
      summary: destination.summary(),
      onTap: () {
        _additionalDestination = destination;
        _open(_SettingsPage.additional);
      },
    );
    final listenable = destination.listenable;
    return listenable == null
        ? tile()
        : ListenableBuilder(
            listenable: listenable,
            builder: (context, _) => tile(),
          );
  }

  Widget _buildMapAlerts(BuildContext context) {
    final groups = groupAlertTypes(widget.alertTypes);
    final hasHiddenType = widget.alertTypes.any(
      (type) => !widget.isAlertTypeVisible(type),
    );
    return ListView(
      key: const ValueKey('settings-page-map-alerts'),
      controller: widget.scrollController,
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        SettingsPageHeader(
          title: 'Map alerts',
          onBack: _back,
          action: TextButton(
            key: const ValueKey('show-all-map-alert-types'),
            onPressed: hasHiddenType
                ? () {
                    widget.onShowAllAlertTypes();
                    setState(() {});
                  }
                : null,
            child: const Text('Show all'),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: _horizontalPadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Choose which National Weather Service alert types appear on the map and in the active-alert count.',
                style: TextStyle(color: Flexoki.base500, fontSize: 13),
              ),
              const SizedBox(height: 14),
              if (groups.isEmpty)
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
                for (final group in groups)
                  AlertTypeCategoryTile(
                    category: group.category,
                    keyPrefix: 'map-alert-category',
                    summary: _mapGroupSummary(group.types),
                    onTap: () => _open(
                      _SettingsPage.mapAlertTypes,
                      category: group.category,
                    ),
                  ),
              const SizedBox(height: 4),
              const Text(
                'Hidden alerts remain active NWS products. This setting changes only their display in HyprRadar.',
                style: TextStyle(color: Flexoki.base500, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _mapGroupSummary(Iterable<String> types) {
    final typeList = types.toList(growable: false);
    final visible = typeList.where(widget.isAlertTypeVisible).length;
    final active = typeList.fold<int>(
      0,
      (count, type) => count + (widget.alertTypeCounts[type] ?? 0),
    );
    final activeSummary = active == 1
        ? '1 active alert'
        : '$active active alerts';
    return '$visible of ${typeList.length} shown · $activeSummary';
  }

  Widget _buildMapAlertTypes() {
    final category = _category ?? AlertTypeCategory.other;
    final group = groupAlertTypes(
      widget.alertTypes,
    ).where((group) => group.category == category).firstOrNull;
    return AlertTypePicker(
      key: ValueKey('settings-page-map-${category.storageKey}'),
      controller: widget.scrollController,
      header: SettingsPageHeader(
        title: category.label,
        onBack: _back,
        backTooltip: 'Back to map alerts',
      ),
      category: category,
      types: group?.types ?? const [],
      isSelected: widget.isAlertTypeVisible,
      semanticAction: 'Show on map',
      toggleKeyPrefix: 'alert-type',
      countForType: (type) => widget.alertTypeCounts[type] ?? 0,
      onChanged: (type, visible) {
        widget.onAlertTypeChanged(type, visible);
        if (mounted) setState(() {});
      },
      footer: const Text(
        'Map visibility does not change your background notification choices.',
        style: TextStyle(color: Flexoki.base500, fontSize: 12),
      ),
    );
  }

  Widget _buildNotifications() {
    final controller = widget.notificationController;
    if (controller == null) return _buildHome(context);
    return AlertNotificationSettingsPage(
      controller: controller,
      learnedAlertTypes: widget.alertTypes,
      scrollController: widget.scrollController,
      onBack: _back,
      onCategorySelected: (category) =>
          _open(_SettingsPage.notificationAlertTypes, category: category),
    );
  }

  Widget _buildNotificationAlertTypes() {
    final controller = widget.notificationController;
    if (controller == null) return _buildHome(context);
    return AlertNotificationTypePickerPage(
      controller: controller,
      learnedAlertTypes: widget.alertTypes,
      category: _category ?? AlertTypeCategory.other,
      scrollController: widget.scrollController,
      onBack: _back,
    );
  }

  Widget _buildAdditionalDestination(BuildContext context) {
    final destination = _additionalDestination;
    if (destination == null) return _buildHome(context);
    return destination.pageBuilder(context, widget.scrollController, _back);
  }

  double get _horizontalPadding => widget.landscape ? 16 : 18;
}

class _SettingsDestinationTile extends StatelessWidget {
  const _SettingsDestinationTile({
    required this.icon,
    required this.title,
    required this.summary,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Flexoki.base100,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Flexoki.base200),
      ),
      child: ListTile(
        minTileHeight: 72,
        leading: Icon(icon, color: Flexoki.cyan, size: 25),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        subtitle: Text(summary),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }
}
