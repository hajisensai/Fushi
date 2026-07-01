import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/browser_extension_installer.dart';

void main() {
  group('browserExtensionsPageUrl', () {
    test('chrome / edge management page urls', () {
      expect(
          browserExtensionsPageUrl(BrowserKind.chrome), 'chrome://extensions');
      expect(browserExtensionsPageUrl(BrowserKind.edge), 'edge://extensions');
    });
  });

  // 漂移守卫（TODO-1000）：随 app 打包的 assets/browser_extension/ 必须与真源
  // tools/browser-extension/ 逐字节一致（排除 *.test.js 测试文件）。改了扩展源却忘同步
  // bundle → 助手装出的是旧扩展；此守卫强制同步。重新同步：把 tools/browser-extension 下
  // 非 *.test.js 文件复制进 hibiki/assets/browser_extension/（含 vendor/）。
  group('bundled extension matches source', () {
    final Directory srcDir = Directory('../tools/browser-extension');
    final Directory bundleDir = Directory('assets/browser_extension');

    test('source dir exists', () {
      expect(srcDir.existsSync(), isTrue, reason: 'missing ${srcDir.path}');
    });

    test('every loadable source file is bundled byte-identical', () {
      final List<FileSystemEntity> entities =
          srcDir.listSync(recursive: true).whereType<File>().toList();
      for (final FileSystemEntity e in entities) {
        final String rel = e.path
            .substring(srcDir.path.length)
            .replaceAll('\\', '/')
            .replaceFirst(RegExp(r'^/'), '');
        if (rel.endsWith('.test.js')) continue; // 测试文件不进 bundle
        final File bundled = File('${bundleDir.path}/$rel');
        expect(bundled.existsSync(), isTrue,
            reason: 'not bundled: $rel (run the re-sync copy)');
        expect(bundled.readAsBytesSync(), (e as File).readAsBytesSync(),
            reason: 'bundle out of sync with source: $rel');
      }
    });
  });
}
