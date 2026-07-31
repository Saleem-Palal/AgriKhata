import 'dart:developer' as developer;

import 'package:shared_preferences/shared_preferences.dart';

/// Thrown when desktop Google Drive OAuth client credentials are missing.
class GoogleOAuthNotConfiguredException implements Exception {
  final String message;
  const GoogleOAuthNotConfiguredException([
    this.message =
        'Google Drive OAuth is not configured yet. Add a Desktop OAuth Client ID to continue.',
  ]);

  @override
  String toString() => message;
}

/// Google Cloud OAuth credentials for Drive backup on desktop.
///
/// Resolution order:
/// 1. Runtime values saved from Settings (SharedPreferences) — editable anytime
/// 2. Compile-time `--dart-define=GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`
///
/// Production MSIX builds should bake in the Client ID:
/// `flutter pub run msix:create --dart-define=GOOGLE_CLIENT_ID="<CLIENT_ID>"`
///
/// Do not commit Client ID or Client Secret to Git.
class GoogleOAuthConfig {
  GoogleOAuthConfig._();

  static const _prefsClientIdKey = 'agrikhata_google_oauth_client_id';
  static const _prefsClientSecretKey = 'agrikhata_google_oauth_client_secret';

  static const String _envClientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const String _envClientSecret = String.fromEnvironment(
    'GOOGLE_CLIENT_SECRET',
  );

  /// Fixed loopback port so the redirect URI stays stable in Cloud Console.
  /// Add `http://localhost:8765/` as an authorized redirect URI if required.
  static const int loopbackPort = 8765;

  static String? _runtimeClientId;
  static String? _runtimeClientSecret;
  static bool _loaded = false;
  static bool _warnedMissingClientId = false;

  static Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _runtimeClientId = prefs.getString(_prefsClientIdKey);
    _runtimeClientSecret = prefs.getString(_prefsClientSecretKey);
    _loaded = true;
    _warnIfClientIdMissing();
  }

  /// Logs a non-fatal warning when no Client ID is available (common in local
  /// `flutter run` without `--dart-define`). Drive features stay disabled
  /// until Settings or a production define supplies credentials.
  static void _warnIfClientIdMissing() {
    if (isConfigured || _warnedMissingClientId) return;
    _warnedMissingClientId = true;
    developer.log(
      'GOOGLE_CLIENT_ID is empty. Google Drive backup will stay disabled '
      'until you either:\n'
      '  • enter a Desktop OAuth Client ID in Settings, or\n'
      '  • rebuild with '
      '`--dart-define=GOOGLE_CLIENT_ID="<CLIENT_ID>"` '
      '(required for production .msix packages).\n'
      'Example: flutter pub run msix:create '
      '--dart-define=GOOGLE_CLIENT_ID="<CLIENT_ID>"',
      name: 'GoogleOAuthConfig',
      level: 900, // Warning
    );
  }

  static String get desktopClientId {
    final runtime = _runtimeClientId?.trim() ?? '';
    if (runtime.isNotEmpty) return runtime;
    return _envClientId.trim();
  }

  static String get desktopClientSecret {
    final runtime = _runtimeClientSecret?.trim() ?? '';
    if (runtime.isNotEmpty) return runtime;
    return _envClientSecret.trim();
  }

  static bool get isConfigured {
    final id = desktopClientId;
    return id.isNotEmpty && id.contains('.apps.googleusercontent.com');
  }

  static Future<void> saveRuntimeCredentials({
    required String clientId,
    String clientSecret = '',
  }) async {
    final id = clientId.trim();
    final secret = clientSecret.trim();
    if (id.isEmpty || !id.contains('.apps.googleusercontent.com')) {
      throw ArgumentError(
        'Enter a valid Desktop OAuth Client ID '
        '(…apps.googleusercontent.com)',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsClientIdKey, id);
    if (secret.isEmpty) {
      await prefs.remove(_prefsClientSecretKey);
    } else {
      await prefs.setString(_prefsClientSecretKey, secret);
    }
    _runtimeClientId = id;
    _runtimeClientSecret = secret.isEmpty ? null : secret;
    _loaded = true;
    _warnedMissingClientId = false;
  }
}
