import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/controllers/alert_notification_controller.dart';
import 'package:radar_mobile/models/alert_notification_models.dart';
import 'package:radar_mobile/services/alert_notification_background.dart';
import 'package:radar_mobile/services/alert_notification_permissions.dart';
import 'package:radar_mobile/services/alert_notification_store.dart';
import 'package:radar_mobile/theme/flexoki_theme.dart';
import 'package:radar_mobile/widgets/settings_panel.dart';

void main() {
  testWidgets(
    'denied notification permission disables controls and offers recovery',
    (tester) async {
      final controller = await _controller(_denied);
      await _pumpSettings(tester, controller);

      expect(find.text('Notifications are disabled'), findsOneWidget);
      expect(find.text('Enable permissions'), findsOneWidget);
      final tornado = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('notification-alert-type-Tornado Warning')),
      );
      expect(tornado.value, isTrue);
      expect(tornado.onChanged, isNull);
      controller.dispose();
    },
  );

  testWidgets('scope and alert types update independently from map visibility', (
    tester,
  ) async {
    final controller = await _controller(_granted);
    await _pumpSettings(tester, controller);

    expect(find.text('Near me'), findsOneWidget);
    expect(controller.isAlertTypeEnabled('Tornado Warning'), isTrue);
    expect(controller.isAlertTypeEnabled('Air Quality Alert'), isFalse);

    await tester.tap(find.text('Nationwide'));
    await tester.pump();
    expect(controller.preferences.scope, AlertNotificationScope.nationwide);

    await tester.tap(
      find.byKey(const ValueKey('notification-alert-type-Air Quality Alert')),
    );
    await tester.pump();
    expect(controller.isAlertTypeEnabled('Air Quality Alert'), isTrue);

    await tester.tap(
      find.byKey(const ValueKey('disable-all-alert-notifications')),
    );
    await tester.pump();
    expect(controller.preferences.enabledTypes, isEmpty);
    expect(
      find.text(
        'Background notifications are off. No location or network checks are scheduled.',
      ),
      findsOneWidget,
    );
    controller.dispose();
  });
}

Future<AlertNotificationController> _controller(
  AlertNotificationPermissionSnapshot permissions,
) async {
  final controller = AlertNotificationController(
    store: _MemoryStore(AlertNotificationPreferences.defaults()),
    permissions: _FakePermissions(permissions),
    scheduler: _FakeScheduler(),
  );
  await controller.initialize();
  return controller;
}

Future<void> _pumpSettings(
  WidgetTester tester,
  AlertNotificationController controller,
) => tester.pumpWidget(
  MaterialApp(
    theme: Flexoki.darkTheme,
    home: Scaffold(
      body: RadarSettingsPanel(
        notificationController: controller,
        alertTypes: const ['Air Quality Alert', 'Tornado Warning'],
        alertTypeCounts: const {},
        isAlertTypeVisible: (_) => true,
        onAlertTypeChanged: (_, _) {},
        onShowAllAlertTypes: () {},
      ),
    ),
  ),
);

const _granted = AlertNotificationPermissionSnapshot(
  supported: true,
  notificationsGranted: true,
  foregroundLocationGranted: true,
  backgroundLocationGranted: true,
);

const _denied = AlertNotificationPermissionSnapshot(
  supported: true,
  notificationsGranted: false,
  foregroundLocationGranted: true,
  backgroundLocationGranted: false,
  notificationsPermanentlyDenied: true,
);

final class _MemoryStore implements AlertNotificationStore {
  _MemoryStore(this.preferences);

  AlertNotificationPreferences preferences;
  AlertNotificationLedger ledger = AlertNotificationLedger();

  @override
  Future<AlertNotificationLedger> loadLedger() async => ledger;

  @override
  Future<AlertNotificationPreferences> loadPreferences() async => preferences;

  @override
  Future<void> saveLedger(AlertNotificationLedger value) async {
    ledger = value;
  }

  @override
  Future<void> savePreferences(AlertNotificationPreferences value) async {
    preferences = value;
  }
}

final class _FakePermissions implements AlertNotificationPermissionGateway {
  _FakePermissions(this.value);

  final AlertNotificationPermissionSnapshot value;

  @override
  Future<bool> openSettings() async => true;

  @override
  Future<AlertNotificationPermissionSnapshot>
  requestBackgroundLocation() async => value;

  @override
  Future<AlertNotificationPermissionSnapshot> requestNotifications() async =>
      value;

  @override
  Future<AlertNotificationPermissionSnapshot> status() async => value;
}

final class _FakeScheduler implements AlertNotificationScheduler {
  @override
  Future<void> sync({required bool enabled}) async {}
}
