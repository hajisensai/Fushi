import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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

    final Set<int> available = _cmapCodePoints(font.readAsBytesSync());
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

/// 解析 TTF 的 cmap format 4 子表，返回其中出现的全部码位。
///
/// 只支持 format 4（BMP）——Material Symbols 的私用区码位全在 BMP，够用；读不到
/// format 4 时返回空集，由调用方断言成失败而不是静默放过。
Set<int> _cmapCodePoints(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  final int numTables = data.getUint16(4);

  int? cmapOffset;
  for (int i = 0; i < numTables; i++) {
    final int rec = 12 + 16 * i;
    final String tag = String.fromCharCodes(bytes.sublist(rec, rec + 4));
    if (tag == 'cmap') {
      cmapOffset = data.getUint32(rec + 8);
      break;
    }
  }
  if (cmapOffset == null) return <int>{};

  final int numSubtables = data.getUint16(cmapOffset + 2);
  int? format4Offset;
  for (int i = 0; i < numSubtables; i++) {
    final int rec = cmapOffset + 4 + 8 * i;
    final int subtableOffset = cmapOffset + data.getUint32(rec + 4);
    if (data.getUint16(subtableOffset) == 4) {
      format4Offset = subtableOffset;
      break;
    }
  }
  if (format4Offset == null) return <int>{};

  final int segCountX2 = data.getUint16(format4Offset + 6);
  final int segCount = segCountX2 ~/ 2;
  final int endBase = format4Offset + 14;
  final int startBase = endBase + segCountX2 + 2;

  final Set<int> result = <int>{};
  for (int seg = 0; seg < segCount; seg++) {
    final int end = data.getUint16(endBase + 2 * seg);
    final int start = data.getUint16(startBase + 2 * seg);
    if (start == 0xFFFF) continue;
    for (int cp = start; cp <= end && cp != 0xFFFF; cp++) {
      result.add(cp);
    }
  }
  return result;
}
