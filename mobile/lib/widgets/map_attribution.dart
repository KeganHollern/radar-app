import 'package:flutter/material.dart';

import '../models/data_attribution.dart';
import '../theme/flexoki_theme.dart';

typedef AttributionLinkOpener = Future<void> Function(Uri uri);

/// Shared square size for the compact map utility controls. Two controls plus
/// their 8 px gap match the default Nearby legend and mode stack at 112 px.
const mapUtilityButtonDimension = 52.0;

const _weatherAttributions = [
  DataAttribution(
    label: 'NOAA / National Weather Service',
    url: 'https://www.weather.gov/',
  ),
];

/// Replaces MapLibre's platform-owned attribution hit target with a compact,
/// reliable Flutter control. Full provider credits remain in the opened panel.
class MapAttributionButton extends StatelessWidget {
  const MapAttributionButton({
    required this.credit,
    required this.onPressed,
    super.key,
  });

  final String credit;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      key: const ValueKey('map-attribution-semantics'),
      button: true,
      label: '$credit; map and weather data sources',
      onTap: onPressed,
      excludeSemantics: true,
      child: Material(
        color: Flexoki.base100,
        elevation: 9,
        shadowColor: Colors.black87,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Flexoki.base300),
        ),
        child: InkWell(
          key: const ValueKey('map-attribution-button'),
          onTap: onPressed,
          borderRadius: BorderRadius.circular(16),
          child: const SizedBox.square(
            dimension: mapUtilityButtonDimension,
            child: Icon(
              Icons.info_outline_rounded,
              size: 28,
              color: Flexoki.paper,
            ),
          ),
        ),
      ),
    );
  }
}

class MapAttributionPanel extends StatelessWidget {
  const MapAttributionPanel({
    required this.mapAttributions,
    required this.onOpenLink,
    super.key,
  });

  final List<DataAttribution> mapAttributions;
  final AttributionLinkOpener onOpenLink;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Data sources',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 14),
            const _SourceHeading(
              icon: Icons.map_outlined,
              title: 'Map',
              description:
                  'Basemap provider, schema, and map-data credits for this build.',
            ),
            const SizedBox(height: 8),
            _SourceLinks(links: mapAttributions, onOpenLink: onOpenLink),
            const SizedBox(height: 20),
            const _SourceHeading(
              icon: Icons.radar_rounded,
              title: 'Live weather',
              description:
                  'Live radar imagery and active alerts are derived from NOAA and National Weather Service data.',
            ),
            const SizedBox(height: 8),
            _SourceLinks(links: _weatherAttributions, onOpenLink: onOpenLink),
            const SizedBox(height: 18),
            const Text(
              'HyprRadar is not affiliated with or endorsed by NOAA or the National Weather Service.',
              style: TextStyle(color: Flexoki.base500, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _SourceHeading extends StatelessWidget {
  const _SourceHeading({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, color: Flexoki.cyan, size: 21),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 3),
              Text(
                description,
                style: const TextStyle(color: Flexoki.base500, fontSize: 13),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SourceLinks extends StatelessWidget {
  const _SourceLinks({required this.links, required this.onOpenLink});

  final Iterable<DataAttribution> links;
  final AttributionLinkOpener onOpenLink;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      children: [
        for (final link in links)
          Builder(
            builder: (context) {
              final uri = link.uri;
              return TextButton.icon(
                key: ValueKey('attribution-link-${link.label}'),
                onPressed: uri == null ? null : () => onOpenLink(uri),
                icon: const Icon(Icons.open_in_new_rounded, size: 14),
                iconAlignment: IconAlignment.end,
                label: Text(link.label),
              );
            },
          ),
      ],
    );
  }
}
