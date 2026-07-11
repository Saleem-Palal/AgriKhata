import 'dart:convert';

import 'package:flutter/services.dart';

/// Reads the bundled [assets/version.json] that ships with the app.
///
/// Keep this file in sync with the repo-root `version.json` (GitHub raw URL).
class AppVersion {
  static const assetPath = 'assets/version.json';

  static String? _cached;

  /// Returns the local `latest_version` string, e.g. `"1.0.1"`.
  static Future<String> current() async {
    if (_cached != null) return _cached!;
    try {
      final raw = await rootBundle.loadString(assetPath);
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final version = (map['latest_version'] as String?)?.trim() ?? '';
      _cached = version;
      return version;
    } catch (_) {
      return '';
    }
  }

  /// Display label, e.g. `"v1.0.1"`, or empty if unavailable.
  static Future<String> displayLabel() async {
    final version = await current();
    if (version.isEmpty) return '';
    return version.startsWith('v') ? version : 'v$version';
  }
}
