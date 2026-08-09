import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_platform/fushi_platform.dart';

class FakePlatformDirectoryService implements PlatformDirectoryService {
  @override
  Future<List<String>> getExternalStorageDirectories() async => ['/fake/sd'];
  @override
  Future<List<String>> getDefaultPickerDirectories() async => ['/fake'];
  @override
  Future<void> excludeFromMediaScanner(String directoryPath) async {}
}

void main() {
  test('FakePlatformDirectoryService implements contract', () async {
    final svc = FakePlatformDirectoryService();
    expect(await svc.getExternalStorageDirectories(), ['/fake/sd']);
    expect(await svc.getDefaultPickerDirectories(), ['/fake']);
  });
}
