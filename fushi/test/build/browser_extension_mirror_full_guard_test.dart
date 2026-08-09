import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// G15 全目录镜像守卫：`tools/browser-extension/`（唯一真相源）与随 app 打包的
/// `assets/browser_extension/` 必须整目录字节一致——不再是逐文件手工点名
/// （browser_extension_dict_media_mirror_guard_test.dart 只锁 TODO-1215/1219
/// 涉及的 15 个文件，新增文件不改测试就没有守卫，dict-media.js 历史上正是这样
/// 漂移的，58a7d4fa 修复）。
///
/// 镜像清单规则与 `tool/sync_browser_extension.dart` 保持一致（同步改）：
/// 排除 `*.test.js` 与 `scripts/`，vendor/ 整目录纳入；assets 侧不允许有清单
/// 之外的多余文件。漂移时跑 `dart run tool/sync_browser_extension.dart`。
///
/// flutter test cwd 是 hibiki 包根。
void main() {
  const String toolsRoot = '../tools/browser-extension';
  const String assetsRoot = 'assets/browser_extension';

  bool isMirrored(String rel) {
    if (rel.endsWith('.test.js')) return false;
    if (rel == 'scripts' || rel.startsWith('scripts/')) return false;
    // README 不进 app 资产包（与 tool/sync_browser_extension.dart 及
    // scripts/sync-mirrors.mjs 的清单规则三方一致）。
    if (rel == 'README.md') return false;
    return true;
  }

  List<String> collect(String root) {
    final Directory dir = Directory(root);
    final List<String> out = <String>[];
    for (final FileSystemEntity e in dir.listSync(recursive: true)) {
      if (e is! File) continue;
      final String rel = e.path
          .substring(dir.path.length)
          .replaceAll('\\', '/')
          .replaceFirst(RegExp('^/'), '');
      if (!isMirrored(rel)) continue;
      out.add(rel);
    }
    out.sort();
    return out;
  }

  test('assets 镜像的文件集合与 tools 源完全一致（无缺失、无残留）', () {
    final List<String> tools = collect(toolsRoot);
    final List<String> assets = collect(assetsRoot);
    expect(tools, isNotEmpty, reason: '源目录空？路径错了');
    expect(assets, tools,
        reason: '镜像文件集合漂移：跑 dart run tool/sync_browser_extension.dart');
  });

  test('镜像中每个文件与 tools 源字节一致', () {
    for (final String rel in collect(toolsRoot)) {
      final File src = File('$toolsRoot/$rel');
      final File dst = File('$assetsRoot/$rel');
      expect(dst.existsSync(), isTrue,
          reason:
              '$assetsRoot/$rel 缺失：跑 dart run tool/sync_browser_extension.dart');
      expect(dst.readAsBytesSync(), src.readAsBytesSync(),
          reason: '$assetsRoot/$rel 与源不一致：'
              '跑 dart run tool/sync_browser_extension.dart');
    }
  });
}
