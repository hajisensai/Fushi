import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// BUG-2064：系统分享必须**只有一个入口** `FushiShare`。
///
/// share_plus 的 iOS 端（`FPPSharePlusPlugin.m`）把 text / uri / files 三条路径
/// 汇进同一个 `+share:`，并要求 popover 锚点 rect 非空且完全落在 root view 内；
/// 缺 `sharePositionOrigin` 时 rect 是 `CGRectZero`，必抛
/// `PlatformException(error, sharePositionOrigin: argument must be set, ...)`。
/// 锚点只在 `FushiShare` 内统一解析，任何绕过入口直接调 `Share.xxx` 的新代码都会
/// 把这个崩溃带回来（历史上正是这样漏掉了截图分享），故在源码层挡住。
///
/// 同时挡 `SharePlus` 前缀（share_plus 10+ 的新 API 名），避免升级依赖时静默开一道
/// 口子。**判据末尾没有 `\b` 是有意的**：`package:share_plus/share_plus.dart` 直接
/// `export 'src/share_plus_linux.dart'` /
/// `export 'src/share_plus_windows.dart'`，
/// 于是 `SharePlusLinuxPlugin` / `SharePlusWindowsPlugin`（都是 `SharePlatform`
/// 子类、都带 `.share()`）普通 import 就能写。带 `\b` 的判据在
/// `SharePlusLinuxPlugin(...).share(text)` 上不成立（`SharePlus` 后面跟的 `L` 是
/// 词字符），整条守卫会被这一个字符静默绕过。开头的 `\b` 仍在，`FushiShare` 不会误伤。
void main() {
  test('lib/ 下只有 fushi_share.dart 能直接调 share_plus 的分享 API', () {
    final Directory libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue,
        reason: '必须在 fushi/ 下运行（cwd=${Directory.current.path}）');

    const String entryPointPath = 'lib/src/utils/misc/fushi_share.dart';
    final RegExp forbidden = RegExp(r'\b(Share\.share|SharePlus)');

    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String normalized = entity.path.replaceAll(r'\', '/');
      final String relative = 'lib/${normalized.split('lib/').last}';
      if (relative == entryPointPath) continue;
      scanned++;

      final String source = entity.readAsStringSync();
      // 注释里对 `Share.share` 的引用不算违规，但**只能用等长词法掩码剥**：
      // 手写的 `line.indexOf('//')` 截断会把字符串字面量里的 `https://` 当成注释
      // 起点，把同一行后面真正的 `Share.share(` 一起吞掉（假绿），反过来又对块
      // 注释 `/* Share.share(x) */` 完全放行（假红/假绿两头都错）。
      // maskComments 等长、不改下标，掩码串第 i 行 == 原文第 i 行。
      final List<String> raw = source.split('\n');
      final List<String> masked = maskComments(source).split('\n');
      for (int i = 0; i < masked.length; i++) {
        if (forbidden.hasMatch(masked[i])) {
          offenders.add('$relative:${i + 1}: ${raw[i].trim()}');
        }
      }
    }

    // 扫描本身失效（cwd 不是 fushi/ / listSync 拿不到东西 / 过滤写反）必须红，
    // 不能静默退化成「零违规」的摆设。
    expectScanScale(scanned,
        what: 'lib/ 下除分享入口外的 .dart', atLeast: 960, measured: 1201);

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
