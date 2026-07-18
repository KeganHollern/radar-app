import 'package:shared_preferences/shared_preferences.dart';

const _lightningVisibilityKey = 'map.lightning.visible.v1';

abstract interface class LightningVisibilityStore {
  Future<bool> load();
  Future<void> save(bool enabled);
}

final class SharedPreferencesLightningVisibilityStore
    implements LightningVisibilityStore {
  SharedPreferencesLightningVisibilityStore({
    Future<SharedPreferences> Function()? loadPreferences,
  }) : _loadPreferences = loadPreferences ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _loadPreferences;

  @override
  Future<bool> load() async =>
      (await _loadPreferences()).getBool(_lightningVisibilityKey) ?? false;

  @override
  Future<void> save(bool enabled) async {
    await (await _loadPreferences()).setBool(_lightningVisibilityKey, enabled);
  }
}
