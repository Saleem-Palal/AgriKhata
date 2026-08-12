import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// ignore: implementation_imports
import 'package:googleapis_auth/src/oauth2_flows/auth_code.dart' as oauth_flow;

import 'google_oauth_config.dart';

/// Thrown when the local loopback OAuth listener cannot start.
class DesktopLoopbackOAuthException implements Exception {
  final String message;
  final Object? cause;

  const DesktopLoopbackOAuthException(this.message, {this.cause});

  @override
  String toString() => cause == null ? message : '$message ($cause)';
}

/// Desktop Google OAuth via a local HTTP loopback listener.
///
/// Used when native [GoogleSignIn] is unavailable (common on Windows desktop).
class DesktopLoopbackOAuthService {
  DesktopLoopbackOAuthService._();
  static final DesktopLoopbackOAuthService instance =
      DesktopLoopbackOAuthService._();

  static const openIdScope = 'openid';
  static const userInfoEmailScope =
      'https://www.googleapis.com/auth/userinfo.email';
  static const driveFileScope =
      'https://www.googleapis.com/auth/drive.file';

  /// Scopes shared across sign-in and Drive backup.
  static const List<String> scopes = [
    openIdScope,
    userInfoEmailScope,
    driveFileScope,
  ];

  /// Ordered ports to try before falling back to an OS-assigned dynamic port.
  static const List<int> preferredLoopbackPorts = [
    GoogleOAuthConfig.preferredLoopbackPort,
    8766,
    8767,
    8768,
    8769,
  ];

  int? _lastBoundPort;

  /// Port used by the most recent successful loopback OAuth flow, if any.
  int? get lastBoundPort => _lastBoundPort;

  /// True when loopback OAuth can run (Desktop client ID is configured).
  Future<bool> get isAvailable async {
    await GoogleOAuthConfig.load();
    return GoogleOAuthConfig.isConfigured;
  }

  /// Probes loopback ports and returns the first port that can be bound.
  ///
  /// Returns `0` when only a dynamic port is available.
  Future<int> resolveLoopbackPort() async {
    for (final port in preferredLoopbackPorts) {
      HttpServer? probe;
      try {
        probe = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        developer.log(
          'Loopback port $port is available',
          name: 'DesktopLoopbackOAuth',
        );
        return port;
      } on SocketException catch (e, st) {
        developer.log(
          'Loopback port $port unavailable: $e',
          name: 'DesktopLoopbackOAuth',
          error: e,
          stackTrace: st,
          level: 900,
        );
      } finally {
        await probe?.close(force: true);
      }
    }

    HttpServer? dynamicProbe;
    try {
      dynamicProbe =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = dynamicProbe.port;
      developer.log(
        'Using dynamic loopback port $port (preferred ports were busy)',
        name: 'DesktopLoopbackOAuth',
        level: 900,
      );
      return port;
    } on SocketException catch (e, st) {
      developer.log(
        'Failed to bind any loopback port: $e',
        name: 'DesktopLoopbackOAuth',
        error: e,
        stackTrace: st,
        level: 1000,
      );
      throw DesktopLoopbackOAuthException(
        'Could not start the local Google sign-in listener. '
        'Another app may be blocking localhost ports, or Windows Firewall may '
        'be denying loopback access. Allow AgriKhata through the firewall and '
        'try again.',
        cause: e,
      );
    } finally {
      await dynamicProbe?.close(force: true);
    }
  }

  /// Runs the OAuth authorization-code loopback flow with port fallback.
  Future<AutoRefreshingAuthClient> authorize({
    bool forceConsent = false,
  }) async {
    await GoogleOAuthConfig.load();
    if (!GoogleOAuthConfig.isConfigured) {
      throw const GoogleOAuthNotConfiguredException();
    }

    final clientId = ClientId(
      GoogleOAuthConfig.desktopClientId,
      GoogleOAuthConfig.desktopClientSecret.isEmpty
          ? null
          : GoogleOAuthConfig.desktopClientSecret,
    );

    final portsToTry = <int>[...preferredLoopbackPorts, 0];
    Object? lastError;
    StackTrace? lastStack;

    for (final port in portsToTry) {
      try {
        developer.log(
          'Starting loopback OAuth on port ${port == 0 ? "dynamic" : port}',
          name: 'DesktopLoopbackOAuth',
        );
        final credentials = await _obtainCredentialsViaLoopback(
          clientId: clientId,
          listenPort: port,
        );
        final baseClient = http.Client();
        final client = autoRefreshingClient(
          clientId,
          credentials,
          baseClient,
        );
        _lastBoundPort = port == 0 ? _lastBoundPort : port;
        developer.log(
          'Loopback OAuth succeeded',
          name: 'DesktopLoopbackOAuth',
        );
        return client;
      } on SocketException catch (e, st) {
        lastError = e;
        lastStack = st;
        developer.log(
          'HttpServer.bind failed on port ${port == 0 ? "dynamic" : port}: $e',
          name: 'DesktopLoopbackOAuth',
          error: e,
          stackTrace: st,
          level: 900,
        );
        if (port == 0) break;
        continue;
      } on UserConsentException {
        rethrow;
      } catch (e, st) {
        lastError = e;
        lastStack = st;
        developer.log(
          'Loopback OAuth failed on port ${port == 0 ? "dynamic" : port}: $e',
          name: 'DesktopLoopbackOAuth',
          error: e,
          stackTrace: st,
          level: 1000,
        );
        if (_isPortBindFailure(e)) {
          if (port == 0) break;
          continue;
        }
        rethrow;
      }
    }

    debugPrint(
      'DesktopLoopbackOAuth: all loopback ports failed\n$lastError\n$lastStack',
    );
    throw DesktopLoopbackOAuthException(
      'Could not start the local Google sign-in listener after trying ports '
      '${preferredLoopbackPorts.join(", ")} and a dynamic port. '
      'Check Windows Firewall rules and ensure no other app is blocking '
      'localhost.',
      cause: lastError,
    );
  }

