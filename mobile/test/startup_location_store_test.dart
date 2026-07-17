import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:radar_mobile/services/startup_location_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 7, 17, 15);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('round trips a recent accepted device location', () async {
    final store = SharedPreferencesStartupLocationStore(clock: () => now);
    final saved = StartupLocation(
      position: const LatLng(30.2672, -97.7431),
      observedAt: now.subtract(const Duration(minutes: 3)),
    );

    await store.save(saved);
    final loaded = await store.load();

    expect(loaded?.position, saved.position);
    expect(loaded?.observedAt, saved.observedAt);
  });

  test('missing and corrupt preferences fall back safely', () async {
    final store = SharedPreferencesStartupLocationStore(clock: () => now);
    expect(await store.load(), isNull);

    SharedPreferences.setMockInitialValues({
      'map.startup_location.v1': '{not json',
    });
    expect(await store.load(), isNull);
  });

  test('rejects unsupported, invalid, stale, and future records', () async {
    Future<StartupLocation?> load(Map<String, Object?> value) async {
      SharedPreferences.setMockInitialValues({
        'map.startup_location.v1': jsonEncode(value),
      });
      return SharedPreferencesStartupLocationStore(clock: () => now).load();
    }

    expect(
      await load({
        'schema': 2,
        'latitude': 30.2,
        'longitude': -97.7,
        'observedAtMillis': now.millisecondsSinceEpoch,
      }),
      isNull,
    );
    expect(
      await load({
        'schema': 1,
        'latitude': 90,
        'longitude': -97.7,
        'observedAtMillis': now.millisecondsSinceEpoch,
      }),
      isNull,
    );
    expect(
      await load({
        'schema': 1,
        'latitude': 30.2,
        'longitude': -97.7,
        'observedAtMillis': now
            .subtract(const Duration(days: 31))
            .millisecondsSinceEpoch,
      }),
      isNull,
    );
    expect(
      await load({
        'schema': 1,
        'latitude': 30.2,
        'longitude': -97.7,
        'observedAtMillis': now
            .add(const Duration(minutes: 6))
            .millisecondsSinceEpoch,
      }),
      isNull,
    );
  });

  test('writer throttles fixes and flushes the newest one in order', () async {
    final store = _MemoryStartupLocationStore();
    final writer = StartupLocationWriter(store);
    final first = StartupLocation(
      position: const LatLng(30.0, -97.0),
      observedAt: now,
    );
    final second = StartupLocation(
      position: const LatLng(30.1, -97.1),
      observedAt: now.add(const Duration(seconds: 10)),
    );
    final third = StartupLocation(
      position: const LatLng(30.2, -97.2),
      observedAt: now.add(const Duration(seconds: 31)),
    );

    writer.record(first);
    writer.record(second);
    writer.record(third);
    await writer.flush();

    expect(store.saved.map((location) => location.position), [
      first.position,
      third.position,
    ]);
  });

  test('flush writes a recent throttled fix', () async {
    final store = _MemoryStartupLocationStore();
    final writer = StartupLocationWriter(store);
    final first = StartupLocation(
      position: const LatLng(30.0, -97.0),
      observedAt: now,
    );
    final second = StartupLocation(
      position: const LatLng(30.1, -97.1),
      observedAt: now.add(const Duration(seconds: 10)),
    );

    writer.record(first);
    writer.record(second);
    await writer.flush();

    expect(store.saved.map((location) => location.position), [
      first.position,
      second.position,
    ]);
  });
}

final class _MemoryStartupLocationStore implements StartupLocationStore {
  final List<StartupLocation> saved = [];

  @override
  Future<StartupLocation?> load() async => saved.lastOrNull;

  @override
  Future<void> save(StartupLocation location) async {
    saved.add(location);
  }
}
