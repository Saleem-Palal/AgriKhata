import 'package:flutter_test/flutter_test.dart';

import 'package:agrikhata/services/update_service.dart';

void main() {
  group('UpdateService.normalizeVersion', () {
    test('strips Windows 4-part identity to 3-part semver', () {
      expect(UpdateService.normalizeVersion('1.0.16.0'), '1.0.16');
      expect(UpdateService.normalizeVersion('1.0.16'), '1.0.16');
      expect(UpdateService.normalizeVersion('v1.0.16.0'), '1.0.16');
    });

    test('ignores build and prerelease metadata', () {
      expect(UpdateService.normalizeVersion('1.0.16+16'), '1.0.16');
      expect(UpdateService.normalizeVersion('1.0.16-beta.1'), '1.0.16');
    });
  });

  group('UpdateService.isNewerVersion', () {
    test('detects newer patch / minor / major', () {
      expect(UpdateService.isNewerVersion('1.0.17', '1.0.16'), isTrue);
      expect(UpdateService.isNewerVersion('1.1.0', '1.0.99'), isTrue);
      expect(UpdateService.isNewerVersion('2.0.0', '1.9.9'), isTrue);
    });

    test('rejects equal or older', () {
      expect(UpdateService.isNewerVersion('1.0.17', '1.0.17'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.16', '1.0.17'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.17.0', '1.0.17'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.17', '1.0.17.0'), isFalse);
    });

    test('ignores build metadata', () {
      expect(UpdateService.isNewerVersion('1.0.17+17', '1.0.16+16'), isTrue);
      expect(UpdateService.isNewerVersion('1.0.17', '1.0.17+16'), isFalse);
    });
  });
}
