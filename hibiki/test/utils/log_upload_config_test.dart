import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/log_upload_config.dart';

void main() {
  group('isLogUploadConfigured', () {
    test('空端点 → 未配置', () {
      expect(isLogUploadConfigured(''), isFalse);
      expect(isLogUploadConfigured('   '), isFalse);
    });
    test('非 http 端点 → 未配置（防误填）', () {
      expect(isLogUploadConfigured('logs.example.com'), isFalse);
    });
    test('https 端点 → 已配置', () {
      expect(
          isLogUploadConfigured('https://logs.example.com/api/logs'), isTrue);
    });
  });
}
