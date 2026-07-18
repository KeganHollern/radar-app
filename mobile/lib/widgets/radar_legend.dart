import 'package:flutter/material.dart';

import '../models/radar_models.dart';
import '../theme/flexoki_theme.dart';

/// A compact interpretation key for the active NOAA radar product.
///
/// The color stops mirror the legends emitted by the NOAA/NWS RIDGE WMS
/// products used by the backend.
class RadarLegend extends StatelessWidget {
  const RadarLegend({required this.mode, this.compact = false, super.key});

  final RadarMode mode;
  final bool compact;

  bool get _isVelocity => mode == RadarMode.stationVelocity;

  @override
  Widget build(BuildContext context) {
    final palette = _isVelocity
        ? _velocityPalette
        : _declutteredReflectivityPalette;
    return Semantics(
      container: true,
      label: _isVelocity
          ? 'Radial velocity color scale in knots. Negative values mean motion toward the radar, zero is in the center, and positive values mean motion away from the radar. The separate RF swatch means range-folded or unresolved data, not a velocity value.'
          : 'Reflectivity color scale in dBZ, from light echoes to intense echoes. Weak returns below 15 dBZ are hidden.',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 6),
          decoration: BoxDecoration(
            color: Flexoki.base100.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: Flexoki.base300),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 8,
                offset: Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      _isVelocity ? 'RADIAL VELOCITY' : 'REFLECTIVITY',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Flexoki.paper,
                        fontSize: 10,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.7,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Flexible(
                    child: Text(
                      _isVelocity
                          ? compact
                                ? 'knots'
                                : 'knots · RF = unresolved'
                          : compact
                          ? 'dBZ'
                          : 'dBZ · <15 hidden',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Flexoki.base500,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              ClipRRect(
                key: const Key('radar-legend-color-bar'),
                borderRadius: BorderRadius.circular(3),
                child: SizedBox(
                  width: double.infinity,
                  height: 9,
                  child: _isVelocity
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const SizedBox(
                              key: Key('radar-legend-rf-swatch'),
                              width: 18,
                              child: ColoredBox(color: _rangeFoldedColor),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(colors: palette),
                                ),
                              ),
                            ),
                          ],
                        )
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: palette),
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 2),
              DefaultTextStyle(
                style: const TextStyle(
                  color: Flexoki.base700,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
                child: _isVelocity
                    ? Row(
                        children: [
                          const SizedBox(width: 18, child: Text('RF')),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Row(
                              children: [
                                Text(compact ? '-100' : '-100 · toward'),
                                const Spacer(),
                                const Text('0'),
                                const Spacer(),
                                Text(compact ? '+100' : '+100 · away'),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Text(compact ? '15' : '15 · light'),
                          const Spacer(),
                          const Text('40'),
                          const Spacer(),
                          Text(compact ? '70' : '70 · intense'),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Nearby and station reflectivity tiles are decluttered below 15 dBZ by the
// API. Start their shared key at NOAA's 15 dBZ cyan-green transition so hidden
// colors are not advertised.
const _declutteredReflectivityPalette = <Color>[
  Color(0xFF58C2B9),
  Color(0xFF30D65B),
  Color(0xFF0DAF12),
  Color(0xFF0A730C),
  Color(0xFF84A005),
  Color(0xFFF5CB17),
  Color(0xFFF5B217),
  Color(0xFFD10809),
  Color(0xFFAA0809),
  Color(0xFFF1BAFE),
  Color(0xFFF175FE),
  Color(0xFF8300E7),
];

// Sampled from the numeric portion of the NOAA/NWS RIDGE SR_BVEL WMS legend.
// Negative velocity is toward the station and positive velocity is away from
// it. The source legend's separate RF color is range folded, not -100 knots.
const _rangeFoldedColor = Color(0xFFC8018B);

const _velocityPalette = <Color>[
  Color(0xFF970B7C),
  Color(0xFF480499),
  Color(0xFF29B0D2),
  Color(0xFFB1EDF0),
  Color(0xFF02BF02),
  Color(0xFF4A6E3F),
  Color(0xFF721416),
  Color(0xFFE60A10),
  Color(0xFFFFBCB8),
  Color(0xFFFC9458),
  Color(0xFFB24728),
];