  /// Resolves the signed-in Google account email and display name.
  Future<({String email, String name})> signInForProfile({
    bool forceConsent = false,
  }) async {
    final client = await authorize(forceConsent: forceConsent);
    try {
      final response = await client.get(
        Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
      );
      if (response.statusCode != 200) {
        throw StateError(
          'Google userinfo request failed (${response.statusCode})',
        );
      }
      final map = jsonDecode(response.body) as Map<String, dynamic>;
      final email = (map['email'] as String?)?.trim() ?? '';
      if (email.isEmpty) {
        throw StateError('Google account did not return an email');
      }
      final rawName = (map['name'] as String?)?.trim();
      final name = rawName != null && rawName.isNotEmpty
          ? rawName
          : email.split('@').first;
      return (email: email, name: name);
    } finally {
      client.close();
    }
  }

  Future<void> _launchConsentUrl(String url) async {
    final uri = Uri.parse(url);
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!launched) {
      throw StateError('Could not open browser for Google sign-in');
    }
  }

  /// Loopback authorization-code flow with PKCE + offline refresh tokens.
  Future<AccessCredentials> _obtainCredentialsViaLoopback({
    required ClientId clientId,
    required int listenPort,
  }) async {
    final httpClient = http.Client();
    HttpServer? server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, listenPort);
      _lastBoundPort = server.port;
      final redirectionUri = 'http://127.0.0.1:${server.port}';
      final state = oauth_flow.randomState();
      final codeVerifier = oauth_flow.createCodeVerifier();
      final authUri = oauth_flow.createAuthenticationUri(
        redirectUri: redirectionUri,
        clientId: clientId.identifier,
        scopes: scopes,
        codeVerifier: codeVerifier,
        state: state,
        offline: true,
      );

      await _launchConsentUrl(authUri.toString());

      final request = await server.first;
      final uri = request.uri;
      try {
        if (request.method != 'GET') {
          throw AuthorizationCallbackException(
            'Invalid OAuth callback (expected GET, got ${request.method}).',
          );
        }
        if (state != uri.queryParameters['state']) {
          throw const AuthorizationCallbackException(
            'Invalid OAuth callback (state mismatch).',
          );
        }
        final error = uri.queryParameters['error'];
        if (error != null) {
          throw UserConsentException(
            'Google sign-in failed: $error',
          );
        }
        final code = uri.queryParameters['code'];
        if (code == null || code.isEmpty) {
          throw const AuthorizationCallbackException(
            'Invalid OAuth callback (missing authorization code).',
          );
        }

        final credentials = await oauth_flow.obtainAccessCredentialsViaCodeExchange(
          httpClient,
          clientId,
          code,
          redirectUrl: redirectionUri,
          codeVerifier: codeVerifier,
        );

        request.response
          ..statusCode = 200
          ..headers.set('content-type', 'text/html; charset=UTF-8')
          ..write(_postAuthHtml);
        await request.response.close();
        return credentials;
      } catch (e) {
        request.response.statusCode = 500;
        await request.response.close().catchError((_) {});
        rethrow;
      }
    } on SocketException catch (e, st) {
      developer.log(
        'Loopback HttpServer.bind failed: $e',
        name: 'DesktopLoopbackOAuth',
        error: e,
        stackTrace: st,
        level: 1000,
      );
      rethrow;
    } finally {
      await server?.close(force: true);
      httpClient.close();
    }
  }

  static const _postAuthHtml = '''
<!DOCTYPE html>
<html>
  <head>
    <meta charset="utf-8">
    <title>Signed in to AgriKhata</title>
  </head>
  <body>
    <h2 style="text-align: center">Google sign-in successful</h2>
    <p style="text-align: center">You can close this window and return to AgriKhata.</p>
  </body>
</html>''';

  bool _isPortBindFailure(Object error) {
    if (error is SocketException) return true;
    final msg = error.toString().toLowerCase();
    return msg.contains('socketexception') ||
        msg.contains('failed host lookup') ||
        msg.contains('permission denied') ||
        msg.contains('address already in use') ||
        msg.contains('port is already in use');
  }

}
