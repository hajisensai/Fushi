import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

/// BUG-060：高亮坐标改由实时 DOM 权威定位。验证搜索逻辑三不变量：
/// ① 上游 N 字漂移自愈（用 cue 原文在 DOM 就近重定位，不用死的偏移）；
/// ② 漂移不传播（每条 cue 独立锚定）；
/// ③ 窗口受限 + 单调 ⇒ 不跳到远处重复句；④ 未命中回落提示偏移。
List<int> _resolve(String fullNorm, List<SasayakiCueHint> cues,
        {int window = 256}) =>
    ReaderPaginationScripts.resolveCueNormStartsForTesting(
      fullNorm: fullNorm,
      cues: cues,
      window: window,
    );

void main() {
  group('resolveCueNormStarts (BUG-060)', () {
    test('无漂移：解析起点等于命中位置', () {
      const String full = 'あいうえおかきくけこさしすせそ';
      final out = _resolve(full, const <SasayakiCueHint>[
        SasayakiCueHint(needle: 'かきくけこ', hint: 5, length: 5),
      ]);
      expect(out, <int>[5]);
    });

    test('上游 +2 字漂移：按原文重定位到真实位置(7)，而非死提示(5)', () {
      // DOM 比匹配坐标在前部多了 2 个字（ＸＹ），提示仍说 5。
      const String full = 'ＸＹあいうえおかきくけこさしすせそ';
      final out = _resolve(full, const <SasayakiCueHint>[
        SasayakiCueHint(needle: 'かきくけこ', hint: 5, length: 5),
      ]);
      expect(out, <int>[7]);
    });

    test('漂移不传播：前句漂移不影响后句各自命中', () {
      // 前部多 2 字；两句提示都偏 2，但各自按原文重定位到真实位置。
      const String full = 'ＸＹあいうえおかきくけこさしすせそたちつてと';
      final out = _resolve(full, const <SasayakiCueHint>[
        SasayakiCueHint(needle: 'かきくけこ', hint: 5, length: 5), // 真实 7
        SasayakiCueHint(needle: 'たちつてと', hint: 15, length: 5), // 真实 17
      ]);
      expect(out, <int>[7, 17]);
    });

    test('窗口受限 + 就近：远处重复句不抢，取离提示最近的那个', () {
      // 同一句在 5 和 500 各出现一次；提示 5、窗口 256 → 取 5，不跳 500。
      final String full = 'かきくけこ${'を' * 495}かきくけこ'; // 第二处在 500
      final out = _resolve(full, const <SasayakiCueHint>[
        SasayakiCueHint(needle: 'かきくけこ', hint: 5, length: 5),
      ]);
      expect(out.single, 0); // 第一处在 index 0（最近 hint=5）
    });

    test('单调：不回退到游标之前的更早出现', () {
      // needle 在 0 和 20 各出现；第一句吃掉 0，第二句 hint 指向 20，
      // 即便 0 也匹配，也不能回退。
      const String full = 'かきくけこ#####かきくけこ#####';
      final out = _resolve(full, const <SasayakiCueHint>[
        SasayakiCueHint(needle: 'かきくけこ', hint: 0, length: 5), // → 0
        SasayakiCueHint(needle: 'かきくけこ', hint: 10, length: 5), // → 10（不回退到 0）
      ]);
      expect(out, <int>[0, 10]);
    });

    test('未命中：回落到裁剪后的提示偏移', () {
      const String full = 'あいうえおかきくけこ';
      final out = _resolve(full, const <SasayakiCueHint>[
        SasayakiCueHint(needle: 'まったく無い句', hint: 3, length: 6),
      ]);
      expect(out.single, 3); // 回落提示
    });

    test('未命中且提示越界：裁剪到文本末尾', () {
      const String full = 'あいうえお';
      final out = _resolve(full, const <SasayakiCueHint>[
        SasayakiCueHint(needle: 'xyz不存在', hint: 999, length: 4),
      ]);
      expect(out.single, full.length);
    });
  });

  // 源码守卫：JS collectSasayakiCueRanges 必须与上面被测的 Dart 影子同算法
  // （文本就近 + 单调 + 窗口 + 回落），任一支柱被回归删掉就回到「死偏移累积漂移」。
  group('JS sasayaki anchoring wiring guard (BUG-060)', () {
    test('JS 用 cue 原文在实时 DOM 就近重定位（非死偏移逐字计数）', () {
      final String src = File(
        'lib/src/reader/reader_pagination_scripts.dart',
      ).readAsStringSync();

      // 运行时按 DOM 文本建归一化反查表。
      expect(src.contains('buildSasayakiNormIndex:'), isTrue,
          reason: '需一次性构建实时 DOM 的归一化全文 + 反查表');
      // 反查表必须按 UTF-16 码元粒度（代理对 push 两条），与 full.indexOf 的
      // 码元偏移对齐，否则 CJK 扩展 B+ 汉字后高亮错位（W-1）。
      expect(src.contains('for (var u = 0; u < ch.length'), isTrue,
          reason: 'map 必须按码元粒度建，与 full(码元串) 同空间');
      // 用 cue 原文 needle 在全文里搜索（而非按 start 死偏移数 cursor）。
      expect(src.contains('this.normalizeText(cue.text'), isTrue,
          reason: 'needle 必须来自 cue 原文，靠 DOM 文本自校正');
      expect(src.contains('full.indexOf(needle'), isTrue,
          reason: '在 DOM 归一化全文里搜索 cue 原文');
      // 提示仅作 hint（就近 + 有界窗口），不再是权威坐标。
      expect(src.contains('cue.start'), isTrue, reason: 'start 降级为提示位置');
      expect(RegExp(r'WINDOW').hasMatch(src), isTrue, reason: '搜索半径有界，防跳远处重复句');
      // 回落仍走 rangesForNormSpan（绝不空高亮整章）。
      expect(src.contains('rangesForNormSpan('), isTrue,
          reason: '命中/回落都经统一的 span→DOM range 映射');
    });
  });
}
