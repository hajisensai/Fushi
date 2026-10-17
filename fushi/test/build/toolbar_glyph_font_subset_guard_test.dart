import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/ttf_cmap.dart';

/// 工具条按钮字形必须真的在打包的字体子集里。
///
/// `assets/fonts/MaterialSymbolsRounded.ttf` 是个 **4KB 的极小子集**（只含当时用
/// 到的十来个码位），不是完整的 Material Symbols。给新按钮随手配一个官方码位
/// （比如 skip_previous U+E045）在源码里看起来完全正常，DirectWrite 却画不出字形
/// —— 用户看到的是一颗豆腐块 / 空按钮。
///
/// 这个坑只在真机上看得见：native 窗口跑不进 widget test，源码扫描也只能看到
/// 「有个 \uXXXX 字面量」。所以这条守卫直接解析 TTF 的 cmap，把 `SlotGlyph` 里
/// 出现的每个码位拿去比对真实字体内容。
///
/// 配套约定（见 hook_toolbar_window.cpp 的 SlotGlyph）：给不出字形的 action 必须
/// **显式**返回空串，由调用方逐槽回退到 DrawSlotIcon 的矢量画法。
void main() {
  test('SlotGlyph 用到的码位都在打包的字体子集里（否则画出豆腐块）', () {
    final File font = File(
      p.join('assets', 'fonts', 'MaterialSymbolsRounded.ttf'),
    );
    expect(font.existsSync(), isTrue, reason: '找不到打包字体');

    final Set<int> available = ttfCmapCodePoints(font.readAsBytesSync());
    expect(available, isNotEmpty, reason: 'cmap 解析失败：一个码位都没读出来');

    final String source = File(
      p.join('windows', 'runner', 'hook_toolbar_window.cpp'),
    ).readAsStringSync();
    final int start = source.indexOf('const wchar_t* SlotGlyph');
    expect(start, greaterThan(0), reason: '找不到 SlotGlyph 定义');
    final int end = source.indexOf('\n}', start);
    expect(end, greaterThan(start));
    final String body = source.substring(start, end);

    final Set<int> used = RegExp(r'L"\\u([0-9A-Fa-f]{4})"')
        .allMatches(body)
        .map((RegExpMatch m) => int.parse(m.group(1)!, radix: 16))
        .toSet();
    expect(used, isNotEmpty, reason: 'SlotGlyph 里一个字形码位都没有？');

    final List<String> missing =
        used
            .where((int cp) => !available.contains(cp))
            .map((int cp) => 'U+${cp.toRadixString(16).toUpperCase()}')
            .toList()
          ..sort();

    expect(
      missing,
      isEmpty,
      reason:
          '这些码位不在 assets/fonts/MaterialSymbolsRounded.ttf 的子集里：'
          '$missing。要么把字形补进子集字体，要么让该 action 返回空串并在 '
          'DrawSlotIcon 里给出矢量画法（previousCue / nextCue 就是后者）。',
    );
  });
}
