import 'package:agrikhata/Core/Themes/app_theme.dart';
import 'package:agrikhata/screens/auth/auth_gate.dart';
import 'package:agrikhata/services/backup_service.dart';
import 'package:agrikhata/services/google_oauth_config.dart';
import 'package:agrikhata/utils/advance_checkout_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Debug auto-login flag lives in `services/debug_auth_config.dart`
/// (`bypassLoginInDebug`). Flip it there, or use the floating DEBUG chip.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _loadDotEnv();
  // Warm OAuth config after dotenv so warnings reflect bundled credentials.
  await GoogleOAuthConfig.load();
  runApp(const MyApp());
}

Future<void> _loadDotEnv() async {
  try {
    await dotenv.load(fileName: '.env', isOptional: true);
    if (!dotenv.isInitialized ||
        (dotenv.env['GOOGLE_CLIENT_ID']?.trim().isEmpty ?? true)) {
      debugPrint(
        'GoogleOAuth: .env missing or GOOGLE_CLIENT_ID empty. '
        'Copy .env.example to .env for desktop OAuth out of the box.',
      );
    }
  } catch (e, st) {
    // Never crash startup for missing/invalid .env — fall back to Settings /
    // dart-define / manual onboarding.
    debugPrint('GoogleOAuth: failed to load .env: $e\n$st');
  }
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
