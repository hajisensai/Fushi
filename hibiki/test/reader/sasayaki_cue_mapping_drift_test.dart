import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

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

    // BUG-282（TODO-366，BUG-060 跟进）：不可命中 cue 的回落**不得污染单调游标**。
    // 旧实现回落后 `cursor = resolved + length`，会把游标推到 hint 猜测处；若该
    // 猜测越过后面**真正能命中**的 cue 的真实位置，后续 cue 的搜索窗口下界
    // (max(cursor, hint-window)) 就把真实位置排除掉 → 整本逐句漂移。
    // full 索引: あ0 い1 う2 え3 お4 か5 き6 く7 け8 こ9 さ10 し11 す12 せ13 そ14
    test('回落不污染游标：不可命中 cue(hint 越界)后，可命中 cue 仍锚定真实位置', () {
      const String full = 'あいうえおかきくけこさしすせそ';
      final out = _resolve(full, const <SasayakiCueHint>[
        // cue1 在 DOM 搜不到（转写差异 / gaiji 被剥 / 模糊匹配）。matcher 给的
        // hint=8、length=2 把旧游标推到 10，越过 cue2 真实位置 5。
        SasayakiCueHint(needle: 'みつからん', hint: 8, length: 2),
        // cue2「かきくけこ」DOM 真实位置 5，能精确命中，不该被前句回落污染推到 10。
        SasayakiCueHint(needle: 'かきくけこ', hint: 5, length: 5),
      ]);
      expect(out[1], 5, reason: '可命中 cue 必须自愈到 5，不被前一条回落 cue 的游标污染');
    });

    test('回落不污染游标：连续两条不可命中后，真实可命中句仍命中', () {
      const String full = 'あいうえおかきくけこさしすせそたちつてと';
      final out = _resolve(full, const <SasayakiCueHint>[
        // 两条都搜不到且 hint 越界靠后；旧实现累积把游标推到很靠后。
        SasayakiCueHint(needle: 'なし1', hint: 12, length: 3),
        SasayakiCueHint(needle: 'なし2', hint: 14, length: 3),
        // 真实「かきくけこ」在 5，必须能命中。
        SasayakiCueHint(needle: 'かきくけこ', hint: 5, length: 5),
      ]);
      expect(out[2], 5, reason: '多条回落不得累积推进游标越过真实可命中句');
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
      // TODO-630/BUG-366：needle 现经 foldNormalize（剥+值折叠），仍来自 cue 原文。
      expect(src.contains('this.foldNormalize(cue.text'), isTrue,
          reason: 'needle 必须来自 cue 原文（经 foldNormalize），靠 DOM 文本自校正');
      expect(src.contains('full.indexOf(needle'), isTrue,
          reason: '在 DOM 归一化全文里搜索 cue 原文');
      // 提示仅作 hint（就近 + 有界窗口），不再是权威坐标。
      expect(src.contains('cue.start'), isTrue, reason: 'start 降级为提示位置');
      expect(RegExp(r'WINDOW').hasMatch(src), isTrue, reason: '搜索半径有界，防跳远处重复句');
      // 回落仍走 rangesForNormSpan（绝不空高亮整章）。
      expect(src.contains('rangesForNormSpan('), isTrue,
          reason: '命中/回落都经统一的 span→DOM range 映射');
    });

    // BUG-282 源码守卫：JS collectSasayakiCueRanges 的回落分支**不得**再推进
    // 单调游标 cursor（否则不可命中 cue 的猜测会越过后面可命中 cue 的真实位置，
    // 重新引入逐句累积漂移）。游标只允许在 DOM 真命中分支（best>=0）前进。
    test('JS 回落分支不推进单调游标 cursor（BUG-282）', () {
      final String src = File(
        'lib/src/reader/reader_pagination_scripts.dart',
      ).readAsStringSync();

      // 锁定 collectSasayakiCueRanges 函数体。
      final int fnStart = src.indexOf('collectSasayakiCueRanges: function');
      expect(fnStart, greaterThanOrEqualTo(0));
      final int fnEnd = src.indexOf('applySasayakiCues: function', fnStart);
      expect(fnEnd, greaterThan(fnStart));
      final String fnBody = src.substring(fnStart, fnEnd);

      // 命中分支必须推进游标（best>=0 时 cursor = best + normLen）。
      expect(
        RegExp(r'best\s*>=\s*0.*cursor\s*=\s*best\s*\+\s*normLen', dotAll: true)
            .hasMatch(fnBody),
        isTrue,
        reason: '命中分支仍应推进游标',
      );
      // 回落分支（resolved < 0 / else 块）绝不能把 cursor 设成 spanStart+len。
      expect(
        fnBody.contains('cursor = spanStart + len'),
        isFalse,
        reason: '回落不得推进游标，否则越过后续可命中句重新引入累积漂移（BUG-282）',
      );
    });
  });

  // ── TODO-630 / BUG-366：JS sasayaki 归一化「值折叠」与 Dart 匹配坐标系对齐 ──
  //
  // 真回归（hypothesis C）：commit cf990a444 / b524c8102 给 Dart AudioTextNormalizer
  // 加了值折叠（片假名→平假名 / 大小写 / 全角→ASCII / 半角片假名→全角片假名），但运行
  // 期 JS normalizeText 只剥不折。BUG-060 之后 JS 在运行期对 cue.text 做
  // `full.indexOf(needle)` 实时文本比较 —— 折叠类书（SRT 片假名 vs EPUB 平假名、全角
  // vs 半角）的 needle（未折叠）在 full（未折叠）里 indexOf 落空 → 回落 hint → 高亮看似
  // 「不显示/错位」。修复让 JS foldNormalize 与 Dart 值口径一致。
  group('foldNormalize parity with AudioTextNormalizer (TODO-630/BUG-366)', () {
    void expectParity(String input) {
      expect(
        ReaderPaginationScripts.foldNormalizeForTesting(input),
        AudioTextNormalizer.normalize(input),
        reason: 'JS 折叠口径必须与 Dart 匹配坐标系一致：「$input」',
      );
    }

    test('片假名折叠成平假名（与平假名书同形）', () {
      expect(
        ReaderPaginationScripts.foldNormalizeForTesting('カタカナ'),
        'かたかな',
      );
      expectParity('カタカナ');
    });

    test('全角字母数字折叠成 ASCII', () {
      expect(ReaderPaginationScripts.foldNormalizeForTesting('Ａ１ｂ'), 'a1b');
      expectParity('Ａ１ｂ');
    });

    test('半角片假名折叠成平假名', () {
      expect(ReaderPaginationScripts.foldNormalizeForTesting('ｶﾀｶﾅ'), 'かたかな');
      expectParity('ｶﾀｶﾅ');
    });

    test('剥标点/空白/emoji 与折叠混合', () {
      expectParity('第１話「カタカナ」です！🐱');
      expectParity('Helloｗorld　世界');
      expectParity('コーヒーを飲む');
    });

    test('星平面汉字（代理对）不折叠、保留', () {
      // CJK 扩展 B 𠀋（U+2000B），白名单保留且不折叠。
      const String ext = '\u{2000B}漢';
      expect(ReaderPaginationScripts.foldNormalizeForTesting(ext), ext);
      expectParity(ext);
    });
  });

  // 折叠类书的运行期重定位：needle（folded）必须在 full（folded）里命中（而非回落 hint）。
  // 复现真 bug：DOM 全文是平假名「かたかな」，SRT cue.text 是片假名「カタカナ」。
  // 修复前 JS needle 只剥不折 = 「カタカナ」，在平假名 full 里 indexOf 落空 → 回落 hint。
  // 修复后 needle 折叠成「かたかな」→ 命中真实位置。
  group(
      'folding-class cue relocation hits via folded needle (TODO-630/BUG-366)',
      () {
    test('片假名 cue 在平假名 DOM 全文里命中（折叠后 indexOf 不落空）', () {
      // full 由 DOM 折叠产生（平假名）：あ0 い1 う2 え3 お4 か5 た6 か7 な8 ...
      const String full = 'あいうえおかたかなさしすせそ';
      // cue 原文是片假名「カタカナ」，先折叠成 needle「かたかな」（运行期 foldNormalize）。
      final String needle =
          ReaderPaginationScripts.foldNormalizeForTesting('カタカナ');
      final out = _resolve(full, <SasayakiCueHint>[
        // hint 故意给 0（不准），靠 DOM 文本就近重定位到真实位置 5。
        SasayakiCueHint(needle: needle, hint: 0, length: 4),
      ]);
      expect(out.single, 5, reason: '折叠后 needle 必须命中真实位置 5，而非回落 hint=0');
    });

    test('未折叠的片假名 needle 在平假名全文里落空（证伪：这正是修复前症状）', () {
      const String full = 'あいうえおかたかなさしすせそ';
      // 不经折叠（模拟旧 JS：normalizeText 只剥），片假名 needle 在平假名全文里搜不到。
      final out = _resolve(full, const <SasayakiCueHint>[
        SasayakiCueHint(needle: 'カタカナ', hint: 0, length: 4),
      ]);
      expect(out.single, 0, reason: '未折叠时 indexOf 落空 → 回落 hint=0（这是被修复的错误行为）');
    });
  });

  // 源码守卫：JS 运行期归一化必须做值折叠并用于 needle + full（防回归删回「只剥不折」）。
  group('JS sasayaki value-folding wiring guard (TODO-630/BUG-366)', () {
    final String src = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();

    test('JS 定义 foldCodePoint / foldNormalize 值折叠函数', () {
      expect(src.contains('foldCodePoint: function'), isTrue,
          reason: '需 JS 值折叠码点函数（片假名→平假名/大小写/全角→ASCII）');
      expect(src.contains('foldNormalize: function'), isTrue,
          reason: '需 JS 剥+折叠组合函数供 needle 用');
    });

    test('needle 经 foldNormalize（而非只剥的 normalizeText）', () {
      expect(src.contains('this.foldNormalize(cue.text'), isTrue,
          reason: 'needle 必须折叠，否则折叠类书 indexOf 落空');
    });

    test('full 索引也折叠（与 needle 同坐标系）', () {
      expect(src.contains('this.foldCodePoint(text.codePointAt(i))'), isTrue,
          reason: 'buildSasayakiNormIndex 的 full 也须折叠，否则 needle/full 坐标系分叉');
    });
  });

  // 源码守卫：观测日志（解定位僵局）必须存在于关键节点（防回归删）。
  group('JS sasayaki highlight observability guard (TODO-630)', () {
    final String src = File(
      'lib/src/reader/reader_pagination_scripts.dart',
    ).readAsStringSync();

    test('applySasayakiCues 打 payload cue 数 + 一次性诊断（cssHighlights/背景色）', () {
      expect(
          src.contains('[sasayaki-hl] applySasayakiCues payloadCues='), isTrue);
      expect(
          src.contains('[sasayaki-hl] diag cssHighlightsSupported='), isTrue);
      expect(src.contains('--hoshi-sasayaki-background-color'), isTrue,
          reason: '一次性诊断须读 sasayaki 背景色变量（透明/缺失也是「看不见」原因）');
    });

    test('collectSasayakiCueRanges 打 cue 数 + 空 range 计数', () {
      expect(src.contains('[sasayaki-hl] collectRanges cues='), isTrue);
      expect(src.contains('emptyRanges'), isTrue);
    });

    test('highlightSasayakiCue 打 range/ruby 数（或为何 return null）', () {
      expect(src.contains('[sasayaki-hl] highlightCue ranges='), isTrue);
      expect(src.contains('RETURN_NULL_no_segments'), isTrue);
    });
  });
}
