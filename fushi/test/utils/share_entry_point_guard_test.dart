import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2064：系统分享必须**只有一个入口** `FushiShare`。
///
/// share_plus 的 iOS 端（`FPPSharePlusPlugin.m`）把 text / uri / files 三条路径
/// 汇进同一个 `+share:`，并要求 popover 锚点 rect 非空且完全落在 root view 内；
/// 缺 `sharePositionOrigin` 时 rect 是 `CGRectZero`，必抛
/// `PlatformException(error, sharePositionOrigin: argument must be set, ...)`。
/// 锚点只在 `FushiShare` 内统一解析，任何绕过入口直接调 `Share.xxx` 的新代码都会
/// 把这个崩溃带回来（历史上正是这样漏掉了截图分享），故在源码层挡住。
///
/// 同时挡 `SharePlus`（share_plus 10+ 的新 API 名），避免升级依赖时静默开一道口子。
void main() {
  test('lib/ 下只有 fushi_share.dart 能直接调 share_plus 的分享 API', () {
    final Directory libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue,
        reason: '必须在 fushi/ 下运行（cwd=${Directory.current.path}）');

    const String entryPointPath = 'lib/src/utils/misc/fushi_share.dart';
    final RegExp forbidden = RegExp(r'\b(Share\.share|SharePlus\b)');

    final List<String> offenders = <String>[];
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String normalized = entity.path.replaceAll(r'\', '/');
      final String relative = 'lib/${normalized.split('lib/').last}';
      if (relative == entryPointPath) continue;

      final List<String> lines = entity.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String code = _stripLineComment(lines[i]);
        if (forbidden.hasMatch(code)) {
          offenders.add('$relative:${i + 1}: ${lines[i].trim()}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '这些地方绕过了 FushiShare，iOS/iPad 上会因缺 sharePositionOrigin '
          '抛 PlatformException：\n${offenders.join('\n')}',
    );
  });

  test('FushiShare 自身确实携带 sharePositionOrigin（守卫的另一半）', () {
    final String source =
        File('lib/src/utils/misc/fushi_share.dart').readAsStringSync();
    final Iterable<RegExpMatch> passes =
        RegExp(r'sharePositionOrigin:\s*_sharePositionOrigin\(\)')
            .allMatches(source);
    expect(passes.length, greaterThanOrEqualTo(2),
        reason: '文件分享与文本分享两条路径都必须传锚点');
  });
}

/// 去掉行尾 `//` 注释，避免文档注释里对 `Share.share` 的引用把守卫弄成假红。
String _stripLineComment(String line) {
  final int index = line.indexOf('//');
  return index < 0 ? line : line.substring(0, index);
}
