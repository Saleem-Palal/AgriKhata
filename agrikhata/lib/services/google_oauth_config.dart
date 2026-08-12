import 'dart:developer' as developer;

import 'package:flutter_dotenv/flutter_dotenv.dart';
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

/// Google Cloud OAuth credentials for Drive backup / desktop sign-in.
///
/// Resolution order:
/// 1. Runtime values saved from Settings (SharedPreferences) — optional override
/// 2. Values from the bundled `.env` asset (`flutter_dotenv`)
/// 3. Compile-time `--dart-define=GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET`
///
/// Copy `.env.example` → `.env` for local and release packaging. Never commit
/// `.env` (it is gitignored).
class GoogleOAuthConfig {
  GoogleOAuthConfig._();

  static const _prefsClientIdKey = 'agrikhata_google_oauth_client_id';
  static const _prefsClientSecretKey = 'agrikhata_google_oauth_client_secret';

  static const String _defineClientId =
      String.fromEnvironment('GOOGLE_CLIENT_ID');
  static const String _defineClientSecret =
      String.fromEnvironment('GOOGLE_CLIENT_SECRET');

  /// Preferred loopback port for OAuth redirect (tried first).
  /// Add `http://localhost:8765/` as an authorized redirect URI if required.
  /// Additional fallback ports (8766–8769) and a dynamic port are tried
  /// automatically when this port is busy or blocked.
  static const int preferredLoopbackPort = 8765;

  /// @deprecated Use [preferredLoopbackPort]. Kept for existing call sites.
  static const int loopbackPort = preferredLoopbackPort;

  static String? _runtimeClientId;
  static String? _runtimeClientSecret;
  static bool _loaded = false;
  static bool _warnedMissingClientId = false;

  static Future<void> load() async {
    if (_loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _runtimeClientId = prefs.getString(_prefsClientIdKey);
      _runtimeClientSecret = prefs.getString(_prefsClientSecretKey);
    } catch (e, st) {
      developer.log(
        'Failed to load OAuth credentials from SharedPreferences: $e',
        name: 'GoogleOAuthConfig',
        error: e,
        stackTrace: st,
        level: 900,
      );
    } finally {
      _loaded = true;
      _warnIfClientIdMissing();
    }
  }

  /// Logs a non-fatal warning when no Client ID is available.
  static void _warnIfClientIdMissing() {
    if (isConfigured || _warnedMissingClientId) return;
    _warnedMissingClientId = true;
    developer.log(
      'GOOGLE_CLIENT_ID is empty. Google OAuth will stay disabled until you:\n'
      '  • copy `.env.example` to `.env` and set GOOGLE_CLIENT_ID, or\n'
      '  • enter a Desktop OAuth Client ID in Settings, or\n'
      '  • rebuild with `--dart-define=GOOGLE_CLIENT_ID="<CLIENT_ID>"`.\n'
      'See README / `.env.example` for setup.',
      name: 'GoogleOAuthConfig',
      level: 900, // Warning
    );
  }

  static String get _dotenvClientId =>
      (dotenv.isInitialized
              ? dotenv.env['GOOGLE_CLIENT_ID']
              : null)
          ?.trim() ??
      '';

  static String get _dotenvClientSecret =>
      (dotenv.isInitialized
              ? dotenv.env['GOOGLE_CLIENT_SECRET']
              : null)
          ?.trim() ??
      '';

  static String get desktopClientId {
    final runtime = _runtimeClientId?.trim() ?? '';
    if (runtime.isNotEmpty) return runtime;

    final fromDotenv = _dotenvClientId;
    if (fromDotenv.isNotEmpty) return fromDotenv;

    return _defineClientId.trim();
  }

  static String get desktopClientSecret {
    final runtime = _runtimeClientSecret?.trim() ?? '';
    if (runtime.isNotEmpty) return runtime;

    final fromDotenv = _dotenvClientSecret;
    if (fromDotenv.isNotEmpty) return fromDotenv;

    return _defineClientSecret.trim();
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
