import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../Database/database_helper.dart';
import 'desktop_loopback_oauth_service.dart';
import 'google_oauth_config.dart';

/// Metadata for a backup ZIP stored in Google Drive.
class DriveBackupFile {
  final String id;
  final String name;
  final DateTime? modifiedTime;
  final int? sizeBytes;

  const DriveBackupFile({
    required this.id,
    required this.name,
    this.modifiedTime,
    this.sizeBytes,
  });

  String get formattedSize {
    final bytes = sizeBytes;
    if (bytes == null || bytes <= 0) return '—';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String get formattedWhen {
    final t = modifiedTime;
    if (t == null) return 'Unknown date';
    return DateFormat('dd-MMM-yyyy, hh:mm a').format(t.toLocal());
  }
}

/// Google Drive cloud backup / restore for the local SQLite database.
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const List<String> _scopes = DesktopLoopbackOAuthService.scopes;

  static const _backupFolderName = 'AgriKhata_Backups';
  static const _prefsEmailKey = 'agrikhata_drive_account_email';
  static const _prefsCredentialsKey = 'agrikhata_drive_oauth_credentials';
  static const _prefsLastBackupKey = 'agrikhata_drive_last_backup_at';
  static const _prefsLastBackupOkKey = 'agrikhata_drive_last_backup_ok';
  static const _prefsAutoBackupOnExitKey =
      'agrikhata_drive_auto_backup_on_exit';
  static const _prefsKeepLocalCopyKey = 'agrikhata_drive_keep_local_copy';

  http.Client? _authClient;
  GoogleSignInAccount? _googleAccount;
  bool _googleReady = false;
  bool _backupInProgress = false;

  String? _connectedEmail;
  DateTime? _lastBackupAt;
  bool _lastBackupSuccessful = false;
  bool _autoBackupOnExit = false;
  bool _keepLocalCopy = true;
  bool _prefsLoaded = false;

  String? get connectedEmail => _connectedEmail;
  bool get isConnected =>
      (_connectedEmail != null && _connectedEmail!.isNotEmpty) ||
      _authClient != null ||
      _googleAccount != null;
  DateTime? get lastBackupAt => _lastBackupAt;
  bool get lastBackupSuccessful => _lastBackupSuccessful;
  bool get autoBackupOnExit => _autoBackupOnExit;
  bool get keepLocalCopy => _keepLocalCopy;
  bool get isBackupInProgress => _backupInProgress;

  String get lastBackupStatusLabel {
    final at = _lastBackupAt;
    if (at == null) return 'Last Cloud Backup: Never';
    final when = DateFormat('dd-MMM-yyyy, hh:mm a').format(at.toLocal());
    final status = _lastBackupSuccessful ? 'Successful' : 'Failed';
    return 'Last Cloud Backup: $when ($status)';
  }

  Future<void> loadPreferences() async {
    if (_prefsLoaded) return;
    await GoogleOAuthConfig.load();
    final prefs = await SharedPreferences.getInstance();
    _connectedEmail = prefs.getString(_prefsEmailKey);
    final raw = prefs.getString(_prefsLastBackupKey);
    if (raw != null && raw.isNotEmpty) {
      _lastBackupAt = DateTime.tryParse(raw);
    }
    _lastBackupSuccessful = prefs.getBool(_prefsLastBackupOkKey) ?? false;
    _autoBackupOnExit = prefs.getBool(_prefsAutoBackupOnExitKey) ?? false;
    _keepLocalCopy = prefs.getBool(_prefsKeepLocalCopyKey) ?? true;
    _prefsLoaded = true;
  }

