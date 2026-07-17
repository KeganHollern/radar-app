import 'dart:async';

import 'native_startup_location_source.dart';
import 'startup_location_store.dart';

/// Resolves one startup camera seed before the native map is mounted.
///
/// The app-local value wins because it was accepted by this app. The platform
/// cache is a migration fallback for an upgrade where that preference does not
/// exist yet. Both sources are bounded so neither can hold the map closed.
final class StartupLocationResolver {
  const StartupLocationResolver({
    required StartupLocationStore local,
    required NativeStartupLocationSource native,
    this.localTimeout = const Duration(seconds: 1),
    this.nativeTimeout = const Duration(milliseconds: 750),
  }) : _local = local,
       _native = native;

  final StartupLocationStore _local;
  final NativeStartupLocationSource _native;
  final Duration localTimeout;
  final Duration nativeTimeout;

  Future<StartupLocation?> load() async {
    final local = await _loadSafely(_local.load, localTimeout);
    if (local != null) return local;
    return _loadSafely(_native.load, nativeTimeout);
  }

  static Future<StartupLocation?> _loadSafely(
    Future<StartupLocation?> Function() loader,
    Duration timeout,
  ) async {
    try {
      return await loader().timeout(timeout);
    } catch (_) {
      return null;
    }
  }
}
