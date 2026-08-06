import 'dart:convert';
import 'dart:io';

import 'package:agrikhata/Widgets/update_dialog.dart';
import 'package:agrikhata/utils/app_version.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Checks GitHub-hosted [version.json] and prompts when a newer build exists.
///
/// Install flow (Windows / MSIX only):
/// 1. Compare bundled [assets/version.json] to remote manifest
/// 2. Download (or reuse) MSIX under `%LOCALAPPDATA%\AgriKhata\updates\`
/// 3. Verify Appx identity version matches the expected release
/// 4. Open Windows App Installer UI — never [exit] / never silent ForceShutdown
class UpdateService {
  static const _manifestUrl =
      'https://raw.githubusercontent.com/Saleem-Palal/AgriKhata/master/version.json';

  Future<void> checkForUpdates(BuildContext context) async {
    try {
      if (!Platform.isWindows) {
        debugPrint('UpdateService: skipping (Windows only)');
        return;
      }

      final response = await http
          .get(Uri.parse(_manifestUrl))
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        debugPrint(
          'UpdateService: $_manifestUrl => HTTP ${response.statusCode}',
        );
        return;
      }

      final Map<String, dynamic> manifest =
          jsonDecode(response.body) as Map<String, dynamic>;

      final latestVersion = (manifest['latest_version'] as String?)?.trim();
      final downloadUrl = (manifest['download_url'] as String?)?.trim();
      final changelog = _parseChangelog(manifest);

      if (latestVersion == null || latestVersion.isEmpty) return;
      if (downloadUrl == null || downloadUrl.isEmpty) return;

      final currentVersion = await AppVersion.current();
      if (currentVersion.isEmpty) {
        debugPrint('UpdateService: local assets/version.json missing');
        return;
      }

      debugPrint(
        'UpdateService: local=$currentVersion remote=$latestVersion',
      );

      if (!_isNewerVersion(latestVersion, currentVersion)) {
        debugPrint('UpdateService: already up to date');
        await _deleteUpdateArtifacts(latestVersion);
        return;
      }

      final cached = await _updatePackageFile(latestVersion);
      final hasCached = await cached.exists() &&
          await _msixIdentityVersionMatches(cached.path, latestVersion);

      if (!context.mounted) return;

      await UpdateDialog.show(
        context,
        latestVersion: latestVersion,
        currentVersion: currentVersion,
        changelog: changelog,
        downloadUrl: downloadUrl,
        initialStatus: hasCached
            ? 'Update already downloaded. Tap Install to open Windows setup.'
            : null,
        onUpdateNow: (url, {onStatus, onProgress}) => downloadAndInstall(
          url,
          expectedVersion: latestVersion,
          onStatus: onStatus,
          onProgress: onProgress,
        ),
      );
    } catch (e, st) {
      debugPrint('UpdateService: check failed: $e\n$st');
    }
  }

  /// Downloads the MSIX (or reuses a valid cache), verifies identity version,
  /// then opens the Windows App Installer UI.
  Future<void> downloadAndInstall(
    String downloadUrl, {
    required String expectedVersion,
    void Function(String status)? onStatus,
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('In-app updates are only supported on Windows.');
    }

    final resolvedUrl = _resolveMsixUrl(downloadUrl);
    final uri = Uri.tryParse(resolvedUrl);
    if (uri == null || !uri.hasScheme) {
      throw ArgumentError('Invalid download URL');
    }
    if (!resolvedUrl.toLowerCase().endsWith('.msix')) {
      throw ArgumentError(
        'download_url must end with .msix '
        '(direct release asset), got: $downloadUrl',
      );
    }

    final msixFile = await _updatePackageFile(expectedVersion);
    final canReuse = await msixFile.exists() &&
        await _msixIdentityVersionMatches(msixFile.path, expectedVersion);

    if (canReuse) {
      onStatus?.call('Using previously downloaded update...');
      onProgress?.call(1, 1);
      debugPrint('UpdateService: reusing cached ${msixFile.path}');
    } else {
      onStatus?.call('Checking download...');
      await _assertDownloadAvailable(uri);

      onStatus?.call('Preparing update...');
      if (await msixFile.exists()) {
        try {
          await msixFile.delete();
        } catch (_) {}
      }

      await _downloadFileAtomic(uri, msixFile, onProgress: onProgress);

      final length = await msixFile.length();
      if (length < 1024 * 100) {
        try {
          await msixFile.delete();
        } catch (_) {}
        throw StateError(
          'Downloaded file looks invalid ($length bytes). '
          'Check that download_url is a direct .msix asset link.',
        );
      }

      onStatus?.call('Verifying update package...');
      await _flushUiFrames();
      final matches =
          await _msixIdentityVersionMatches(msixFile.path, expectedVersion);
      if (!matches) {
        final found = await _readMsixIdentityVersion(msixFile.path);
        try {
          await msixFile.delete();
        } catch (_) {}
        throw StateError(
          'Downloaded package version mismatch. '
          'Expected $expectedVersion, got ${found ?? "unknown"}. '
          'Upload the correct agrikhata.msix for this release, then try again.',
        );
      }
    }

    if (!await msixFile.exists()) {
      throw StateError('Update package missing: ${msixFile.path}');
    }

    debugPrint('UpdateService: opening installer UI for ${msixFile.path}');
    onStatus?.call('Opening Windows installer...');
    await _flushUiFrames();

    final opened = await _launchInstallerUi(msixFile.path);
    if (!opened) {
      throw StateError(
        'Could not open the Windows installer.\n'
        'Open this file manually:\n${msixFile.path}',
      );
    }

    onStatus?.call(
      'Windows Installer is open. Click Update / Install there. '
      'AgriKhata stays open until Windows applies the update.',
    );
  }

  /// Stable folder outside the MSIX package (survives package replacement).
  String _updateDirPath() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    final root = (localAppData != null && localAppData.isNotEmpty)
        ? localAppData
        : Directory.systemTemp.path;
    return p.join(root, 'AgriKhata', 'updates');
  }

  Future<File> _updatePackageFile(String version) async {
    final dir = Directory(_updateDirPath());
    await dir.create(recursive: true);
    final safe = version.replaceAll(RegExp(r'[^\w.\-]'), '_');
    return File(p.join(dir.path, 'agrikhata_$safe.msix'));
  }

  Future<void> _deleteUpdateArtifacts(String version) async {
    try {
      final file = await _updatePackageFile(version);
      if (await file.exists()) await file.delete();
      final partial = File('${file.path}.partial');
      if (await partial.exists()) await partial.delete();
    } catch (_) {}
  }

  /// Fail fast with a clear error when the GitHub release asset is missing.
  Future<void> _assertDownloadAvailable(Uri uri) async {
    final client = http.Client();
    try {
      // Prefer HEAD; some CDNs dislike it — fall back to a ranged GET.
      var response = await client
          .head(uri, headers: {
            'User-Agent': 'AgriKhata-Updater',
            'Accept': 'application/octet-stream,*/*',
          })
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 405 || response.statusCode == 501) {
        response = await client
            .get(
              uri,
              headers: {
                'User-Agent': 'AgriKhata-Updater',
                'Accept': 'application/octet-stream,*/*',
                'Range': 'bytes=0-0',
              },
            )
            .timeout(const Duration(seconds: 15));
      }

      if (response.statusCode == 404) {
        throw StateError(
          'Update file not found (HTTP 404).\n'
          'The GitHub release asset is missing for this version.\n'
          'Publish agrikhata.msix to the release, then try again.\n'
          'URL: $uri',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 400) {
        throw StateError(
          'Update file is not reachable (HTTP ${response.statusCode}).\n'
          'URL: $uri',
        );
      }
    } finally {
      client.close();
    }
  }

  /// Reads `Package/Identity/@Version` from the MSIX (zip) via PowerShell.
  Future<String?> _readMsixIdentityVersion(String msixPath) async {
    final safePath = msixPath.replaceAll("'", "''");
    final script = '''
\$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
\$zip = [System.IO.Compression.ZipFile]::OpenRead('$safePath')
try {
  \$entry = \$zip.Entries | Where-Object { \$_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
  if (\$null -eq \$entry) { throw 'AppxManifest.xml missing' }
  \$reader = New-Object System.IO.StreamReader(\$entry.Open())
  try {
    [xml]\$xml = \$reader.ReadToEnd()
    \$ver = \$xml.Package.Identity.Version
    if (-not \$ver) { throw 'Identity Version missing' }
    Write-Output \$ver
  } finally { \$reader.Close() }
} finally { \$zip.Dispose() }
''';

    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
        runInShell: false,
      );
      if (result.exitCode != 0) {
        debugPrint(
          'UpdateService: read MSIX version failed: ${result.stderr}',
        );
        return null;
      }
      final out = (result.stdout as String).trim();
      return out.isEmpty ? null : out;
    } catch (e, st) {
      debugPrint('UpdateService: read MSIX version error: $e\n$st');
      return null;
    }
  }

  /// True when the package identity version matches [expected] (3-part semver).
  Future<bool> _msixIdentityVersionMatches(
    String msixPath,
    String expected,
  ) async {
    final identity = await _readMsixIdentityVersion(msixPath);
    if (identity == null) return false;
    // Identity is usually 1.0.16.0 — compare first 3 segments to expected 1.0.16
    return !_isNewerVersion(expected, identity) &&
        !_isNewerVersion(identity, expected);
  }

  Future<void> _flushUiFrames() async {
    try {
      final binding = WidgetsBinding.instance;
      await binding.endOfFrame;
      binding.scheduleFrame();
      await binding.endOfFrame;
    } catch (_) {}
  }

  String _resolveMsixUrl(String raw) {
    final url = raw.trim();
    if (url.toLowerCase().endsWith('.msix')) return url;

    final tagMatch = RegExp(
      r'github\.com/([^/]+)/([^/]+)/releases/tag/(v?[\w.\-]+)',
      caseSensitive: false,
    ).firstMatch(url);
    if (tagMatch != null) {
      final owner = tagMatch.group(1);
      final repo = tagMatch.group(2);
      final tag = tagMatch.group(3);
      return 'https://github.com/$owner/$repo/releases/download/$tag/agrikhata.msix';
    }

    return url;
  }

  /// Downloads to `destination.partial`, verifies size, then renames into place.
  Future<void> _downloadFileAtomic(
    Uri uri,
    File destination, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final partial = File('${destination.path}.partial');
    if (await partial.exists()) {
      try {
        await partial.delete();
      } catch (_) {}
    }

    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers['User-Agent'] = 'AgriKhata-Updater';
      request.headers['Accept'] = 'application/octet-stream,*/*';

      final streamed = await client
          .send(request)
          .timeout(const Duration(minutes: 10));

      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw HttpException(
          'Download failed (HTTP ${streamed.statusCode})',
          uri: uri,
        );
      }

      final contentType = streamed.headers['content-type'] ?? '';
      if (contentType.contains('text/html')) {
        throw StateError(
          'Server returned a web page instead of an MSIX file. '
          'Use a direct releases/download/.../agrikhata.msix URL.',
        );
      }

      final totalBytes = streamed.contentLength ?? 0;
      var receivedBytes = 0;
      var lastUiEmit = DateTime.fromMillisecondsSinceEpoch(0);
      var lastEmittedPercent = -1;

      void emitProgress({bool force = false}) {
        final now = DateTime.now();
        final percent =
            totalBytes > 0 ? ((receivedBytes / totalBytes) * 100).round() : -1;
        final elapsed = now.difference(lastUiEmit);
        if (!force &&
            elapsed < const Duration(milliseconds: 100) &&
            percent == lastEmittedPercent) {
          return;
        }
        lastUiEmit = now;
        lastEmittedPercent = percent;
        onProgress?.call(receivedBytes, totalBytes);
      }

      final sink = partial.openWrite();
      try {
        await for (final chunk in streamed.stream) {
          sink.add(chunk);
          receivedBytes += chunk.length;
          emitProgress();
        }
        await sink.flush();
        emitProgress(force: true);
      } finally {
        await sink.close();
      }

      if (totalBytes > 0 && receivedBytes != totalBytes) {
        try {
          await partial.delete();
        } catch (_) {}
        throw StateError(
          'Download incomplete ($receivedBytes of $totalBytes bytes). '
          'Please try again.',
        );
      }

      if (await destination.exists()) {
        await destination.delete();
      }
      await partial.rename(destination.path);

      debugPrint(
        'UpdateService: download complete '
        '($receivedBytes / ${totalBytes > 0 ? totalBytes : "?"} bytes) '
        '=> ${destination.path}',
      );
    } catch (e) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      rethrow;
    } finally {
      client.close();
    }
  }

  /// Opens the MSIX with Windows App Installer. App stays running.
  Future<bool> _launchInstallerUi(String msixPath) async {
    final file = File(msixPath);
    if (!await file.exists()) {
      debugPrint('UpdateService: installer file missing: $msixPath');
      return false;
    }

    // 1) cmd start — shell association for .msix (App Installer)
    try {
      final result = await Process.run(
        'cmd',
        ['/c', 'start', '', msixPath],
        runInShell: false,
      );
      if (result.exitCode == 0) {
        debugPrint('UpdateService: launched installer via cmd start');
        return true;
      }
      debugPrint(
        'UpdateService: cmd start exit=${result.exitCode} '
        'stderr=${result.stderr}',
      );
    } catch (e, st) {
      debugPrint('UpdateService: cmd start failed: $e\n$st');
    }

    // 2) PowerShell Start-Process fallback
    try {
      final safePath = msixPath.replaceAll("'", "''");
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          "Start-Process -FilePath '$safePath' -ErrorAction Stop",
        ],
        runInShell: false,
      );
      if (result.exitCode == 0) {
        debugPrint('UpdateService: launched installer via PowerShell');
        return true;
      }
      debugPrint(
        'UpdateService: PowerShell Start-Process exit=${result.exitCode} '
        'stderr=${result.stderr}',
      );
    } catch (e, st) {
      debugPrint('UpdateService: PowerShell Start-Process failed: $e\n$st');
    }

    return false;
  }

  List<String> _parseChangelog(Map<String, dynamic> manifest) {
    final rawList = manifest['changelog'];
    if (rawList is List) {
      return rawList
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }

    final notes = (manifest['release_notes'] as String?)?.trim() ?? '';
    if (notes.isEmpty) return const [];

    return notes
        .split(RegExp(r'\r?\n'))
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  /// Public for tests / diagnostics.
  static bool isNewerVersion(String remote, String local) {
    return UpdateService()._isNewerVersion(remote, local);
  }

  bool _isNewerVersion(String remote, String local) {
    final remoteParts = _parseVersion(remote);
    final localParts = _parseVersion(local);

    for (var i = 0; i < 3; i++) {
      if (remoteParts[i] > localParts[i]) return true;
      if (remoteParts[i] < localParts[i]) return false;
    }
    return false;
  }

  List<int> _parseVersion(String version) {
    final cleaned = version.split('+').first.split('-').first.trim();
    final parts = cleaned.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0,
    ];
  }
}
