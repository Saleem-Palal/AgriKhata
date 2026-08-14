import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agrikhata/Widgets/update_dialog.dart';
import 'package:agrikhata/utils/app_version.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Checks GitHub-hosted [version.json] and prompts when a newer build exists.
///
/// Install flow (Windows / MSIX only):
/// 1. Compare bundled [assets/version.json] to remote manifest
/// 2. Download (or reuse) MSIX under `%LOCALAPPDATA%\AgriKhata\updates\`
/// 3. Verify Appx identity version matches the expected release
/// 4. Open Windows App Installer UI — never [exit] / never silent ForceShutdown
///
/// Network I/O uses Windows-native TLS (curl.exe / PowerShell Schannel), not
/// Dart BoringSSL, so downloads match Edge/Chrome certificate trust.
class UpdateService {
  static const _manifestUrl =
      'https://raw.githubusercontent.com/Saleem-Palal/AgriKhata/master/version.json';

  Future<void> checkForUpdates(BuildContext context) async {
    try {
      if (!Platform.isWindows) {
        debugPrint('UpdateService: skipping (Windows only)');
        return;
      }

      final body = await _windowsHttpGetString(
        _cacheBustedUri(Uri.parse(_manifestUrl)),
        timeout: const Duration(seconds: 8),
      );

      final Map<String, dynamic> manifest =
          jsonDecode(body) as Map<String, dynamic>;

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
      final found = await _readMsixIdentityVersion(msixFile.path);
      if (found == null) {
        // Inspection can fail on some Windows/App Installer setups; do not
        // block install — trust release tag / version.json metadata.
        debugPrint(
          'UpdateService: MSIX identity version unreadable; '
          'trusting release metadata ($expectedVersion)',
        );
        onStatus?.call(
          'Could not verify package identity; continuing with release $expectedVersion...',
        );
      } else if (!_versionsEqual(found, expectedVersion)) {
        try {
          await msixFile.delete();
        } catch (_) {}
        throw StateError(
          'Downloaded package version mismatch. '
          'Expected $expectedVersion, got $found. '
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

  /// Appends a cache-busting `t=` query so CDNs/proxies don't serve a stale MSIX.
  Uri _cacheBustedUri(Uri uri) {
    final params = Map<String, String>.from(uri.queryParameters);
    params['t'] = DateTime.now().millisecondsSinceEpoch.toString();
    return uri.replace(queryParameters: params);
  }

  // ---------------------------------------------------------------------------
  // Windows-native HTTP (Schannel via curl.exe / PowerShell)
  // ---------------------------------------------------------------------------

  Future<bool> _curlAvailable() async {
    try {
      final result = await Process.run(
        'where',
        ['curl.exe'],
        runInShell: false,
      );
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// GET response body using Windows TLS (matches browser trust).
  Future<String> _windowsHttpGetString(
    Uri uri, {
    required Duration timeout,
  }) async {
    if (await _curlAvailable()) {
      final result = await Process.run(
        'curl.exe',
        [
          '-sS',
          '-L',
          '-f',
          '--max-time',
          '${timeout.inSeconds}',
          '-A',
          'AgriKhata-Updater',
          '-H',
          'Cache-Control: no-cache',
          '-H',
          'Pragma: no-cache',
          uri.toString(),
        ],
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(timeout + const Duration(seconds: 2));

      if (result.exitCode != 0) {
        final err = (result.stderr as String).trim();
        throw StateError(
          'Failed to fetch update manifest (curl ${result.exitCode})'
          '${err.isEmpty ? '' : ': $err'}',
        );
      }
      return (result.stdout as String);
    }

    return _powershellHttpGetString(uri, timeout: timeout);
  }

  Future<String> _powershellHttpGetString(
    Uri uri, {
    required Duration timeout,
  }) async {
    final safeUrl = uri.toString().replaceAll("'", "''");
    final script = '''
\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
\$r = Invoke-WebRequest -Uri '$safeUrl' -UseBasicParsing -TimeoutSec ${timeout.inSeconds} -UserAgent 'AgriKhata-Updater'
Write-Output \$r.Content
''';
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout + const Duration(seconds: 3));

    if (result.exitCode != 0) {
      final err = (result.stderr as String).trim();
      throw StateError(
        'Failed to fetch update manifest'
        '${err.isEmpty ? '' : ': $err'}',
      );
    }
    return (result.stdout as String);
  }

  /// Fail fast with a clear error when the GitHub release asset is missing.
  Future<void> _assertDownloadAvailable(Uri uri) async {
    final busted = _cacheBustedUri(uri);
    final status = await _windowsHttpStatus(busted);

    if (status == 404) {
      throw StateError(
        'Update file not found (HTTP 404).\n'
        'The GitHub release asset is missing for this version.\n'
        'Publish agrikhata.msix to the release, then try again.\n'
        'URL: $uri',
      );
    }
    if (status < 200 || status >= 400) {
      throw StateError(
        'Update file is not reachable (HTTP $status).\n'
        'URL: $uri',
      );
    }
  }

  Future<int> _windowsHttpStatus(Uri uri) async {
    if (await _curlAvailable()) {
      // Prefer HEAD; fall back to a 1-byte ranged GET for picky CDNs.
      var code = await _curlHttpCode([
        '-sI',
        '-L',
        '-o',
        'NUL',
        '-w',
        '%{http_code}',
        '--max-time',
        '15',
        '-A',
        'AgriKhata-Updater',
        uri.toString(),
      ]);
      if (code == 405 || code == 501 || code == 0) {
        code = await _curlHttpCode([
          '-sL',
          '-o',
          'NUL',
          '-w',
          '%{http_code}',
          '--max-time',
          '15',
          '-r',
          '0-0',
          '-A',
          'AgriKhata-Updater',
          uri.toString(),
        ]);
      }
      return code;
    }

    return _powershellHttpStatus(uri);
  }

  Future<int> _curlHttpCode(List<String> args) async {
    final result = await Process.run(
      'curl.exe',
      args,
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 20));
    final out = (result.stdout as String).trim();
    return int.tryParse(out) ?? 0;
  }

  Future<int> _powershellHttpStatus(Uri uri) async {
    final safeUrl = uri.toString().replaceAll("'", "''");
    final script = '''
\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
try {
  \$r = Invoke-WebRequest -Uri '$safeUrl' -Method Head -UseBasicParsing -TimeoutSec 15 -UserAgent 'AgriKhata-Updater'
  Write-Output ([int]\$r.StatusCode)
} catch {
  if (\$_.Exception.Response -ne \$null) {
    Write-Output ([int]\$_.Exception.Response.StatusCode)
  } else {
    Write-Output 0
  }
}
''';
    final result = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      runInShell: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(seconds: 20));
    final out = (result.stdout as String).trim().split(RegExp(r'\r?\n')).last;
    return int.tryParse(out) ?? 0;
  }

  Future<int?> _windowsContentLength(Uri uri) async {
    if (!await _curlAvailable()) return null;
    try {
      final result = await Process.run(
        'curl.exe',
        [
          '-sI',
          '-L',
          '--max-time',
          '15',
          '-A',
          'AgriKhata-Updater',
          uri.toString(),
        ],
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) return null;
      final headers = result.stdout as String;
      final match = RegExp(
        r'^content-length:\s*(\d+)\s*$',
        caseSensitive: false,
        multiLine: true,
      ).firstMatch(headers);
      if (match == null) return null;
      return int.tryParse(match.group(1)!);
    } catch (_) {
      return null;
    }
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

    final busted = _cacheBustedUri(uri);
    try {
      if (await _curlAvailable()) {
        await _downloadWithCurl(
          busted,
          partial,
          onProgress: onProgress,
        );
      } else {
        await _downloadWithPowerShell(
          busted,
          partial,
          onProgress: onProgress,
        );
      }

      final length = await partial.length();
      if (length <= 0) {
        throw StateError('Download produced an empty file.');
      }

      // Reject HTML error pages mistaken for an MSIX.
      if (length < 1024 * 100) {
        final raf = await partial.open();
        try {
          final bytes = await raf.read(64);
          final head = utf8.decode(bytes, allowMalformed: true).toLowerCase();
          if (head.contains('<html') || head.contains('<!doctype')) {
            throw StateError(
              'Server returned a web page instead of an MSIX file. '
              'Use a direct releases/download/.../agrikhata.msix URL.',
            );
          }
        } finally {
          await raf.close();
        }
      }

      if (await destination.exists()) {
        await destination.delete();
      }
      await partial.rename(destination.path);

      final finalLen = await destination.length();
      debugPrint(
        'UpdateService: download complete ($finalLen bytes) '
        '=> ${destination.path}',
      );
      onProgress?.call(finalLen, finalLen);
    } catch (e) {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _downloadWithCurl(
    Uri uri,
    File partial, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final totalBytes = await _windowsContentLength(uri) ?? 0;
    onProgress?.call(0, totalBytes);

    final process = await Process.start(
      'curl.exe',
      [
        '-L',
        '-f',
        '--retry',
        '2',
        '--connect-timeout',
        '20',
        '--max-time',
        '600',
        '-A',
        'AgriKhata-Updater',
        '-H',
        'Accept: application/octet-stream,*/*',
        '-H',
        'Cache-Control: no-cache',
        '-H',
        'Pragma: no-cache',
        '-o',
        partial.path,
        uri.toString(),
      ],
      runInShell: false,
    );

    final stderrBuf = StringBuffer();
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuf.write, cancelOnError: false)
        .asFuture<void>();

    var finished = false;
    final exitFuture = process.exitCode.then((code) {
      finished = true;
      return code;
    });

    while (!finished) {
      await Future.any([
        Future<void>.delayed(const Duration(milliseconds: 250)),
        exitFuture,
      ]);
      try {
        if (await partial.exists()) {
          onProgress?.call(await partial.length(), totalBytes);
        }
      } catch (_) {}
    }

    await stdoutDone;
    await stderrDone;
    final code = await exitFuture;
    if (code != 0) {
      final err = stderrBuf.toString().trim();
      throw StateError(
        'Download failed (curl exit $code)'
        '${err.isEmpty ? '' : ':\n$err'}',
      );
    }

    if (await partial.exists()) {
      onProgress?.call(await partial.length(), totalBytes);
    }
  }

  Future<void> _downloadWithPowerShell(
    Uri uri,
    File partial, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    onProgress?.call(0, 0);
    final safeUrl = uri.toString().replaceAll("'", "''");
    final safePath = partial.path.replaceAll("'", "''");
    final script = '''
\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri '$safeUrl' -OutFile '$safePath' -UseBasicParsing -TimeoutSec 600 -UserAgent 'AgriKhata-Updater'
''';

    final process = await Process.start(
      'powershell.exe',
      ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script],
      runInShell: false,
    );

    final stderrBuf = StringBuffer();
    final stdoutDone = process.stdout.drain<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderrBuf.write, cancelOnError: false)
        .asFuture<void>();

    var finished = false;
    final exitFuture = process.exitCode.then((code) {
      finished = true;
      return code;
    });

    while (!finished) {
      await Future.any([
        Future<void>.delayed(const Duration(milliseconds: 250)),
        exitFuture,
      ]);
      try {
        if (await partial.exists()) {
          onProgress?.call(await partial.length(), 0);
        }
      } catch (_) {}
    }

    await stdoutDone;
    await stderrDone;
    final code = await exitFuture;
    if (code != 0) {
      final err = stderrBuf.toString().trim();
      throw StateError(
        'Download failed (PowerShell exit $code)'
        '${err.isEmpty ? '' : ':\n$err'}',
      );
    }

    if (await partial.exists()) {
      final len = await partial.length();
      onProgress?.call(len, len);
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
  /// Returns false when identity cannot be read (caller may re-download).
  Future<bool> _msixIdentityVersionMatches(
    String msixPath,
    String expected,
  ) async {
    final identity = await _readMsixIdentityVersion(msixPath);
    if (identity == null) return false;
    return _versionsEqual(identity, expected);
  }

  /// Compares versions after normalizing Windows 4-part identities (`1.0.16.0`).
  bool _versionsEqual(String a, String b) {
    return normalizeVersion(a) == normalizeVersion(b);
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

  /// Strips build/prerelease metadata and trailing Windows revision
  /// (`1.0.16.0` → `1.0.16`).
  static String normalizeVersion(String version) {
    final cleaned = version.split('+').first.split('-').first.trim();
    final withoutV =
        cleaned.startsWith('v') || cleaned.startsWith('V')
            ? cleaned.substring(1)
            : cleaned;
    final parts = withoutV
        .split('.')
        .where((p) => p.isNotEmpty)
        .take(3)
        .map((p) => (int.tryParse(p) ?? 0).toString())
        .toList();
    while (parts.length < 3) {
      parts.add('0');
    }
    return parts.join('.');
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
    final normalized = normalizeVersion(version);
    final parts = normalized.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0,
    ];
  }
}
