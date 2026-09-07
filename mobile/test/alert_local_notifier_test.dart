import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/services/alert_local_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'initialize' ? true : null;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('test delivery initializes the real weather channel and icon', () async {
    final notifier = LocalWeatherAlertNotifier();

    await notifier.showTest();

    expect(calls.map((call) => call.method), [
      'initialize',
      'createNotificationChannel',
      'show',
    ]);
    expect(calls.first.arguments['defaultIcon'], 'ic_stat_radar');
    expect(calls[1].arguments['id'], LocalWeatherAlertNotifier.channelId);
    final notification = calls.last.arguments;
    expect(notification['title'], 'HyprRadar test notification');
    expect(notification['body'], startsWith('This is a test.'));
    expect(notification['platformSpecifics']['icon'], 'ic_stat_radar');
    expect(notification['platformSpecifics']['onlyAlertOnce'], isFalse);
    expect(
      notification['platformSpecifics']['channelId'],
      LocalWeatherAlertNotifier.channelId,
    );
  });
}
