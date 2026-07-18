import 'dart:async';

import 'package:flutter/material.dart';

import '../models/alert_type_category.dart';
import '../theme/flexoki_theme.dart';

typedef AlertTypeChanged = FutureOr<void> Function(String type, bool selected);

class SettingsPageHeader extends StatelessWidget {
  const SettingsPageHeader({
    required this.title,
    this.onBack,
    this.backTooltip = 'Back to settings',
    this.action,
    super.key,
  });

  final String title;
  final VoidCallback? onBack;
  final String backTooltip;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
      child: Row(
        children: [
          if (onBack != null)
            IconButton(
              key: const ValueKey('settings-page-back'),
              tooltip: backTooltip,
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class AlertTypeCategoryTile extends StatelessWidget {
  const AlertTypeCategoryTile({
    required this.category,
    required this.summary,
    required this.onTap,
    this.enabled = true,
    this.keyPrefix = 'alert-category',
    super.key,
  });

  final AlertTypeCategory category;
  final String summary;
  final VoidCallback onTap;
  final bool enabled;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Flexoki.base100,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Flexoki.base200),
        ),
        child: ListTile(
          key: ValueKey('$keyPrefix-${category.storageKey}'),
          enabled: enabled,
          minTileHeight: 64,
          leading: Icon(_iconFor(category), color: Flexoki.cyan),
          title: Text(
            category.label,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          subtitle: Text(summary),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: enabled ? onTap : null,
        ),
      ),
    );
  }
}

class AlertTypePicker extends StatefulWidget {
  const AlertTypePicker({
    required this.controller,
    required this.header,
    required this.category,
    required this.types,
    required this.isSelected,
    required this.onChanged,
    required this.semanticAction,
    required this.toggleKeyPrefix,
    this.enabled = true,
    this.countForType,
    this.footer,
    super.key,
  });

  final ScrollController? controller;
  final Widget header;
  final AlertTypeCategory category;
  final List<String> types;
  final bool Function(String type) isSelected;
  final AlertTypeChanged onChanged;
  final String semanticAction;
  final String toggleKeyPrefix;
  final bool enabled;
  final int Function(String type)? countForType;
  final Widget? footer;

  @override
  State<AlertTypePicker> createState() => _AlertTypePickerState();
}

class _AlertTypePickerState extends State<AlertTypePicker> {
  final Map<String, bool> _optimisticValues = {};
  final Map<String, int> _changeRevisions = {};

  bool _valueFor(String type) =>
      _optimisticValues[type] ?? widget.isSelected(type);

  void _change(String type, bool selected) {
    final revision = (_changeRevisions[type] ?? 0) + 1;
    setState(() {
      _changeRevisions[type] = revision;
      _optimisticValues[type] = selected;
    });

    // Let the switch paint before map filtering, persistence, or platform
    // scheduler work begins. This keeps taps responsive even with many alerts.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await Future<void>.sync(() => widget.onChanged(type, selected));
      } catch (error, stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'HyprRadar settings',
            context: ErrorDescription('while changing the $type alert setting'),
          ),
        );
      } finally {
        if (mounted && _changeRevisions[type] == revision) {
          setState(() => _optimisticValues.remove(type));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      key: ValueKey('alert-type-picker-${widget.category.storageKey}'),
      controller: widget.controller,
      slivers: [
        SliverToBoxAdapter(child: widget.header),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 2, 18, 28),
          sliver: SliverList.builder(
            itemCount: widget.types.length + (widget.footer == null ? 1 : 2),
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    widget.category.description,
                    style: const TextStyle(
                      color: Flexoki.base500,
                      fontSize: 13,
                    ),
                  ),
                );
              }
              final typeIndex = index - 1;
              if (typeIndex == widget.types.length) {
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: widget.footer,
                );
              }
              final type = widget.types[typeIndex];
              final selected = _valueFor(type);
              final count = widget.countForType?.call(type);
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Flexoki.base100,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Flexoki.base200),
                  ),
                  child: Semantics(
                    container: true,
                    label: '${widget.semanticAction} $type',
                    toggled: selected,
                    enabled: widget.enabled,
                    onTap: widget.enabled
                        ? () => _change(type, !selected)
                        : null,
                    child: ExcludeSemantics(
                      child: SwitchListTile.adaptive(
                        key: ValueKey('${widget.toggleKeyPrefix}-$type'),
                        value: selected,
                        onChanged: widget.enabled
                            ? (value) => _change(type, value)
                            : null,
                        title: Text(
                          type,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: count == null
                            ? null
                            : Text(
                                count == 0
                                    ? 'No active alerts'
                                    : '$count active ${count == 1 ? 'alert' : 'alerts'}',
                              ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

IconData _iconFor(AlertTypeCategory category) => switch (category) {
  AlertTypeCategory.stormsAndWind => Icons.thunderstorm_rounded,
  AlertTypeCategory.floodingAndTropical => Icons.water_rounded,
  AlertTypeCategory.winter => Icons.ac_unit_rounded,
  AlertTypeCategory.heatFireAndAir => Icons.local_fire_department_rounded,
  AlertTypeCategory.other => Icons.info_outline_rounded,
};
