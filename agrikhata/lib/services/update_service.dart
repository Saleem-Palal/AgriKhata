import 'dart:convert';
import 'dart:io';

import 'package:agrikhata/Widgets/update_dialog.dart';
import 'package:agrikhata/utils/app_version.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Checks GitHub-hosted [version.json] and prompts when a newer build exists.
class UpdateService {
  static const _manifestUrl =
      'https://raw.githubusercontent.com/Saleem-Palal/AgriKhata/master/version.json';

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
        onUpdateNow: (url, {onStatus}) =>
            downloadAndInstall(url, onStatus: onStatus),
      );
    } catch (e) {
      debugPrint('UpdateService: check failed: $e');
    }
  }

  /// Downloads the MSIX locally, then installs it. Never opens a browser URL.
  Future<void> downloadAndInstall(
    String downloadUrl, {
    void Function(String status)? onStatus,
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

    onStatus?.call('Downloading update...');
    final tempDir = await getTemporaryDirectory();
    final msixPath = p.join(tempDir.path, 'agrikhata_update.msix');
    final msixFile = File(msixPath);
    if (await msixFile.exists()) {
      await msixFile.delete();
    }

    await _downloadFile(uri, msixFile);

    final length = await msixFile.length();
    if (length < 1024 * 100) {
      // Real packages are several MB; tiny files are usually HTML error pages.
      throw StateError(
        'Downloaded file looks invalid ($length bytes). '
        'Check that download_url is a direct .msix asset link.',
      );
    }

    onStatus?.call('Installing update...');
    debugPrint('UpdateService: installing local file $msixPath ($length bytes)');

    final installed = await _installLocalMsix(msixPath);
    if (!installed) {
      throw StateError(
        'Could not install the update automatically. '
        'Run install.bat once as Administrator to trust the certificate, '
        'then try again.',
      );
    }

    onStatus?.call('Update installed. The app may restart...');
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

  Future<void> _downloadFile(Uri uri, File destination) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers['User-Agent'] = 'AgriKhata-Updater';
      request.headers['Accept'] = 'application/octet-stream,*/*';

      final streamed = await client
          .send(request)
          .timeout(const Duration(minutes: 5));

      // Follow redirects manually if needed (http.Client usually follows).
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

      final sink = destination.openWrite();
      try {
        await streamed.stream.pipe(sink);
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  /// Installs a local .msix path. Returns true on apparent success.
  Future<bool> _installLocalMsix(String msixPath) async {
    final safePath = msixPath.replaceAll("'", "''");

    // 1) Preferred: silent/in-place AppX update (closes this app).
    final addResult = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "Add-AppxPackage -Path '$safePath' -ForceUpdateFromAnyVersion -ForceApplicationShutdown",
    ]);

    if (addResult.exitCode == 0) {
      debugPrint('UpdateService: Add-AppxPackage succeeded');
      return true;
    }

    debugPrint(
      'UpdateService: Add-AppxPackage failed '
      '(${addResult.exitCode}): ${addResult.stderr}\n${addResult.stdout}',
    );

    // 2) Fallback: open the LOCAL installer UI (not a website).
    final startResult = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "Start-Process -FilePath '$safePath'",
    ]);

    if (startResult.exitCode == 0) {
      debugPrint('UpdateService: launched local MSIX installer UI');
      return true;
    }

    debugPrint(
      'UpdateService: Start-Process failed '
      '(${startResult.exitCode}): ${startResult.stderr}\n${startResult.stdout}',
    );
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
