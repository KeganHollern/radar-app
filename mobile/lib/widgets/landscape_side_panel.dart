import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/flexoki_theme.dart';

typedef LandscapePanelBuilder =
    Widget Function(BuildContext context, ScrollController scrollController);

/// Opens a full-height, right-aligned panel for landscape-only interactions.
Future<T?> showLandscapeSidePanel<T>({
  required BuildContext context,
  required String barrierLabel,
  required LandscapePanelBuilder builder,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (context, animation, secondaryAnimation) {
      return LandscapeSidePanel(closeLabel: barrierLabel, builder: builder);
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.16, 0),
            end: Offset.zero,
          ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// The testable panel surface used by [showLandscapeSidePanel].
class LandscapeSidePanel extends StatefulWidget {
  const LandscapeSidePanel({
    required this.closeLabel,
    required this.builder,
    super.key,
  });

  final String closeLabel;
  final LandscapePanelBuilder builder;

  @override
  State<LandscapeSidePanel> createState() => _LandscapeSidePanelState();
}

class _LandscapeSidePanelState extends State<LandscapeSidePanel> {
  late final ScrollController _scrollController = ScrollController();

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableWidth = media.size.width - media.padding.horizontal - 16;
    final desiredWidth = (media.size.width * 0.58)
        .clamp(420.0, 600.0)
        .toDouble();
    final panelWidth = min(desiredWidth, availableWidth);

    return SafeArea(
      minimum: const EdgeInsets.all(8),
      child: Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          key: const ValueKey('landscape-side-panel'),
          width: panelWidth,
          height: double.infinity,
          child: Material(
            color: Flexoki.base50,
            elevation: 18,
            shadowColor: Colors.black,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Flexoki.base300),
            ),
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      key: const ValueKey('landscape-side-panel-close'),
                      tooltip: widget.closeLabel,
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ),
                Expanded(child: widget.builder(context, _scrollController)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }
}
