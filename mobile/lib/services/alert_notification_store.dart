import 'package:shared_preferences/shared_preferences.dart';

import '../models/alert_notification_models.dart';

const _preferencesKey = 'alerts.notifications.preferences.v1';
const _ledgerKey = 'alerts.notifications.ledger.v1';

abstract interface class AlertNotificationStore {
  Future<AlertNotificationPreferences> loadPreferences();

  Future<void> savePreferences(AlertNotificationPreferences preferences);

  Future<AlertNotificationLedger> loadLedger();

  Future<void> saveLedger(AlertNotificationLedger ledger);
}

final class SharedPreferencesAlertNotificationStore
    implements AlertNotificationStore {
  SharedPreferencesAlertNotificationStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<AlertNotificationPreferences> loadPreferences() async {
    final source = await _preferences.getString(_preferencesKey);
    if (source == null) return AlertNotificationPreferences.defaults();
    try {
      return AlertNotificationPreferences.fromJson(source);
    } catch (_) {
      return AlertNotificationPreferences.defaults();
    }
  }

  @override
  Future<void> savePreferences(AlertNotificationPreferences preferences) =>
      _preferences.setString(_preferencesKey, preferences.toJson());

  @override
  Future<AlertNotificationLedger> loadLedger() async {
    final source = await _preferences.getString(_ledgerKey);
    if (source == null) return AlertNotificationLedger();
    try {
      return AlertNotificationLedger.fromJson(source);
    } catch (_) {
      return AlertNotificationLedger();
    }
  }

  @override
  Future<void> saveLedger(AlertNotificationLedger ledger) =>
      _preferences.setString(_ledgerKey, ledger.toJson());
}
