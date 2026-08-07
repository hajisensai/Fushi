import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/platform/android/android_directory_service.dart';
import 'package:fushi_platform/fushi_platform.dart';

void main() {
  test('AndroidDirectoryService implements PlatformDirectoryService', () {
    expect(AndroidDirectoryService.new, isA<Function>());
    final service = AndroidDirectoryService();
    expect(service, isA<PlatformDirectoryService>());
  });
}
