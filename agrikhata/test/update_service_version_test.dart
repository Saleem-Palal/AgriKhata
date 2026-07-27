import 'package:flutter_test/flutter_test.dart';

import 'package:agrikhata/services/update_service.dart';

void main() {
  group('UpdateService.isNewerVersion', () {
    test('detects newer patch / minor / major', () {
      expect(UpdateService.isNewerVersion('1.0.14', '1.0.13'), isTrue);
      expect(UpdateService.isNewerVersion('1.1.0', '1.0.99'), isTrue);
      expect(UpdateService.isNewerVersion('2.0.0', '1.9.9'), isTrue);
    });

    test('rejects equal or older', () {
      expect(UpdateService.isNewerVersion('1.0.14', '1.0.14'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.13', '1.0.14'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.14.0', '1.0.14'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.14', '1.0.14.0'), isFalse);
    });

    test('ignores build metadata', () {
      expect(UpdateService.isNewerVersion('1.0.14+14', '1.0.13+13'), isTrue);
      expect(UpdateService.isNewerVersion('1.0.14', '1.0.14+13'), isFalse);
    });
  });
}
