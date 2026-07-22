import 'dart:convert';
import 'dart:io';

import 'package:agrikhata/Database/database_helper.dart';
import 'package:agrikhata/Widgets/update_dialog.dart';
import 'package:agrikhata/utils/app_version.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Checks GitHub-hosted [version.json] and prompts when a newer build exists.
class UpdateService {
  static const _manifestUrl =
      'https://raw.githubusercontent.com/Saleem-Palal/AgriKhata/master/version.json';

  static const _packageIdentity = 'com.saleempalal.agrikhata';

  Future<void> checkForUpdates(BuildContext context) async {
    try {
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
        return;
      }
      if (!context.mounted) return;

      await UpdateDialog.show(
        context,
        latestVersion: latestVersion,
        currentVersion: currentVersion,
        changelog: changelog,
        downloadUrl: downloadUrl,
        onUpdateNow: (url, {onStatus, onProgress}) => downloadAndInstall(
          url,
          onStatus: onStatus,
          onProgress: onProgress,
        ),
      );
    } catch (e, st) {
      debugPrint('UpdateService: check failed: $e\n$st');
    }
  }

  /// Downloads the MSIX locally, then installs it. Never opens a browser URL.
  ///
  /// [onProgress] receives `(receivedBytes, totalBytes)`. `totalBytes` is `0`
  /// when the server omits `Content-Length`.
  ///
  /// Does **not** call [exit] — that looked like a crash right after 100%.
  /// Packaged installs rely on `Add-AppxPackage -ForceApplicationShutdown`
  /// so Windows closes this process only when the package is actually applied.
  Future<void> downloadAndInstall(
    String downloadUrl, {
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

    onStatus?.call('Preparing update...');
    // Keep the payload outside the MSIX package folder. App temp under
    // Packages\...\TempState can vanish while the package is replaced.
    final msixFile = await _updatePackageFile();
    if (await msixFile.exists()) {
      await msixFile.delete();
    }

    await _downloadFile(uri, msixFile, onProgress: onProgress);

    final length = await msixFile.length();
    if (length < 1024 * 100) {
      // Real packages are several MB; tiny files are usually HTML error pages.
      throw StateError(
        'Downloaded file looks invalid ($length bytes). '
        'Check that download_url is a direct .msix asset link.',
      );
    }

    final msixPath = msixFile.path;
    debugPrint('UpdateService: installing local file $msixPath ($length bytes)');

    final packaged = _isRunningAsPackagedMsix();
    if (!packaged) {
      onStatus?.call('Opening installer...');
      final opened = await _launchInstallerUi(msixPath);
      if (!opened) {
        throw StateError(
          'Could not open the MSIX installer. '
          'Install the packaged AgriKhata build to use automatic updates, '
          'or run the downloaded .msix manually.',
        );
      }
      onStatus?.call(
        'Installer opened. Finish the Windows install, then restart AgriKhata.',
      );
      return;
    }

    onStatus?.call('Download complete. Installing update...');
    await _flushUiFrames();
    await Future.delayed(const Duration(milliseconds: 600));

    onStatus?.call(
      'Installing… Windows will close and reopen AgriKhata when ready.',
    );
    await _flushUiFrames();

    final logFile = File(p.join(_updateDirPath(), 'agrikhata_update.log'));
    if (await logFile.exists()) {
      try {
        await logFile.delete();
      } catch (_) {}
    }

    final started = await _installLocalMsix(msixPath);
    if (!started) {
      onStatus?.call('Automatic install unavailable. Opening installer...');
      await _flushUiFrames();
      final opened = await _launchInstallerUi(msixPath);
      if (!opened) {
        throw StateError(
          'Could not install the update automatically. '
          'Run install.bat once as Administrator to trust the certificate, '
          'then try again.',
        );
      }
      onStatus?.call(
        'Installer opened. Finish the Windows install, then restart AgriKhata.',
      );
      return;
    }

    // Stay alive until Windows applies the package (ForceApplicationShutdown)
    // or the installer reports failure in the log. Never call exit() ourselves.
    final deadline = DateTime.now().add(const Duration(minutes: 2));
    while (DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(seconds: 1));
      if (!await logFile.exists()) continue;
      String text;
      try {
        text = await logFile.readAsString();
      } catch (_) {
        continue;
      }
      if (text.contains('Update FAILED:')) {
        final failLine = text
            .split(RegExp(r'\r?\n'))
            .lastWhere(
              (line) => line.contains('Update FAILED:'),
              orElse: () => 'Update FAILED: unknown error',
            );
        final detail = failLine.split('Update FAILED:').last.trim();
        throw StateError(
          detail.isEmpty
              ? 'The update could not be installed. See ${logFile.path}'
              : detail,
        );
      }
      if (text.contains('Update completed successfully')) {
        onStatus?.call(
          'Update installed. Please restart AgriKhata if it is still open.',
        );
        return;
      }
    }
    throw StateError(
      'The update is taking too long or did not finish. '
      'See ${logFile.path}, or run the installer under '
      '${_updateDirPath()} manually.',
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

  Future<File> _updatePackageFile() async {
    final dir = Directory(_updateDirPath());
    await dir.create(recursive: true);
    return File(p.join(dir.path, 'agrikhata_update.msix'));
  }

  /// True when running as an installed MSIX (not `flutter run` / unpackaged exe).
  bool _isRunningAsPackagedMsix() {
    final env = Platform.environment;
    if (env.containsKey('APPX_PACKAGE_FULL_NAME') ||
        env.containsKey('APPX_PACKAGE_NAME')) {
      return true;
    }
    final exe = Platform.resolvedExecutable.toLowerCase();
    return exe.contains(r'\windowsapps\');
  }

  /// Yields so [setState] from [onStatus] can paint.
  Future<void> _flushUiFrames() async {
    try {
      final binding = WidgetsBinding.instance;
      await binding.endOfFrame;
      binding.scheduleFrame();
      await binding.endOfFrame;
    } catch (_) {
      // Binding may be unavailable in rare edge cases; delay still helps.
    }
  }

  /// Prefer a direct asset URL. Never returns a GitHub web page URL.
  String _resolveMsixUrl(String raw) {
    final url = raw.trim();
    if (url.toLowerCase().endsWith('.msix')) return url;

    // releases/tag/vX.Y.Z -> releases/download/vX.Y.Z/agrikhata.msix
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

  Future<void> _downloadFile(
    Uri uri,
    File destination, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers['User-Agent'] = 'AgriKhata-Updater';
      request.headers['Accept'] = 'application/octet-stream,*/*';

      final streamed = await client
          .send(request)
          .timeout(const Duration(minutes: 5));

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
        // Throttle UI updates (~10 Hz or on percent change) to keep frames smooth.
        if (!force &&
            elapsed < const Duration(milliseconds: 100) &&
            percent == lastEmittedPercent) {
          return;
        }
        lastUiEmit = now;
        lastEmittedPercent = percent;
        onProgress?.call(receivedBytes, totalBytes);
      }

      final sink = destination.openWrite();
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

      debugPrint(
        'UpdateService: download complete '
        '($receivedBytes / ${totalBytes > 0 ? totalBytes : "?"} bytes)',
      );
    } finally {
      client.close();
    }
  }

  /// Releases SQLite locks, then starts Add-AppxPackage in a detached process.
  ///
  /// Returns true if the installer process was started. Does not call [exit] —
  /// `-ForceApplicationShutdown` closes this app when Windows applies the package.
  Future<bool> _installLocalMsix(String msixPath) async {
    try {
      debugPrint('UpdateService: closing database before install...');
      await DatabaseHelper.instance.close();
      // Allow WAL/journal handles to finish releasing on Windows.
      await Future.delayed(const Duration(milliseconds: 500));

      final safePath = msixPath.replaceAll("'", "''");
      final logPath =
          p.join(_updateDirPath(), 'agrikhata_update.log').replaceAll("'", "''");

      final launched = await _launchDetachedInstaller(safePath, logPath);
      if (launched) {
        debugPrint(
          'UpdateService: Add-AppxPackage started (no hard exit; log: $logPath)',
        );
        return true;
      }
      return false;
    } catch (e, st) {
      debugPrint('UpdateService: install launcher error: $e\n$st');
      return false;
    }
  }

  /// Runs Add-AppxPackage in a detached PowerShell process, then relaunches.
  ///
  /// Failures are written to [logPath] and shown in a MessageBox.
  Future<bool> _launchDetachedInstaller(String safePath, String logPath) async {
    try {
      final script = '''
\$ErrorActionPreference = 'Stop'
\$logFile = '$logPath'
function Write-UpdateLog([string]\$Message) {
  \$line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), \$Message)
  Add-Content -Path \$logFile -Value \$line -ErrorAction SilentlyContinue
}
try {
  Write-UpdateLog "Installing MSIX: $safePath"
  if (-not (Test-Path -LiteralPath '$safePath')) {
    throw "Update package not found: $safePath"
  }
  # ForceApplicationShutdown closes AgriKhata only when the package is applied.
  Add-AppxPackage -Path '$safePath' -ForceUpdateFromAnyVersion -ForceApplicationShutdown
  Start-Sleep -Seconds 2
  \$pkg = Get-AppxPackage -Name '$_packageIdentity' | Sort-Object -Property Version -Descending | Select-Object -First 1
  if (\$null -eq \$pkg) { throw 'Package not found after install ($_packageIdentity).' }
  \$manifest = Get-AppxPackageManifest -Package \$pkg
  \$appId = \$manifest.Package.Applications.Application.Id
  if (\$appId -is [System.Array]) { \$appId = \$appId[0] }
  if (-not \$appId) { \$appId = 'App' }
  \$aumid = \$pkg.PackageFamilyName + '!' + \$appId
  Write-UpdateLog "Relaunching \$aumid"
  Start-Process ("shell:AppsFolder\\" + \$aumid)
  Write-UpdateLog 'Update completed successfully.'
} catch {
  \$err = \$_.Exception.Message
  Write-UpdateLog ("Update FAILED: " + \$err)
  try {
    Add-Type -AssemblyName PresentationFramework | Out-Null
    [System.Windows.MessageBox]::Show(
      ("AgriKhata could not finish the update.`n`n" + \$err + "`n`nDetails: $logPath"),
      'AgriKhata Update',
      'OK',
      'Error'
    ) | Out-Null
  } catch { }
  exit 1
}
''';

      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-Command',
          script,
        ],
        mode: ProcessStartMode.detached,
      );

      debugPrint('UpdateService: Add-AppxPackage scheduled (detached)');
      return true;
    } catch (e, st) {
      debugPrint('UpdateService: detached Add-AppxPackage failed: $e\n$st');
      return false;
    }
  }

  /// Opens the MSIX with the Windows App Installer UI (app stays running).
  Future<bool> _launchInstallerUi(String msixPath) async {
    try {
      final safePath = msixPath.replaceAll("'", "''");
      await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-Command',
          "Start-Process -FilePath '$safePath'",
        ],
        mode: ProcessStartMode.detached,
      );
      debugPrint('UpdateService: launched local MSIX installer UI');
      return true;
    } catch (e, st) {
      debugPrint('UpdateService: Start-Process installer UI failed: $e\n$st');
      return false;
    }
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
