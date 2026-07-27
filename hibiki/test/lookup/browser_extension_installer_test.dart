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
  // tools/browser-extension/ 逐字节一致（排除 *.test.js 测试文件、scripts/ 构建工具与
  // README.md 文档）。改了扩展源却忘同步 bundle → 助手装出的是旧扩展；此守卫强制同步。
  // 重新同步：跑 `node tools/browser-extension/scripts/sync-mirrors.mjs`（同样的排除规则，
  // `--check` 只校验）。
  // scripts/（TODO-1267 的 generate-content-css.mjs + content-css-overlay.css + 同步脚本）是
  // **构建期工具**：manifest 不加载，与 *.test.js 同类不进发布 bundle。README.md 是开发文档，
  // 不进 bundle——否则内容指纹会随文档改动翻新，触发无意义的扩展自更新 reload。
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
        if (rel.startsWith('scripts/')) continue; // 构建期生成器/overlay 不进 bundle
        if (rel == 'README.md') continue; // 开发文档不进 bundle（防指纹随文档翻新）
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
      expect(js, contains('host: ${jsonEncode('ho"st')},'));
      expect(js, contains('token: ${jsonEncode(r'a"b\c')},'));
    });
  });

  // BUG-726：扩展内容指纹 + build 注入/解析。指纹是「app 升级 → 磁盘副本刷新 → 扩展自
  // reload」链路的身份真值：解压时写进 hibiki-defaults.js（build），查词响应下发同一指纹
  //（extensionBuild），两侧一致 = 最新，不一致 = 扩展 reload 拉新。
  group('browser extension fingerprint (BUG-726)', () {
    test('deterministic over content, order-independent', () {
      final Map<String, List<int>> a = <String, List<int>>{
        'background.js': <int>[1, 2, 3],
        'vendor/popup.js': <int>[4, 5],
      };
      final Map<String, List<int>> b = <String, List<int>>{
        'vendor/popup.js': <int>[4, 5],
        'background.js': <int>[1, 2, 3],
      };
      expect(computeBrowserExtensionFingerprint(a),
          computeBrowserExtensionFingerprint(b));
      expect(computeBrowserExtensionFingerprint(a), hasLength(16));
    });

    test('changes when any file content changes', () {
      final Map<String, List<int>> a = <String, List<int>>{
        'background.js': <int>[1, 2, 3],
      };
      final Map<String, List<int>> b = <String, List<int>>{
        'background.js': <int>[1, 2, 4],
      };
      expect(computeBrowserExtensionFingerprint(a),
          isNot(computeBrowserExtensionFingerprint(b)));
    });

    test('ignores hibiki-defaults.js (rewritten on every extract)', () {
      final Map<String, List<int>> a = <String, List<int>>{
        'background.js': <int>[1],
        'hibiki-defaults.js': <int>[9, 9],
      };
      final Map<String, List<int>> b = <String, List<int>>{
        'background.js': <int>[1],
        'hibiki-defaults.js': <int>[7],
      };
      expect(computeBrowserExtensionFingerprint(a),
          computeBrowserExtensionFingerprint(b));
    });

    test('defaults js build key round-trips through parse', () {
      const BrowserExtensionServerConfig cfg = BrowserExtensionServerConfig(
          host: '127.0.0.1', port: 19633, token: 't');
      final String withBuild =
          buildBrowserExtensionDefaultsJs(cfg, build: 'deadbeef01234567');
      expect(parseBrowserExtensionBuild(withBuild), 'deadbeef01234567');
      // 不传 build（旧调用/占位）→ 不写键、解析回 null（与旧副本一致 → 触发刷新）。
      final String withoutBuild = buildBrowserExtensionDefaultsJs(cfg);
      expect(withoutBuild, isNot(contains('build:')));
      expect(parseBrowserExtensionBuild(withoutBuild), isNull);
    });

    test('prepareBundledBrowserExtension writes fingerprint into defaults', () {
      // 生产接线守卫（源码扫描）：解压时必须把指纹写进 hibiki-defaults.js 的 build，
      // 否则启动刷新（refreshBundledBrowserExtensionIfStale）恒判陈旧、每次启动全量重写。
      final String src = File('lib/src/lookup/browser_extension_installer.dart')
          .readAsStringSync();
      expect(src, contains('build: computeBrowserExtensionFingerprint('));
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
      // 不匹配闭合括号：TODO-1087 诊断特性后 importScripts 追加了
      // 'connection-diagnostics.js'（同一 importScripts 调用多参），
      // hibiki-defaults.js 仍被导入，守卫只认「该文件被 importScripts」这个契约。
      expect(src, contains("importScripts('hibiki-defaults.js'"));
      expect(src, contains('HIBIKI_DEFAULTS'));
      // 不再无条件默认 port=0（那会导致默认连不上）。
      expect(src, isNot(contains('port = 0')));
    });
  });
}
