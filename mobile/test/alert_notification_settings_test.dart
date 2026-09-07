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
  testWidgets('test delivery is available without enabling background checks', (
    tester,
  ) async {
    var sent = 0;
    final controller = AlertNotificationController(
      store: _MemoryStore(AlertNotificationPreferences.defaults()),
      permissions: _FakePermissions(_granted),
      scheduler: _FakeScheduler(),
      sendTestNotification: () async {
        sent++;
      },
    );
    await controller.initialize();
    await _pumpSettings(tester, controller);
    await tester.tap(
      find.byKey(const ValueKey('settings-destination-notifications')),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('send-test-alert-notification'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(sent, 1);
    expect(find.textContaining('Test sent.'), findsOneWidget);
    expect(controller.preferences.monitoringEnabled, isFalse);
    controller.dispose();
  });

  testWidgets(
    'denied notification permission disables controls and offers recovery',
    (tester) async {
      final controller = await _controller(_denied);
      await _pumpSettings(tester, controller);

      await tester.tap(
        find.byKey(const ValueKey('settings-destination-notifications')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Notifications are disabled'), findsOneWidget);
      expect(find.text('Enable permissions'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('notification-alert-type-Tornado Warning')),
        findsNothing,
      );

      await tester.tap(
        find.byKey(const ValueKey('notification-alert-category-storms-wind')),
      );
      await tester.pumpAndSettle();
      final tornado = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('notification-alert-type-Tornado Warning')),
      );
      expect(tornado.value, isTrue);
      expect(tornado.onChanged, isNull);
      controller.dispose();
    },
  );

  testWidgets(
    'background location disclosure immediately precedes the permission request',
    (tester) async {
      final permissions = _FakePermissions(
        const AlertNotificationPermissionSnapshot(
          supported: true,
          notificationsGranted: true,
          foregroundLocationGranted: true,
          backgroundLocationGranted: false,
        ),
      );
      final controller = AlertNotificationController(
        store: _MemoryStore(
          AlertNotificationPreferences.defaults().copyWith(
            backgroundLocationDisclosureVersion:
                currentBackgroundLocationDisclosureVersion,
          ),
        ),
        permissions: permissions,
        scheduler: _FakeScheduler(),
      );
      await controller.initialize();
      await _pumpSettings(tester, controller);

      await tester.tap(
        find.byKey(const ValueKey('settings-destination-notifications')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enable background location'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('background-location-disclosure-continue')),
        findsOneWidget,
      );
      expect(
        find.textContaining('even when the app is closed'),
        findsOneWidget,
      );
      expect(find.textContaining('HTTPS request body'), findsOneWidget);
      expect(permissions.backgroundRequests, 0);

      await tester.tap(
        find.byKey(const ValueKey('background-location-disclosure-continue')),
      );
      await tester.pumpAndSettle();
      expect(permissions.backgroundRequests, 1);
      controller.dispose();
    },
  );

  testWidgets('scope and alert types update independently from map visibility', (
    tester,
  ) async {
    final controller = await _controller(_granted);
    await _pumpSettings(tester, controller);

    await tester.tap(
      find.byKey(const ValueKey('settings-destination-notifications')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Near me'), findsOneWidget);
    expect(controller.isAlertTypeEnabled('Tornado Warning'), isTrue);
    expect(controller.isAlertTypeEnabled('Air Quality Alert'), isFalse);

    await tester.tap(find.text('Nationwide'));
    await tester.pump();
    expect(controller.preferences.scope, AlertNotificationScope.nationwide);

    await tester.tap(
      find.byKey(const ValueKey('notification-alert-category-heat-fire-air')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('notification-alert-type-Air Quality Alert')),
    );
    await tester.pumpAndSettle();
    expect(controller.isAlertTypeEnabled('Air Quality Alert'), isTrue);

    await tester.tap(find.byKey(const ValueKey('settings-page-back')));
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey('disable-all-alert-notifications')),
    );
    await tester.pumpAndSettle();
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
  int backgroundRequests = 0;

  @override
  Future<bool> openSettings() async => true;

  @override
  Future<AlertNotificationPermissionSnapshot>
  requestBackgroundLocation() async {
    backgroundRequests++;
    return value;
  }

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
