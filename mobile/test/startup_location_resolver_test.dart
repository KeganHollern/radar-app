import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:radar_mobile/services/native_startup_location_source.dart';
import 'package:radar_mobile/services/startup_location_resolver.dart';
import 'package:radar_mobile/services/startup_location_store.dart';

void main() {
  final observedAt = DateTime.utc(2026, 7, 17, 15);
  final localLocation = StartupLocation(
    position: const LatLng(30.2672, -97.7431),
    observedAt: observedAt,
  );
  final nativeLocation = StartupLocation(
    position: const LatLng(35.4676, -97.5164),
    observedAt: observedAt,
  );

  test('prefers the app-local startup location', () async {
    final local = _FakeStore(result: localLocation);
    final native = _FakeNativeSource(result: nativeLocation);
    final resolver = StartupLocationResolver(local: local, native: native);

    expect(await resolver.load(), same(localLocation));
    expect(local.loadCalls, 1);
    expect(native.loadCalls, 0);
  });

  test(
    'uses the native cache before falling back when local is absent',
    () async {
      final local = _FakeStore();
      final native = _FakeNativeSource(result: nativeLocation);
      final resolver = StartupLocationResolver(local: local, native: native);

      expect(await resolver.load(), same(nativeLocation));
      expect(local.loadCalls, 1);
      expect(native.loadCalls, 1);
    },
  );

  test('uses the native cache when local storage fails', () async {
    final local = _FakeStore(error: StateError('preferences unavailable'));
    final native = _FakeNativeSource(result: nativeLocation);
    final resolver = StartupLocationResolver(local: local, native: native);

    expect(await resolver.load(), same(nativeLocation));
  });

  test('bounds both sources and returns null when neither resolves', () async {
    final localPending = Completer<StartupLocation?>();
    final nativePending = Completer<StartupLocation?>();
    final resolver = StartupLocationResolver(
      local: _FakeStore(pending: localPending),
      native: _FakeNativeSource(pending: nativePending),
      localTimeout: const Duration(milliseconds: 5),
      nativeTimeout: const Duration(milliseconds: 5),
    );

    expect(await resolver.load(), isNull);
  });
}

final class _FakeStore implements StartupLocationStore {
  _FakeStore({this.result, this.error, this.pending});

  final StartupLocation? result;
  final Object? error;
  final Completer<StartupLocation?>? pending;
  int loadCalls = 0;

  @override
  Future<StartupLocation?> load() async {
    loadCalls += 1;
    if (error case final error?) throw error;
    if (pending case final pending?) return pending.future;
    return result;
  }

  @override
  Future<void> save(StartupLocation location) async {}
}

final class _FakeNativeSource implements NativeStartupLocationSource {
  _FakeNativeSource({this.result, this.pending});

  final StartupLocation? result;
  final Completer<StartupLocation?>? pending;
  int loadCalls = 0;

  @override
  Future<StartupLocation?> load() async {
    loadCalls += 1;
    if (pending case final pending?) return pending.future;
    return result;
  }
}
