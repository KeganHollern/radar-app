import 'package:flutter/material.dart';

/// Positions map controls without changing the established portrait layout.
///
/// Portrait keeps the live card at the top and the radar controls at the
/// bottom. Landscape moves those groups into narrow left and right rails so
/// the center of the map remains useful on short screens.
class ResponsiveMapChrome extends StatelessWidget {
  const ResponsiveMapChrome({
    required this.status,
    required this.statusBanners,
    required this.legend,
    required this.radarControls,
    required this.settingsButton,
    required this.attributionButton,
    required this.pinButton,
    super.key,
  });

  final Widget status;
  final List<Widget> statusBanners;
  final Widget legend;
  final Widget radarControls;
  final Widget settingsButton;
  final Widget attributionButton;
  final Widget pinButton;

  @override
  Widget build(BuildContext context) {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return SafeArea(
      minimum: landscape
          ? const EdgeInsets.fromLTRB(12, 8, 12, 8)
          : const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: landscape ? _buildLandscape() : _buildPortrait(),
    );
  }

  Widget _buildPortrait() {
    return Column(
      key: const ValueKey('portrait-map-chrome'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        status,
        if (statusBanners.isNotEmpty) ...[
          const SizedBox(height: 8),
          ..._withVerticalGaps(statusBanners, 8),
        ],
        const Spacer(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [legend, const SizedBox(height: 8), radarControls],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                attributionButton,
                const SizedBox(height: 8),
                pinButton,
              ],
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildLandscape() {
    return LayoutBuilder(
      builder: (context, constraints) {
        var leftWidth = (constraints.maxWidth * 0.28)
            .clamp(190.0, 270.0)
            .toDouble();
        var rightWidth = (constraints.maxWidth * 0.31)
            .clamp(230.0, 320.0)
            .toDouble();
        const minimumMapGap = 80.0;
        final railBudget = (constraints.maxWidth - minimumMapGap).clamp(
          0.0,
          constraints.maxWidth,
        );
        if (leftWidth + rightWidth > railBudget) {
          final scale = railBudget / (leftWidth + rightWidth);
          leftWidth *= scale;
          rightWidth *= scale;
        }
        return Stack(
          key: const ValueKey('landscape-map-chrome'),
          children: [
            Positioned(
              top: 0,
              bottom: 0,
              left: 0,
              width: leftWidth,
              child: Column(
                key: const ValueKey('landscape-status-rail'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  status,
                  if (statusBanners.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView(
                        key: const ValueKey('landscape-status-list'),
                        padding: EdgeInsets.zero,
                        children: _withVerticalGaps(statusBanners, 8),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: rightWidth,
              child: Column(
                key: const ValueKey('landscape-controls-rail'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const ValueKey('landscape-controls-scroll'),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          legend,
                          const SizedBox(height: 8),
                          radarControls,
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    key: const ValueKey('landscape-utility-controls'),
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      settingsButton,
                      const SizedBox(width: 8),
                      attributionButton,
                      const SizedBox(width: 8),
                      pinButton,
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

List<Widget> _withVerticalGaps(List<Widget> children, double gap) {
  return [
    for (var index = 0; index < children.length; index++) ...[
      if (index > 0) SizedBox(height: gap),
      children[index],
    ],
  ];
}
