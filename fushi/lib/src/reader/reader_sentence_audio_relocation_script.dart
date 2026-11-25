/// 有声书 cue「按原文就近重定位」——三种 view mode 共用的**唯一** JS 源。
///
/// cue 下发的 `{start, length}` 是 Dart 匹配器在 package:html 坐标系里算出的归一化
/// 偏移，与浏览器实时 DOM 逐字不一定一致（BUG-060）。所以 start 只当「提示」，运行时用
/// cue 原文在章节的归一化全文里就近、单调地重新定位，得到真正的 `{start, len}`。
///
/// 以前这段算法只写在分页 / 连续 shell 的 `collectSentenceAudioCueRanges` 里，VN 直接拿
/// start / length 当权威坐标：提示偏 3 个字，VN 每句高亮、切屏、中键反查全错，另两种
/// 模式仍对（测量组 m1，PR #3830 gap-readerjs2-8；拍板台
/// `design-nmv-reader-vn-cue-projects`）。现在三种模式都经这里解析，各自只负责
/// 「归一化全文怎么建」（分页 / 连续：当前 DOM；VN：游离源章节的内容流）。
///
/// 算法与 Dart 影子 `ReaderPaginationScripts.resolveCueNormSpansForTesting` 逐条一致
/// （常量同值，见源码守卫 `sentence_audio_cue_mapping_drift_test.dart`，行为对拍见
/// `sentence_audio_relocation_behavior_test.dart`）。值折叠与 Dart `AudioTextNormalizer`
/// 同口径（TODO-630 / BUG-366），全部 1:1 BMP 码元。
library;

