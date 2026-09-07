import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/services/alert_local_notifier.dart';
import 'package:radar_mobile/services/alert_notification_permissions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter.baseflow.com/permissions/methods');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'checkPermissionStatus') return 1;
          if (call.method == 'openAppSettings') {
            throw PlatformException(code: 'settings_unavailable');
          }
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'a disabled weather channel blocks delivery despite app permission',
    () async {
      final permissions = PlatformAlertNotificationPermissionGateway(
        supported: true,
        notifications: _Channels(Importance.none),
      );

      final status = await permissions.status();

      expect(status.supported, isTrue);
      expect(status.notificationsGranted, isFalse);
      expect(status.backgroundLocationGranted, isTrue);
    },
  );

  test('an enabled weather channel permits delivery', () async {
    final permissions = PlatformAlertNotificationPermissionGateway(
      supported: true,
      notifications: _Channels(Importance.high),
    );

    expect((await permissions.status()).notificationsGranted, isTrue);
  });

  test(
    'a fresh install can notify before the weather channel exists',
    () async {
      final permissions = PlatformAlertNotificationPermissionGateway(
        supported: true,
        notifications: _Channels(null),
      );

      expect((await permissions.status()).notificationsGranted, isTrue);
    },
  );

  test('settings platform failures return false instead of escaping', () async {
    final permissions = PlatformAlertNotificationPermissionGateway(
      supported: true,
      notifications: _Channels(Importance.high),
    );

    expect(await permissions.openSettings(), isFalse);
  });
}

class _Channels extends AndroidFlutterLocalNotificationsPlugin {
  _Channels(this.importance);

  final Importance? importance;

  @override
  Future<List<AndroidNotificationChannel>?> getNotificationChannels() async => [
    if (importance != null)
      AndroidNotificationChannel(
        LocalWeatherAlertNotifier.channelId,
        LocalWeatherAlertNotifier.channelName,
        importance: importance!,
      ),
  ];
}
