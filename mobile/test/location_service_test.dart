import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:radar_mobile/services/location_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter.baseflow.com/geolocator');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  for (final failingMethod in ['checkPermission', 'requestPermission']) {
    test('$failingMethod platform failure leaves location retryable', () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == failingMethod) {
          throw PlatformException(code: 'ACTIVITY_UNAVAILABLE');
        }
        return call.method == 'isLocationServiceEnabled' ? true : 0;
      });

      final service = LocationService();
      expect(await service.requestAccess(), LocationAccess.denied);
      expect(calls, contains(failingMethod));

      messenger.setMockMethodCallHandler(channel, (call) async {
        return call.method == 'isLocationServiceEnabled' ? true : 2;
      });
      expect(await service.checkAccess(), LocationAccess.granted);
    });
  }

  test('checking location never opens a permission prompt', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return call.method == 'isLocationServiceEnabled' ? true : 0;
    });

    expect(await LocationService().checkAccess(), LocationAccess.denied);
    expect(calls, isNot(contains('requestPermission')));
  });
}
