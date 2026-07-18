import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'screens/radar_map_screen.dart';
import 'services/alert_notification_background.dart';
import 'theme/flexoki_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await initializeAlertNotificationBackground();
  } catch (_) {
    // Radar remains usable if the OS background scheduler is unavailable. The
    // settings controller will retry reconciliation on launch and resume.
  }
  unawaited(WakelockPlus.enable());
  runApp(const RadarApp());
}

class RadarApp extends StatefulWidget {
  const RadarApp({super.key});

  @override
  State<RadarApp> createState() => _RadarAppState();
}

class _RadarAppState extends State<RadarApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(WakelockPlus.enable());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(WakelockPlus.disable());
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HyprRadar',
      debugShowCheckedModeBanner: false,
      theme: Flexoki.darkTheme,
      darkTheme: Flexoki.darkTheme,
      themeMode: ThemeMode.dark,
      home: const RadarMapScreen(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(WakelockPlus.disable());
    super.dispose();
  }
}
