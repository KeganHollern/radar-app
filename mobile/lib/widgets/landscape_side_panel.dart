import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
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

class _LandscapeSidePanelState extends State<LandscapeSidePanel>
    with SingleTickerProviderStateMixin {
  static const _settleDuration = Duration(milliseconds: 180);
  static const _activationDistance = 88.0;

  late final ScrollController _scrollController = ScrollController();
  late final AnimationController _dismissController = AnimationController(
    vsync: this,
    duration: _settleDuration,
  );
  double _panelWidth = 0;
  bool _dragActivated = false;
  bool _dismissing = false;

  void _handleHorizontalDragStart(DragStartDetails details) {
    if (_dismissing) return;
    _dismissController.stop();
    _dragActivated = true;
  }

  void _handleHorizontalDragUpdate(DragUpdateDetails details) {
    if (_dismissing || _panelWidth <= 0) return;
    _dismissController.value =
        (_dismissController.value + details.delta.dx / _panelWidth).clamp(
          0.0,
          1.0,
        );
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (_dismissing) return;
    if (_dragActivated) {
      _dragActivated = false;
      unawaited(_dismiss());
      return;
    }
    unawaited(_resetHorizontalDrag());
  }

  void _handleHorizontalDragCancel() {
    _dragActivated = false;
    unawaited(_resetHorizontalDrag());
  }

  Future<void> _resetHorizontalDrag() async {
    if (_dismissing || _dismissController.value == 0) return;
    await _dismissController.animateBack(
      0,
      duration: _settleDuration,
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _dismiss() async {
    if (_dismissing) return;
    _dismissing = true;
    _dragActivated = false;
    unawaited(
      _dismissController.animateTo(
        1,
        duration: _settleDuration,
        curve: Curves.easeOutCubic,
      ),
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final availableWidth = media.size.width - media.padding.horizontal - 16;
    final desiredWidth = (media.size.width * 0.58)
        .clamp(420.0, 600.0)
        .toDouble();
    final panelWidth = min(desiredWidth, availableWidth);
    _panelWidth = panelWidth;

    return SafeArea(
      minimum: const EdgeInsets.all(8),
      child: Align(
        alignment: Alignment.centerRight,
        child: RawGestureDetector(
          behavior: HitTestBehavior.translucent,
          gestures: <Type, GestureRecognizerFactory>{
            _IntentionalHorizontalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  _IntentionalHorizontalDragGestureRecognizer
                >(
                  () => _IntentionalHorizontalDragGestureRecognizer(
                    activationDistance: _activationDistance,
                  ),
                  (recognizer) {
                    recognizer
                      ..activationDistance = _activationDistance
                      ..dragStartBehavior = DragStartBehavior.start
                      ..onStart = _handleHorizontalDragStart
                      ..onUpdate = _handleHorizontalDragUpdate
                      ..onEnd = _handleHorizontalDragEnd
                      ..onCancel = _handleHorizontalDragCancel;
                  },
                ),
          },
          child: AnimatedBuilder(
            animation: _dismissController,
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
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                    ),
                    Expanded(child: widget.builder(context, _scrollController)),
                  ],
                ),
              ),
            ),
            builder: (context, child) => Transform.translate(
              offset: Offset(_dismissController.value * panelWidth, 0),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _dismissController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
}

class _IntentionalHorizontalDragGestureRecognizer
    extends HorizontalDragGestureRecognizer {
  _IntentionalHorizontalDragGestureRecognizer({
    required this.activationDistance,
  });

  double activationDistance;

  @override
  bool hasSufficientGlobalDistanceToAccept(
    PointerDeviceKind pointerDeviceKind,
    double? deviceTouchSlop,
  ) {
    return globalDistanceMoved > activationDistance;
  }

  @override
  String get debugDescription => 'intentional right swipe';
}
