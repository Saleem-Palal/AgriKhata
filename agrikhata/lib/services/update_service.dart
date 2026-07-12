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
        onUpdateNow: downloadAndInstall,
      );
    } catch (e) {
      debugPrint('UpdateService: check failed: $e');
    }
  }

  /// Downloads the MSIX and installs it with Windows AppX APIs.
  ///
  /// [downloadUrl] must be a direct `.msix` link, e.g.
  /// `https://github.com/.../releases/download/v1.0.3/agrikhata.msix`
  Future<void> downloadAndInstall(
    String downloadUrl, {
    void Function(String status)? onStatus,
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('In-app updates are only supported on Windows.');
    }

    final uri = Uri.tryParse(downloadUrl);
    if (uri == null) {
      throw ArgumentError('Invalid download URL');
    }
    if (!downloadUrl.toLowerCase().contains('.msix')) {
      throw ArgumentError(
        'download_url must point directly to an .msix file, not a web page.',
      );
    }

    onStatus?.call('Downloading update...');
    final tempDir = await getTemporaryDirectory();
    final msixPath = p.join(tempDir.path, 'agrikhata_update.msix');
    final msixFile = File(msixPath);
    if (await msixFile.exists()) {
      await msixFile.delete();
    }

    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      request.headers['User-Agent'] = 'AgriKhata-Updater';
      request.headers['Accept'] = 'application/octet-stream';

      final streamed = await client
          .send(request)
          .timeout(const Duration(minutes: 5));

      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        throw HttpException(
          'Download failed (HTTP ${streamed.statusCode})',
          uri: uri,
        );
      }

      final sink = msixFile.openWrite();
      try {
        await streamed.stream.pipe(sink);
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }

    final length = await msixFile.length();
    if (length < 1024) {
      throw StateError('Downloaded update file looks invalid ($length bytes).');
    }

    onStatus?.call('Installing update...');
    debugPrint('UpdateService: installing $msixPath ($length bytes)');

    // ForceApplicationShutdown closes this running app so the package can update.
    final safePath = msixPath.replaceAll("'", "''");
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      "Add-AppxPackage -Path '$safePath' -ForceUpdateFromAnyVersion -ForceApplicationShutdown",
    ]);

    if (result.exitCode != 0) {
      final err = '${result.stderr}\n${result.stdout}'.trim();
      debugPrint('UpdateService: install failed: $err');
      throw StateError(
        err.isEmpty
            ? 'Install failed. Try running install.bat as Administrator once.'
            : err,
      );
    }

    onStatus?.call('Update installed. Restarting...');
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
