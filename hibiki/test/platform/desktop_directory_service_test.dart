import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/platform/desktop/desktop_directory_service.dart';
import 'package:hibiki_platform/hibiki_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('DesktopDirectoryService implements PlatformDirectoryService', () {
    final svc = DesktopDirectoryService();
    expect(svc, isA<PlatformDirectoryService>());
  });

  test('getExternalStorageDirectories returns empty list on desktop', () async {
    final svc = DesktopDirectoryService();
    final dirs = await svc.getExternalStorageDirectories();
    expect(dirs, isEmpty);
  });

  test('excludeFromMediaScanner is no-op on desktop', () async {
    final svc = DesktopDirectoryService();
    await svc.excludeFromMediaScanner('/some/path');
  });
}
