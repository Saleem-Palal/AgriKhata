import 'package:flutter_test/flutter_test.dart';

import 'package:agrikhata/services/update_service.dart';

void main() {
  group('UpdateService.isNewerVersion', () {
    test('detects newer patch / minor / major', () {
      expect(UpdateService.isNewerVersion('1.0.16', '1.0.15'), isTrue);
      expect(UpdateService.isNewerVersion('1.1.0', '1.0.99'), isTrue);
      expect(UpdateService.isNewerVersion('2.0.0', '1.9.9'), isTrue);
    });

    test('rejects equal or older', () {
      expect(UpdateService.isNewerVersion('1.0.16', '1.0.16'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.15', '1.0.16'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.16.0', '1.0.16'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.16', '1.0.16.0'), isFalse);
    });

    test('ignores build metadata', () {
      expect(UpdateService.isNewerVersion('1.0.16+16', '1.0.15+15'), isTrue);
      expect(UpdateService.isNewerVersion('1.0.16', '1.0.16+15'), isFalse);
    });
  });
}
