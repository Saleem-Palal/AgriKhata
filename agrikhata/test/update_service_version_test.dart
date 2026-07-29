import 'package:flutter_test/flutter_test.dart';

import 'package:agrikhata/services/update_service.dart';

void main() {
  group('UpdateService.isNewerVersion', () {
    test('detects newer patch / minor / major', () {
      expect(UpdateService.isNewerVersion('1.0.15', '1.0.14'), isTrue);
      expect(UpdateService.isNewerVersion('1.1.0', '1.0.99'), isTrue);
      expect(UpdateService.isNewerVersion('2.0.0', '1.9.9'), isTrue);
    });

    test('rejects equal or older', () {
      expect(UpdateService.isNewerVersion('1.0.15', '1.0.15'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.14', '1.0.15'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.15.0', '1.0.15'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.15', '1.0.15.0'), isFalse);
    });

    test('ignores build metadata', () {
      expect(UpdateService.isNewerVersion('1.0.15+15', '1.0.14+14'), isTrue);
      expect(UpdateService.isNewerVersion('1.0.15', '1.0.15+14'), isFalse);
    });
  });
}
