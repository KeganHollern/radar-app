import 'package:flutter/material.dart';

import '../models/radar_models.dart';
import '../theme/flexoki_theme.dart';

/// A compact interpretation key for the active NOAA radar product.
///
/// The color stops mirror the legends emitted by the NOAA/NWS RIDGE WMS
/// products used by the backend.
class RadarLegend extends StatelessWidget {
  const RadarLegend({required this.mode, super.key});

  final RadarMode mode;

  bool get _isVelocity => mode == RadarMode.stationVelocity;
  bool get _isDeclutteredReflectivity => mode == RadarMode.stationReflectivity;

  @override
  Widget build(BuildContext context) {
    final palette = _isVelocity
        ? _velocityPalette
        : _isDeclutteredReflectivity
        ? _stationReflectivityPalette
        : _reflectivityPalette;
    return Semantics(
      container: true,
      label: _isVelocity
          ? 'Radial velocity color scale in knots. Negative values mean motion toward the radar, zero is in the center, and positive values mean motion away from the radar. The separate RF swatch means range-folded or unresolved data, not a velocity value.'
          : _isDeclutteredReflectivity
          ? 'Station reflectivity color scale in dBZ, from light echoes to intense echoes. Weak returns below 15 dBZ are hidden.'
          : 'Reflectivity color scale in dBZ, from light echoes to intense echoes.',
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
                  Text(
                    _isVelocity ? 'RADIAL VELOCITY' : 'REFLECTIVITY',
                    style: const TextStyle(
                      color: Flexoki.paper,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.7,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _isVelocity
                        ? 'knots · RF = unresolved'
                        : _isDeclutteredReflectivity
                        ? 'dBZ · <15 hidden'
                        : 'dBZ',
                    style: const TextStyle(
                      color: Flexoki.base500,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
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
                              children: const [
                                Text('-100 · toward'),
                                Spacer(),
                                Text('0'),
                                Spacer(),
                                Text('+100 · away'),
                              ],
                            ),
                          ),
                        ],
                      )
                    : Row(
                        children: [
                          Text(
                            _isDeclutteredReflectivity
                                ? '15 · light'
                                : '-20 · weak',
                          ),
                          const Spacer(),
                          Text(_isDeclutteredReflectivity ? '40' : '30'),
                          const Spacer(),
                          const Text('70 · intense'),
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

// Sampled from the NOAA/NWS RIDGE BREF.QCD and SR_BREF WMS legends. The weak
// end includes gray/pale tones before blue, then transitions through green,
// yellow, red, magenta, and violet as dBZ increases.
const _reflectivityPalette = <Color>[
  Color(0xFF8D817F),
  Color(0xFFB2B284),
  Color(0xFFAFB5B4),
  Color(0xFF6275A7),
  Color(0xFF5DADCE),
  Color(0xFF0ED413),
  Color(0xFF0D6008),
  Color(0xFFEAB32D),
  Color(0xFFA20F10),
  Color(0xFFE374FC),
  Color(0xFF5A00D3),
];

// Station tiles are decluttered below 15 dBZ by the API. Start their key at
// NOAA's 15 dBZ cyan-green transition so hidden colors are not advertised.
const _stationReflectivityPalette = <Color>[
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
