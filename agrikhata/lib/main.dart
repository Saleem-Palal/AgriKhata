import 'package:agrikhata/Core/Themes/app_theme.dart';
import 'package:agrikhata/screens/auth/auth_gate.dart';
import 'package:agrikhata/services/backup_service.dart';
import 'package:agrikhata/utils/advance_checkout_overlay.dart';
import 'package:flutter/material.dart';

/// Debug auto-login flag lives in `services/debug_auth_config.dart`
/// (`bypassLoginInDebug`). Flip it there, or use the floating DEBUG chip.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached ||
        state == AppLifecycleState.paused) {
      // Best-effort auto backup when the app is backgrounded / exiting.
      BackupService.instance.maybeAutoBackupOnExit();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgriKhata',
      theme: AppTheme.theme,
      navigatorKey: rootNavigatorKey,
      home: const AuthGate(),
    );
  }
}
