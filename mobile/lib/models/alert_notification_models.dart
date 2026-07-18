import 'dart:convert';

enum AlertNotificationScope {
  nearby('nearby', 'Near me'),
  nationwide('nationwide', 'Nationwide');

  const AlertNotificationScope(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static AlertNotificationScope fromStorage(String? value) =>
      values.where((scope) => scope.storageValue == value).firstOrNull ??
      AlertNotificationScope.nearby;
}

const alertNotificationTypeCatalog = <String>[
  'Tornado Warning',
  'Extreme Wind Warning',
  'Severe Thunderstorm Warning',
  'Flash Flood Warning',
  'Flood Warning',
  'Hurricane Warning',
  'Tropical Storm Warning',
  'Storm Surge Warning',
  'Tsunami Warning',
  'Blizzard Warning',
  'Ice Storm Warning',
  'Winter Storm Warning',
  'Snow Squall Warning',
  'Dust Storm Warning',
  'High Wind Warning',
  'Red Flag Warning',
  'Fire Warning',
  'Extreme Heat Warning',
  'Excessive Heat Warning',
  'Heat Advisory',
  'Coastal Flood Warning',
  'Air Quality Alert',
  'Special Weather Statement',
];

const defaultAlertNotificationTypes = <String>{
  'tornado warning',
  'extreme wind warning',
  'flash flood warning',
  'hurricane warning',
  'storm surge warning',
  'tsunami warning',
};

String normalizeAlertType(String value) => value.trim().toLowerCase();

List<String> mergedAlertNotificationTypes(Iterable<String> learnedTypes) {
  final labels = <String, String>{};
  for (final label in [...alertNotificationTypeCatalog, ...learnedTypes]) {
    final normalized = normalizeAlertType(label);
    if (normalized.isNotEmpty) labels.putIfAbsent(normalized, () => label);
  }
  final result = labels.values.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return List.unmodifiable(result);
}

final class AlertNotificationPreferences {
  AlertNotificationPreferences({
    required Iterable<String> enabledTypes,
    this.scope = AlertNotificationScope.nearby,
    this.onboardingCompleted = false,
    this.monitoringEnabled = false,
    this.baselineGeneration = 0,
    Map<String, int> typeGenerations = const {},
  }) : enabledTypes = Set.unmodifiable(
         enabledTypes.map(normalizeAlertType).where((type) => type.isNotEmpty),
       ),
       typeGenerations = Map.unmodifiable({
         for (final entry in typeGenerations.entries)
           if (normalizeAlertType(entry.key).isNotEmpty)
             normalizeAlertType(entry.key): entry.value,
       });

  factory AlertNotificationPreferences.defaults() =>
      AlertNotificationPreferences(enabledTypes: defaultAlertNotificationTypes);

  factory AlertNotificationPreferences.fromJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('Expected an object');
    final json = Map<String, dynamic>.from(decoded);
    final rawTypes = json['enabledTypes'];
    final enabledTypes = rawTypes is List
        ? rawTypes.whereType<String>()
        : const <String>[];
    final rawGenerations = json['typeGenerations'];
    final typeGenerations = <String, int>{};
    if (rawGenerations is Map) {
      for (final entry in rawGenerations.entries) {
        if (entry.value is int) {
          typeGenerations[entry.key.toString()] = entry.value as int;
        }
      }
    }
    return AlertNotificationPreferences(
      enabledTypes: enabledTypes,
      scope: AlertNotificationScope.fromStorage(json['scope']?.toString()),
      onboardingCompleted: json['onboardingCompleted'] == true,
      monitoringEnabled: json['monitoringEnabled'] == true,
      baselineGeneration: json['baselineGeneration'] is int
          ? json['baselineGeneration'] as int
          : 0,
      typeGenerations: typeGenerations,
    );
  }

  final Set<String> enabledTypes;
  final AlertNotificationScope scope;
  final bool onboardingCompleted;
  final bool monitoringEnabled;
  final int baselineGeneration;
  final Map<String, int> typeGenerations;

  bool isEnabled(String alertType) =>
      enabledTypes.contains(normalizeAlertType(alertType));

  int typeGeneration(String alertType) =>
      typeGenerations[normalizeAlertType(alertType)] ?? 0;

  AlertNotificationPreferences copyWith({
    Iterable<String>? enabledTypes,
    AlertNotificationScope? scope,
    bool? onboardingCompleted,
    bool? monitoringEnabled,
    int? baselineGeneration,
    Map<String, int>? typeGenerations,
  }) => AlertNotificationPreferences(
    enabledTypes: enabledTypes ?? this.enabledTypes,
    scope: scope ?? this.scope,
    onboardingCompleted: onboardingCompleted ?? this.onboardingCompleted,
    monitoringEnabled: monitoringEnabled ?? this.monitoringEnabled,
    baselineGeneration: baselineGeneration ?? this.baselineGeneration,
    typeGenerations: typeGenerations ?? this.typeGenerations,
  );

