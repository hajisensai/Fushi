import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

class FakePlatformDirectoryService implements PlatformDirectoryService {
  @override
  Future<String> getHibikiExportDirectory() async => '/fake/export';
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
    expect(await svc.getHibikiExportDirectory(), '/fake/export');
    expect(await svc.getExternalStorageDirectories(), ['/fake/sd']);
    expect(await svc.getDefaultPickerDirectories(), ['/fake']);
  });
}
