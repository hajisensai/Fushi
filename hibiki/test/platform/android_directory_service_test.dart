import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/platform/android/android_directory_service.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

void main() {
  test('AndroidDirectoryService implements PlatformDirectoryService', () {
    expect(AndroidDirectoryService.new, isA<Function>());
    final service = AndroidDirectoryService();
    expect(service, isA<PlatformDirectoryService>());
  });
}
