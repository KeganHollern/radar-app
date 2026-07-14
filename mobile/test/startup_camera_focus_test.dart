import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:radar_mobile/controllers/startup_camera_focus.dart';

void main() {
  const firstLocation = LatLng(30.2672, -97.7431);
  const newerLocation = LatLng(30.2710, -97.7500);

  test('waits for both the map and first user location', () {
    final focus = StartupCameraFocus();

    expect(focus.takeTarget(mapReady: true), isNull);

    focus.updateLocation(firstLocation);
    expect(focus.takeTarget(mapReady: false), isNull);
    expect(focus.takeTarget(mapReady: true), firstLocation);
    expect(focus.takeTarget(mapReady: true), isNull);
  });

  test('successful startup focus happens only once', () {
    final focus = StartupCameraFocus()..updateLocation(firstLocation);

    expect(focus.takeTarget(mapReady: true), firstLocation);
    focus.finish(succeeded: true);
    focus.updateLocation(newerLocation);

    expect(focus.takeTarget(mapReady: true), isNull);
  });

  test('a rejected native animation can retry with the latest location', () {
    final focus = StartupCameraFocus()..updateLocation(firstLocation);

    expect(focus.takeTarget(mapReady: true), firstLocation);
    focus.finish(succeeded: false);
    focus.updateLocation(newerLocation);

    expect(focus.takeTarget(mapReady: true), newerLocation);
  });

  test('map interaction cancels a pending startup focus', () {
    final focus = StartupCameraFocus()..updateLocation(firstLocation);

    focus.abandon();
    focus.updateLocation(newerLocation);

    expect(focus.takeTarget(mapReady: true), isNull);
  });

  test('abandoning during an animation cannot be undone by its completion', () {
    final focus = StartupCameraFocus()..updateLocation(firstLocation);

    expect(focus.takeTarget(mapReady: true), firstLocation);
    focus.abandon();
    focus.finish(succeeded: true);
    focus.updateLocation(newerLocation);

    expect(focus.takeTarget(mapReady: true), isNull);
  });

  test('uses a neighborhood-scale startup zoom', () {
    expect(StartupCameraFocus.zoom, 8);
  });
}
