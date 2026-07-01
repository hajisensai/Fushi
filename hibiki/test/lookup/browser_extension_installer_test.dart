import 'dart:convert';
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

  // TODO-1087：自动配置注入函数。buildBrowserExtensionDefaultsJs 把 server 真值写成
  // 扩展的 hibiki-defaults.js（self.HIBIKI_DEFAULTS）。测注入结果字面正确 + 转义安全。
  group('buildBrowserExtensionDefaultsJs', () {
    test('emits host/port/token into self.HIBIKI_DEFAULTS', () {
      final String js = buildBrowserExtensionDefaultsJs(
        const BrowserExtensionServerConfig(
          host: '127.0.0.1',
          port: 19633,
          token: 'abc123',
        ),
      );
      expect(js, contains('self.HIBIKI_DEFAULTS'));
      expect(js, contains('host: "127.0.0.1"'));
      expect(js, contains('port: 19633'));
      expect(js, contains('token: "abc123"'));
    });

    test('json-encodes host/token so quotes cannot break out', () {
      final String js = buildBrowserExtensionDefaultsJs(
        const BrowserExtensionServerConfig(
          host: 'ho"st',
          port: 1,
          token: r'a"b\c',
        ),
      );
      // 双引号/反斜杠必须被 JSON 转义，不能裸出破坏 JS 语法。
      // 用 jsonEncode 计算期望，避免手工转义歧义：编码后不含裸引号越界。
      expect(js, contains('host: ' + jsonEncode('ho"st') + ','));
      expect(js, contains('token: ' + jsonEncode(r'a"b\c') + ','));
    });
  });

  // TODO-1087：扩展默认端口/主机守卫。打包扩展的 hibiki-defaults.js 与 background.js
  // 的默认必须指向本机环回 + kYomitanApiDefaultPort(19633)，否则「加载已解压」后默认连不上。
  group('bundled extension default connection', () {
    test('hibiki-defaults.js defaults to 127.0.0.1:19633', () {
      final File defaults = File('assets/browser_extension/hibiki-defaults.js');
      expect(defaults.existsSync(), isTrue,
          reason: 'missing bundled hibiki-defaults.js');
      final String src = defaults.readAsStringSync();
      expect(src, contains('self.HIBIKI_DEFAULTS'));
      expect(src, contains("host: '127.0.0.1'"));
      expect(src, contains('port: 19633'));
    });

    test('background.js falls back to HIBIKI_DEFAULTS (not port 0)', () {
      final File bg = File('assets/browser_extension/background.js');
      final String src = bg.readAsStringSync();
      // 必须 importScripts 默认文件 + cfg() 引用 HIBIKI_DEFAULTS 作回落。
      expect(src, contains("importScripts('hibiki-defaults.js')"));
      expect(src, contains('HIBIKI_DEFAULTS'));
      // 不再无条件默认 port=0（那会导致默认连不上）。
      expect(src, isNot(contains('port = 0')));
    });
  });
}
