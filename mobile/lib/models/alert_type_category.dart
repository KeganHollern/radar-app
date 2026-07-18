enum AlertTypeCategory {
  stormsAndWind(
    storageKey: 'storms-wind',
    label: 'Storms & wind',
    description: 'Tornadoes, thunderstorms, damaging wind, and dust',
  ),
  floodingAndTropical(
    storageKey: 'flooding-tropical',
    label: 'Flooding & tropical',
    description: 'Flood, coastal, tropical, storm surge, and tsunami alerts',
  ),
  winter(
    storageKey: 'winter',
    label: 'Winter weather',
    description: 'Snow, ice, blizzard, and freezing conditions',
  ),
  heatFireAndAir(
    storageKey: 'heat-fire-air',
    label: 'Heat, fire & air',
    description: 'Heat, fire danger, smoke, and air quality',
  ),
  other(
    storageKey: 'other',
    label: 'Other alerts',
    description: 'Statements and alert types outside the groups above',
  );

  const AlertTypeCategory({
    required this.storageKey,
    required this.label,
    required this.description,
  });

  final String storageKey;
  final String label;
  final String description;
}

final class AlertTypeGroup {
  const AlertTypeGroup({required this.category, required this.types});

  final AlertTypeCategory category;
  final List<String> types;
}

List<AlertTypeGroup> groupAlertTypes(Iterable<String> alertTypes) {
  final grouped = <AlertTypeCategory, List<String>>{
    for (final category in AlertTypeCategory.values) category: <String>[],
  };
  final seen = <String>{};
  for (final rawType in alertTypes) {
    final type = rawType.trim();
    final normalized = type.toLowerCase();
    if (normalized.isEmpty || !seen.add(normalized)) continue;
    grouped[_categoryFor(normalized)]!.add(type);
  }

  return [
    for (final category in AlertTypeCategory.values)
      if (grouped[category]!.isNotEmpty)
        AlertTypeGroup(
          category: category,
          types: List.unmodifiable(
            grouped[category]!..sort(
              (left, right) =>
                  left.toLowerCase().compareTo(right.toLowerCase()),
            ),
          ),
        ),
  ];
}

AlertTypeCategory _categoryFor(String type) {
  if (_containsAny(type, const [
    'winter',
    'blizzard',
    'ice storm',
    'snow',
    'freeze',
    'freezing',
    'frost',
  ])) {
    return AlertTypeCategory.winter;
  }
  if (_containsAny(type, const [
    'flood',
    'hurricane',
    'tropical',
    'storm surge',
    'tsunami',
    'coastal',
  ])) {
    return AlertTypeCategory.floodingAndTropical;
  }
  if (_containsAny(type, const [
    'heat',
    'fire',
    'red flag',
    'air quality',
    'smoke',
  ])) {
    return AlertTypeCategory.heatFireAndAir;
  }
  if (_containsAny(type, const [
    'tornado',
    'thunderstorm',
    'wind',
    'dust',
    'hail',
  ])) {
    return AlertTypeCategory.stormsAndWind;
  }
  return AlertTypeCategory.other;
}

bool _containsAny(String value, Iterable<String> terms) =>
    terms.any(value.contains);
