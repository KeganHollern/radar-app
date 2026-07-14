import 'package:shared_preferences/shared_preferences.dart';

const _hiddenAlertTypesKey = 'alerts.hidden_types.v1';
const _knownAlertTypesKey = 'alerts.known_types.v1';

final class AlertVisibilityPreferences {
  const AlertVisibilityPreferences({
    this.hiddenTypes = const <String>{},
    this.knownTypes = const <String>{},
  });

  final Set<String> hiddenTypes;
  final Set<String> knownTypes;
}

abstract interface class AlertVisibilityStore {
  Future<AlertVisibilityPreferences> load();

  Future<void> save({
    required Set<String> hiddenTypes,
    required Set<String> knownTypes,
  });
}

final class SharedPreferencesAlertVisibilityStore
    implements AlertVisibilityStore {
  @override
  Future<AlertVisibilityPreferences> load() async {
    final preferences = await SharedPreferences.getInstance();
    return AlertVisibilityPreferences(
      hiddenTypes: (preferences.getStringList(_hiddenAlertTypesKey) ?? const [])
          .toSet(),
      knownTypes: (preferences.getStringList(_knownAlertTypesKey) ?? const [])
          .toSet(),
    );
  }

  @override
  Future<void> save({
    required Set<String> hiddenTypes,
    required Set<String> knownTypes,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final hidden = hiddenTypes.toList()..sort();
    final known = knownTypes.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await Future.wait([
      preferences.setStringList(_hiddenAlertTypesKey, hidden),
      preferences.setStringList(_knownAlertTypesKey, known),
    ]);
  }
}