/// 定义 `window.fushiSentenceAudioRelocation`（幂等），由 `engineShell` 在任何 shell
/// 安装之前注入。
const String kSentenceAudioRelocationJs = r"""
if (!window.fushiSentenceAudioRelocation) {
  window.fushiSentenceAudioRelocation = (function() {
    // 搜索半径 / 回吃尾巴 / 延续容差，与 Dart ReaderPaginationScripts 的
    // kSentenceAudioSearchWindow / kSentenceAudioTailOverlap / kSentenceAudioAdjacent 同值。
    var WINDOW = 256;
    var OVERLAP = 4;
    var ADJACENT = 2;
    var HW_KATA_BASE = 0xFF66;
    var HW_KATA_TO_FW = [0x30F2,0x30A1,0x30A3,0x30A5,0x30A7,0x30A9,0x30E3,0x30E5,0x30E7,0x30C3,0x30FC,0x30A2,0x30A4,0x30A6,0x30A8,0x30AA,0x30AB,0x30AD,0x30AF,0x30B1,0x30B3,0x30B5,0x30B7,0x30B9,0x30BB,0x30BD,0x30BF,0x30C1,0x30C4,0x30C6,0x30C8,0x30CA,0x30CB,0x30CC,0x30CD,0x30CE,0x30CF,0x30D2,0x30D5,0x30D8,0x30DB,0x30DE,0x30DF,0x30E0,0x30E1,0x30E2,0x30E4,0x30E6,0x30E8,0x30E9,0x30EA,0x30EB,0x30EC,0x30ED,0x30EF,0x30F3];

    function foldCodePoint(cp) {
      var out = cp;
      if (cp >= 0x41 && cp <= 0x5A) out = cp + 0x20;            // ASCII A-Z -> a-z
      else if (cp >= 0xFF21 && cp <= 0xFF3A) out = cp - 0xFEC0; // fullwidth A-Z -> a-z
      else if (cp >= 0xFF41 && cp <= 0xFF5A) out = cp - 0xFEE0; // fullwidth a-z -> a-z
      else if (cp >= 0xFF10 && cp <= 0xFF19) out = cp - 0xFEE0; // fullwidth 0-9 -> 0-9
      else if (cp >= 0xFF66 && cp <= 0xFF9D) out = HW_KATA_TO_FW[cp - HW_KATA_BASE]; // halfwidth kana -> fullwidth kana
      if (out >= 0x30A1 && out <= 0x30F6) out -= 0x60;          // katakana -> hiragana
      return out;
    }

    // 已剥成可匹配字的串逐码点折叠（码元数不变）。
    function foldText(stripped) {
      var folded = '';
      var i = 0;
      while (i < stripped.length) {
        var cp = stripped.codePointAt(i);
        folded += String.fromCodePoint(foldCodePoint(cp));
        i += cp > 0xFFFF ? 2 : 1;
      }
      return folded;
    }

    // full：章节归一化（已折叠）全文，UTF-16 码元串。cues：按章内顺序的
    // [{id, needle(已 foldNormalize 的 cue 原文), hint(提示起点，非数字 = 当前游标),
    //   length(提示长度)}]。返回同序 [{id, start, len, resolved}]。
    //
    // 不变量：① 游标 cursor 单调不回退（BUG-2204 起允许回吃前一条命中的尾巴 OVERLAP 字，
    // 但不越过其起点）；② 搜索窗口有界（整句 needle + 半径 WINDOW），不跳远处重复句；
    // ③ 紧接前一条命中处（cursor-OVERLAP..cursor+ADJACENT）的「延续」优先，否则窗口内取
    // 离 hint 最近者；④ 未命中回落提示偏移、不推进游标（BUG-282），绝不空高亮；
    // ⑤ 起点早于游标的命中必须越过游标——整条装在前一句里的只是重复片段，认它会把前一句
    // 裁成几个字、本句高亮落在前一句中间。

    //
    // BUG-2204：ASR 字幕前句多带下一句首字（「…高い所。と」+「とはいえ、」）时，前句命中
    // 后游标已越过后句真实起点；只按 hint 就近会撞上远处同前缀句。延续优先 + 回吃尾巴让
    // 后句仍在真实位置命中，并把前句的 span 裁到后句起点。
    function resolveSpans(full, cues) {
      var spans = [];
      var cursor = 0;
      var lastHit = -1;
      var lastHitStart = -1;
      for (var ci = 0; ci < cues.length; ci++) {
        var cue = cues[ci];
        var needle = cue.needle || '';
        var hint = (typeof cue.hint === 'number' && isFinite(cue.hint)) ? cue.hint : cursor;
        var len = (typeof cue.length === 'number' && isFinite(cue.length)) ? cue.length : 0;
        var normLen = needle.length;
        var resolved = -1;
        if (normLen > 0) {
          var floor = lastHit >= 0 ? Math.max(lastHitStart + 1, cursor - OVERLAP) : cursor;
          var lo = floor > (hint - WINDOW) ? floor : (hint - WINDOW);
          var startAt = lo < 0 ? 0 : lo;
          var hi = Math.max(hint + WINDOW, cursor + ADJACENT);
          var best = -1, bestDist = 1 << 30;
          var adjacent = -1, adjacentDist = 1 << 30;
          if (startAt <= full.length) {
            var from = startAt;
            while (true) {
              var p = full.indexOf(needle, from);
              if (p < 0 || p > hi) break;
              // 整条落在前一条命中区间之内（p + normLen <= cursor）的不是下一句，只是前句里
              // 的重复片段（「𠀀猫がいる」后接「猫がいる」）：回吃尾巴要求新句越过游标。
              if (p < cursor && p + normLen <= cursor) { from = p + 1; continue; }
              if (lastHit >= 0 && p >= cursor - OVERLAP && p <= cursor + ADJACENT) {
                var da = Math.abs(p - cursor);
                if (da < adjacentDist) { adjacentDist = da; adjacent = p; }
              }
              if (p <= hint + WINDOW) {
                var d = Math.abs(p - hint);
                if (d < bestDist) { bestDist = d; best = p; }
              }
              from = p + 1;
            }
          }
          if (adjacent >= 0) best = adjacent;
          if (best >= 0) {
            resolved = best;
            // 回吃了前一条的尾巴：把它的 span 裁到本条起点，区间不重叠。
            if (best < cursor && lastHit >= 0) spans[lastHit].len = best - spans[lastHit].start;
            cursor = best + normLen;
            lastHit = spans.length;
            lastHitStart = best;
          }
        }
        if (resolved >= 0) {
          spans.push({ id: cue.id, start: resolved, len: normLen, resolved: true });
        } else {
          // BUG-282：未命中只给尽力而为的回落区间，不推进单调游标——让回落按未核实的
          // hint 推进游标会越过后面真正能命中的位置，整本逐句累积漂移。
          var fallback = hint < cursor ? cursor : (hint > full.length ? full.length : hint);
          spans.push({ id: cue.id, start: fallback, len: len, resolved: false });
        }
      }
      return spans;
    }

    return {
      WINDOW: WINDOW,
      OVERLAP: OVERLAP,
      ADJACENT: ADJACENT,
      foldCodePoint: foldCodePoint,
      foldText: foldText,
      resolveSpans: resolveSpans
    };
  })();
}
""";