  String toJson() {
    final types = enabledTypes.toList()..sort();
    return jsonEncode({
      'enabledTypes': types,
      'scope': scope.storageValue,
      'onboardingCompleted': onboardingCompleted,
      'monitoringEnabled': monitoringEnabled,
      'baselineGeneration': baselineGeneration,
      'typeGenerations': typeGenerations,
    });
  }
}

final class AlertNotificationPermissionSnapshot {
  const AlertNotificationPermissionSnapshot({
    required this.supported,
    required this.notificationsGranted,
    required this.foregroundLocationGranted,
    required this.backgroundLocationGranted,
    this.notificationsPermanentlyDenied = false,
    this.backgroundLocationPermanentlyDenied = false,
  });

  const AlertNotificationPermissionSnapshot.unsupported()
    : supported = false,
      notificationsGranted = false,
      foregroundLocationGranted = false,
      backgroundLocationGranted = false,
      notificationsPermanentlyDenied = false,
      backgroundLocationPermanentlyDenied = false;

  final bool supported;
  final bool notificationsGranted;
  final bool foregroundLocationGranted;
  final bool backgroundLocationGranted;
  final bool notificationsPermanentlyDenied;
  final bool backgroundLocationPermanentlyDenied;
}

final class AlertNotificationLedger {
  AlertNotificationLedger({
    Map<String, int> seenUntilEpochMs = const {},
    Map<String, int> baselineUntilEpochMs = const {},
    Map<String, int> initializedTypeGenerations = const {},
    this.scope,
    this.baselineGeneration = -1,
  }) : seenUntilEpochMs = Map.unmodifiable(seenUntilEpochMs),
       baselineUntilEpochMs = Map.unmodifiable(baselineUntilEpochMs),
       initializedTypeGenerations = Map.unmodifiable({
         for (final entry in initializedTypeGenerations.entries)
           if (normalizeAlertType(entry.key).isNotEmpty)
             normalizeAlertType(entry.key): entry.value,
       });

  factory AlertNotificationLedger.fromJson(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('Expected an object');
    final json = Map<String, dynamic>.from(decoded);
    final rawSeen = json['seenUntil'];
    final seen = <String, int>{};
    if (rawSeen is Map) {
      for (final entry in rawSeen.entries) {
        final value = entry.value;
        if (value is int && entry.key.toString().isNotEmpty) {
          seen[entry.key.toString()] = value;
        }
      }
    }
    final rawBaseline = json['baselineUntil'];
    final baseline = <String, int>{};
    if (rawBaseline is Map) {
      for (final entry in rawBaseline.entries) {
        final value = entry.value;
        if (value is int && entry.key.toString().isNotEmpty) {
          baseline[entry.key.toString()] = value;
        }
      }
    }
    final rawTypeGenerations = json['initializedTypeGenerations'];
    final typeGenerations = <String, int>{};
    if (rawTypeGenerations is Map) {
      for (final entry in rawTypeGenerations.entries) {
        if (entry.value is int) {
          typeGenerations[entry.key.toString()] = entry.value as int;
        }
      }
    } else {
      final rawTypes = json['initializedTypes'];
      if (rawTypes is List) {
        for (final type in rawTypes.whereType<String>()) {
          typeGenerations[type] = 0;
        }
      }
    }
    final rawScope = json['scope']?.toString();
    return AlertNotificationLedger(
      seenUntilEpochMs: seen,
      baselineUntilEpochMs: baseline,
      initializedTypeGenerations: typeGenerations,
      scope: rawScope == null
          ? null
          : AlertNotificationScope.fromStorage(rawScope),
      baselineGeneration: json['baselineGeneration'] is int
          ? json['baselineGeneration'] as int
          : -1,
    );
  }

  final Map<String, int> seenUntilEpochMs;
  final Map<String, int> baselineUntilEpochMs;
  final Map<String, int> initializedTypeGenerations;
  final AlertNotificationScope? scope;
  final int baselineGeneration;

  Set<String> get initializedTypes => initializedTypeGenerations.keys.toSet();

  String toJson() {
    return jsonEncode({
      'seenUntil': seenUntilEpochMs,
      'baselineUntil': baselineUntilEpochMs,
      'initializedTypeGenerations': initializedTypeGenerations,
      'scope': scope?.storageValue,
      'baselineGeneration': baselineGeneration,
    });
  }
}