  Future<void> setAutoBackupOnExit(bool value) async {
    _autoBackupOnExit = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsAutoBackupOnExitKey, value);
  }

  Future<void> setKeepLocalCopy(bool value) async {
    _keepLocalCopy = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefsKeepLocalCopyKey, value);
  }

  /// OAuth2 authentication for Google Drive (`drive.file`).
  Future<bool> connectGoogleAccount() async {
    await loadPreferences();
    try {
      final client = await _ensureAuthClient(forceConsent: false);
      final email = await _resolveAccountEmail(client);
      await _persistAccount(email);
      return email.isNotEmpty;
    } on UserConsentException catch (e) {
      debugPrint('BackupService: user declined Google consent: $e');
      return false;
    } catch (e, st) {
      debugPrint('BackupService.connectGoogleAccount failed: $e\n$st');
      rethrow;
    }
  }

  /// Signs out the active Google account and triggers a fresh login.
  Future<void> switchGoogleAccount() async {
    await disconnectGoogleAccount(silent: true);
    final ok = await connectGoogleAccountWithForceConsent();
    if (!ok) {
      throw StateError('Google account switch was cancelled or failed');
    }
  }

  Future<bool> connectGoogleAccountWithForceConsent() async {
    await loadPreferences();
    try {
      final client = await _ensureAuthClient(forceConsent: true);
      final email = await _resolveAccountEmail(client);
      await _persistAccount(email);
      return email.isNotEmpty;
    } on UserConsentException {
      return false;
    }
  }

  Future<void> disconnectGoogleAccount({bool silent = false}) async {
    try {
      if (_googleReady) {
        await GoogleSignIn.instance.disconnect();
      }
    } catch (e) {
      debugPrint('BackupService GoogleSignIn.disconnect: $e');
      try {
        if (_googleReady) await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
    _googleAccount = null;
    _authClient?.close();
    _authClient = null;

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsEmailKey);
    await prefs.remove(_prefsCredentialsKey);
    _connectedEmail = null;
    if (!silent) {
      debugPrint('BackupService: Google Drive account disconnected');
    }
  }

  /// Compresses `agrikhata.db`, uploads to Drive under `AgriKhata_Backups/`,
  /// and records the last successful backup timestamp.
  Future<bool> createCloudBackup() async {
    await loadPreferences();
    if (_backupInProgress) return false;
    _backupInProgress = true;
    File? tempZip;
    try {
      final client = await _ensureAuthClient(forceConsent: false);
      final driveApi = drive.DriveApi(client);

      final zipBytes = await _buildDatabaseZipBytes();
      final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
      final zipName = 'AgriKhata_Backup_$stamp.zip';

      final tempDir = await getTemporaryDirectory();
      tempZip = File(p.join(tempDir.path, zipName));
      await tempZip.writeAsBytes(zipBytes, flush: true);

      if (_keepLocalCopy) {
        await _saveLocalBackupCopy(tempZip, zipName);
      }

      final folderId = await _ensureBackupFolder(driveApi);
      final meta = drive.File()
        ..name = zipName
        ..parents = [folderId];
      final media = drive.Media(
        tempZip.openRead(),
        await tempZip.length(),
        contentType: 'application/zip',
      );
      await driveApi.files.create(meta, uploadMedia: media);

      await _markBackupResult(success: true);
      return true;
    } catch (e, st) {
      debugPrint('BackupService.createCloudBackup failed: $e\n$st');
      await _markBackupResult(success: false);
      rethrow;
    } finally {
      _backupInProgress = false;
      try {
        if (tempZip != null && await tempZip.exists()) {
          await tempZip.delete();
        }
      } catch (_) {}
    }
  }

  /// Runs a best-effort cloud backup when the app is exiting (if enabled).
  Future<void> maybeAutoBackupOnExit() async {
    await loadPreferences();
    if (!_autoBackupOnExit || _backupInProgress) return;
    if (!isConnected && !await _hasStoredCredentials()) return;
    try {
      await createCloudBackup();
    } catch (e, st) {
      debugPrint('BackupService.maybeAutoBackupOnExit failed: $e\n$st');
    }
  }

  /// Lists AgriKhata backup archives in the user's Drive folder.
  Future<List<DriveBackupFile>> fetchCloudBackups() async {
    await loadPreferences();
    final client = await _ensureAuthClient(forceConsent: false);
    final driveApi = drive.DriveApi(client);
    final folderId = await _ensureBackupFolder(driveApi);

    final result = await driveApi.files.list(
      q: "'$folderId' in parents and trashed=false and "
          "mimeType='application/zip' and name contains 'AgriKhata_Backup_'",
      spaces: 'drive',
      $fields: 'files(id,name,modifiedTime,size)',
      orderBy: 'modifiedTime desc',
      pageSize: 50,
    );

    final files = result.files ?? const <drive.File>[];
    return files
        .where((f) => f.id != null && f.name != null)
        .map(
          (f) => DriveBackupFile(
            id: f.id!,
            name: f.name!,
            modifiedTime: f.modifiedTime,
            sizeBytes: int.tryParse(f.size ?? ''),
          ),
        )
        .toList();
  }

  /// Downloads [fileId], replaces local `agrikhata.db`, and prepares app reload.
  Future<bool> restoreFromCloudBackup(String fileId) async {
    await loadPreferences();
    if (fileId.trim().isEmpty) {
      throw ArgumentError('Backup file id is required');
    }

    Directory? tempDir;
    try {
      final client = await _ensureAuthClient(forceConsent: false);
      final driveApi = drive.DriveApi(client);

      tempDir = await Directory(
        p.join((await getTemporaryDirectory()).path,
            'agrikhata_restore_${DateTime.now().millisecondsSinceEpoch}'),
      ).create(recursive: true);

      final zipPath = p.join(tempDir.path, 'restore.zip');
      final sink = File(zipPath).openWrite();
      try {
        final media = await driveApi.files.get(
          fileId,
          downloadOptions: drive.DownloadOptions.fullMedia,
        ) as drive.Media;
        await media.stream.pipe(sink);
      } finally {
        await sink.close();
      }

      final zipBytes = await File(zipPath).readAsBytes();
      final archive = ZipDecoder().decodeBytes(zipBytes);
      ArchiveFile? dbEntry;
      for (final f in archive) {
        if (f.isFile &&
            p.basename(f.name).toLowerCase() == 'agrikhata.db') {
          dbEntry = f;
          break;
        }
      }
      if (dbEntry == null) {
        throw StateError(
          'Selected backup does not contain agrikhata.db',
        );
      }

      final restoredBytes = dbEntry.content;
      if (restoredBytes.isEmpty) {
        throw StateError('Backup database file is empty');
      }

      // Optional safety snapshot of the current DB before overwrite.
      if (_keepLocalCopy) {
        try {
          final currentZip = await _buildDatabaseZipBytes();
          final stamp = DateFormat('yyyyMMdd_HHmm').format(DateTime.now());
          final name = 'AgriKhata_PreRestore_$stamp.zip';
          final tempZip = File(p.join(tempDir.path, name));
          await tempZip.writeAsBytes(currentZip, flush: true);
          await _saveLocalBackupCopy(tempZip, name);
        } catch (e) {
          debugPrint('BackupService: pre-restore local copy failed: $e');
        }
      }

      final dbPath = await DatabaseHelper.instance.databaseFilePath;
      await DatabaseHelper.instance.close();

      final target = File(dbPath);
      if (await target.exists()) {
        await target.delete();
      }
      for (final suffix in ['-wal', '-shm', '-journal']) {
        final side = File('$dbPath$suffix');
        if (await side.exists()) {
          await side.delete();
        }
      }
      await target.writeAsBytes(restoredBytes, flush: true);

      await DatabaseHelper.instance.reopenAfterRestore();
      return true;
    } catch (e, st) {
      debugPrint('BackupService.restoreFromCloudBackup failed: $e\n$st');
      // Best effort reopen if restore failed mid-flight.
      try {
        await DatabaseHelper.instance.reopenAfterRestore();
      } catch (_) {}
      rethrow;
    } finally {
      try {
        if (tempDir != null && await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  // ── Internals ──────────────────────────────────────────────────────────

  Future<bool> _hasStoredCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsCredentialsKey);
    return raw != null && raw.isNotEmpty;
  }

  Future<void> _persistAccount(String email) async {
    _connectedEmail = email;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsEmailKey, email);
  }

  Future<void> _markBackupResult({required bool success}) async {
    _lastBackupAt = DateTime.now();
    _lastBackupSuccessful = success;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsLastBackupKey,
      _lastBackupAt!.toIso8601String(),
    );
    await prefs.setBool(_prefsLastBackupOkKey, success);
  }

  Future<List<int>> _buildDatabaseZipBytes() async {
    final db = await DatabaseHelper.instance.database;
    try {
      await db.execute('PRAGMA wal_checkpoint(FULL)');
    } catch (e) {
      debugPrint('BackupService: wal_checkpoint skipped: $e');
    }

    final dbPath = await DatabaseHelper.instance.databaseFilePath;
    // Close so Windows releases file locks before reading bytes.
    await DatabaseHelper.instance.close();
    try {
      final dbFile = File(dbPath);
      if (!await dbFile.exists()) {
        throw StateError('Local database not found at $dbPath');
      }
      final dbBytes = await dbFile.readAsBytes();
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('agrikhata.db', dbBytes));
      return ZipEncoder().encodeBytes(archive);
    } finally {
      await DatabaseHelper.instance.database;
    }
  }

  Future<void> _saveLocalBackupCopy(File zipFile, String zipName) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'AgriKhata_Backups'));
      await dir.create(recursive: true);
      final dest = File(p.join(dir.path, zipName));
      await zipFile.copy(dest.path);
    } catch (e, st) {
      debugPrint('BackupService local copy failed: $e\n$st');
    }
  }

  Future<String> _ensureBackupFolder(drive.DriveApi api) async {
    final existing = await api.files.list(
      q: "mimeType='application/vnd.google-apps.folder' and "
          "name='$_backupFolderName' and trashed=false",
      spaces: 'drive',
      $fields: 'files(id,name)',
      pageSize: 1,
    );
    final existingFiles = existing.files;
    if (existingFiles != null && existingFiles.isNotEmpty) {
      final id = existingFiles.first.id;
      if (id != null && id.isNotEmpty) return id;
    }

    final created = await api.files.create(
      drive.File()
        ..name = _backupFolderName
        ..mimeType = 'application/vnd.google-apps.folder',
    );
    final newId = created.id;
    if (newId == null || newId.isEmpty) {
      throw StateError('Failed to create Drive folder $_backupFolderName');
    }
    return newId;
  }

  Future<String> _resolveAccountEmail(http.Client client) async {
    if (_googleAccount?.email.isNotEmpty == true) {
      return _googleAccount!.email.trim();
    }
    if (_connectedEmail != null && _connectedEmail!.isNotEmpty) {
      return _connectedEmail!;
    }
    try {
      final response = await client.get(
        Uri.parse('https://www.googleapis.com/oauth2/v2/userinfo'),
      );
      if (response.statusCode == 200) {
        final map = jsonDecode(response.body) as Map<String, dynamic>;
        final email = (map['email'] as String?)?.trim() ?? '';
        if (email.isNotEmpty) return email;
      }
    } catch (e) {
      debugPrint('BackupService userinfo failed: $e');
    }
    try {
      final about = await drive.DriveApi(client).about.get($fields: 'user');
      final email = about.user?.emailAddress?.trim() ?? '';
      if (email.isNotEmpty) return email;
    } catch (e) {
      debugPrint('BackupService about.get failed: $e');
    }
    return 'Google Account';
  }

  Future<http.Client> _ensureAuthClient({
    required bool forceConsent,
  }) async {
    if (!forceConsent && _authClient != null) {
      return _authClient!;
    }

    // Prefer native Google Sign-In when the platform supports authenticate.
    final viaGoogleSignIn = await _tryGoogleSignInClient(
      forceConsent: forceConsent,
    );
    if (viaGoogleSignIn != null) {
      _authClient?.close();
      _authClient = viaGoogleSignIn;
      return viaGoogleSignIn;
    }

    // Desktop / fallback: loopback OAuth via googleapis_auth.
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

    if (!forceConsent) {
      final restored = await _restoreClientFromPrefs(clientId);
      if (restored != null) {
        _authClient?.close();
        _authClient = restored;
        return restored;
      }
    } else {
      // Force a clean consent by dropping cached tokens.
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefsCredentialsKey);
      _authClient?.close();
      _authClient = null;
    }

    final client = await DesktopLoopbackOAuthService.instance.authorize(
      forceConsent: forceConsent,
    );

    await _persistCredentials(client.credentials);
    client.credentialUpdates.listen((creds) {
      unawaited(_persistCredentials(creds));
    });

    _authClient?.close();
    _authClient = client;
    return client;
  }

  Future<AutoRefreshingAuthClient?> _restoreClientFromPrefs(
    ClientId clientId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsCredentialsKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final credentials = AccessCredentials.fromJson(map);
      final base = http.Client();
      final client = autoRefreshingClient(clientId, credentials, base);
      client.credentialUpdates.listen((creds) {
        unawaited(_persistCredentials(creds));
      });
      return client;
    } catch (e) {
      debugPrint('BackupService: stored credentials invalid: $e');
      await prefs.remove(_prefsCredentialsKey);
      return null;
    }
  }

  Future<void> _persistCredentials(AccessCredentials credentials) async {
    final prefs = await SharedPreferences.getInstance();
    final map = <String, dynamic>{
      'accessToken': credentials.accessToken.toJson(),
      if (credentials.refreshToken != null)
        'refreshToken': credentials.refreshToken,
      'idToken': credentials.idToken,
      'scopes': credentials.scopes,
    };
    await prefs.setString(_prefsCredentialsKey, jsonEncode(map));
  }

  Future<http.Client?> _tryGoogleSignInClient({
    required bool forceConsent,
  }) async {
    try {
      await _ensureGoogleInitialized();
      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        return null;
      }

      if (forceConsent) {
        try {
          await GoogleSignIn.instance.signOut();
        } catch (_) {}
      }
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: _scopes,
      );
      _googleAccount = account;

      var authorization =
          await account.authorizationClient.authorizationForScopes(_scopes);
      authorization ??=
          await account.authorizationClient.authorizeScopes(_scopes);

      final token = authorization.accessToken.trim();
      if (token.isEmpty) return null;

      return _HeaderClient(<String, String>{
        'Authorization': 'Bearer $token',
        'X-Goog-AuthUser': '0',
      });
    } on UnsupportedError {
      return null;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw UserConsentException('Google sign-in was cancelled');
      }
      debugPrint('BackupService GoogleSignIn path unavailable: $e');
      return null;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('MissingPluginException') ||
          msg.contains('not available') ||
          msg.contains('Unsupported')) {
        return null;
      }
      debugPrint('BackupService GoogleSignIn path failed: $e');
      return null;
    }
  }

  Future<void> _ensureGoogleInitialized() async {
    if (_googleReady) return;
    try {
      await GoogleSignIn.instance.initialize();
      _googleReady = true;
    } catch (e) {
      debugPrint('BackupService GoogleSignIn.initialize failed: $e');
      rethrow;
    }
  }
}

/// HTTP client that injects Google authorization headers on every request.
class _HeaderClient extends http.BaseClient {
  _HeaderClient(this._headers);

  final Map<String, String> _headers;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    _headers.forEach((key, value) {
      request.headers.putIfAbsent(key, () => value);
    });
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
