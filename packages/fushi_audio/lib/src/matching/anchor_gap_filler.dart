import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../audiobook/audiobook_model.dart';
import 'audio_text_normalizer.dart';
import 'epub_srt_matcher.dart';

/// 锚点间隙回填：把 Dice 匹配器漏掉的、夹在两条命中 cue 之间的 cue 对齐到
/// 两锚点之间的那段正文。
///
/// 匹配器的第一遍是「cue 文本 vs 正文」的模糊匹配，对听写文本（ASR 产物）天然
/// 有漏：かな⇄漢字、同音字会把 bigram Dice 打到阈值之下。但漏掉的 cue 不是
/// 凭空出现的——它前后各有一条命中 cue，音频是顺序朗读的，所以它的正文**一定**
/// 落在前锚点终点与后锚点起点之间那段归一化文本里。把搜索范围从 200 字窗口缩到
/// 这段（通常几十字），用字符级编辑距离（对单字替换/长度变化远比 bigram 宽容）
/// 顺序对齐，就能把绝大多数听写差补回来。
///
/// 规则：
/// - 只处理**两侧都有锚点**的未命中串；开头（片头/书名等正文里没有的行）与末尾
///   的未命中原样保留——那里没有正文范围可依据。
/// - ① 重切：把未命中串连同两侧锚点（≤ [softAnchorMaxLen] 字的短锚点再向外扩一
///   条——うん/いや 这种两字句常是 Dice 精确命中跳到别处的伪锚点）放进「再前一个
///   已定位 cue 的终点 ~ 再后一个已定位 cue 的起点」区域，**按归一化长度降序**逐条
///   用编辑距离找最佳区间，每条只能落在（cue 顺序上）已落位邻句之间。长句先落位
///   几乎不会错，短句随后只能在邻句夹出的小区间里找，不会再抢走别人的正文。
///   两端锚点必须以 ≥ [anchorMinSimilarity] 落位，否则整体放弃；中间句
///   ≥ [minSimilarity] 才接受。提交条件：净多命中 > 0，或没有丢失且两端锚点仍在
///   原区间并集内（纯边界纠正）。
/// - ② 剩下仍未命中的子串：其总归一化长度与所在间隙长度之比在
///   [[minLengthRatio], [maxLengthRatio]] 内时，按各句长度比例切开认领（单句就是
///   整段认领），不看相似度——朗读者不会在两句已对上的句子之间读别的东西，而
///   纯かな⇄漢字改写（たぶん/多分、せいれい/精霊）编辑距离是零重叠的。
/// - 回填命中的 [CueMatch.score] 就是编辑距离相似度（< 1）。
///
/// ## 锚点不变式（回填只增不改）
///
/// 第一遍命中的 cue 是锚点，按第一遍结果分三类，回填对它们的承诺不同：
///
/// - **硬锚点**：第一遍 `score >= 1.0`（精确子串命中）且归一化长度
///   > [softAnchorMaxLen]。回填后 `sectionIndex` / `normCharStart` /
///   `normCharEnd` / `score` **逐字段不变**，对象也原样保留——重切时它被钉死，
///   邻句让位不会收缩它。
/// - **软锚点**：第一遍模糊命中（`score < 1.0`）且长度 > [softAnchorMaxLen]。
///   允许重切，但新区间必须落在「原区间 ∪ 相邻两个间隙」内——即不越过第一遍里
///   它前一条命中 cue 的终点和后一条命中 cue 的起点——且重切后相似度
///   ≥ [anchorMinSimilarity]；做不到就整串放弃、原样保留。它**绝不会**变成未命中。
/// - **伪锚点**：第一遍命中但长度 ≤ [softAnchorMaxLen]（うん/はい 这种两字句的
///   精确命中几乎必然是撞上的）。它是设计上唯一允许被挪位或丢弃的已命中 cue，
///   丢弃只在整串重切净多命中时发生。
///
/// 三类判定都以**第一遍结果**为准；每串提交前逐条检查，[fill] 末尾再对全部 cue
/// 复核一遍，任何违反都退回第一遍结果（`gapFill.invariantViolated = true`）。
///
/// ## 复杂度与门控
///
/// 每条 cue 在 region 里找最佳区间走 Sellers 半全局近似匹配，O(region × cue 长)；
/// 一串的代价 ≈ region × 串内 cue 数 × 平均 cue 长。region 只由前后已命中 cue
/// 夹定、本身没有上限（第一遍的恢复机制一次能跳过几千到几万字），所以：
/// - 单串 region 超过 [maxRegionChars] 整串跳过；
/// - 整次 [fill] 的工作量（Σ region × 串内 cue 数）超过 [maxTotalWork] 后剩余
///   串全部跳过。
/// 跳过的串原样保留第一遍结果，计入 [MatchResult.gapFill] 并打日志，不静默。
class AnchorGapFiller {
  const AnchorGapFiller({
    this.minSimilarity = 0.45,
    this.maxLengthRatio = 2.5,
    this.minLengthRatio = 0.3,
    this.anchorMinSimilarity = 0.5,
    this.softAnchorMaxLen = 2,
    this.maxRegionChars = defaultMaxRegionChars,
    this.maxTotalWork = defaultMaxTotalWork,
  });

  /// [maxRegionChars] 默认值。回填的设计对象是「相邻两条命中 cue 之间被漏掉的
  /// 几条到二十来条 cue」：第一遍连续 miss 到
  /// [EpubSrtMatcher.defaultMaxConsecutiveMisses]（20）条就会用 `indexOf` 重锚，
  /// 有声书一条 cue 归一化后通常 15~40 字，20 条 ≈ 800 字，加上两端锚点与软锚点
  /// 外扩、region 两头再各带一个间隙，正常情况不到 1500 字。4000 给了 2.5 倍余量；
  /// 比这更长的 region 意味着两个锚点之间夹着整段没被朗读的正文（恢复机制跳过
  /// 的段落），漏掉的 cue 根本读不满它，回填在那里没有合法的事可做。
  static const int defaultMaxRegionChars = 4000;

  /// [maxTotalWork] 默认值：Σ region 字符数 × 串内 cue 数 = Sellers DP 的总列数，
  /// 每列 O(cue 长) 次单元更新。1000 万列 × 平均 40 字 ≈ 4×10⁸ 次单元更新，Dart
  /// AOT 约 1~2 秒，是这次回填的硬上限；一本 8000 条 cue、三成漏掉的书实际只用
  /// 几十万到几百万列。
  static const int defaultMaxTotalWork = 10000000;

  /// 编辑距离相似度门槛（`1 - lev / max(len)`）。0.45 允许一半左右的字被替换或
  /// 增删——比 Dice 的 0.6 宽得多，因为搜索范围已被锚点钉死。
  final double minSimilarity;

  /// 软锚点重切后必须达到的相似度（原本就是命中的，放宽只会让它挪去吞别的
  /// 东西）；也是两端锚点落位的门槛。
  final double anchorMinSimilarity;

  /// 间隙长度 / cue 归一化长度 的上限（比这更长说明正文里有被跳读的句子）。
  final double maxLengthRatio;

  /// 间隙长度 / cue 归一化长度 的下限。かな 听写对漢字正文（あーすふぉーとれす
  /// / 土砦）常到 3 倍，比这更短说明 cue 是正文里没有的旁白。
  final double minLengthRatio;

  /// 不超过这个归一化长度的锚点视为「伪锚点」：重切时向外多扩一条，让它作为
  /// 中间句参与重排（可被挪位或丢弃）。
  final int softAnchorMaxLen;

  /// 单串 region（归一化字符数）上限，超过整串跳过。见 [defaultMaxRegionChars]。
  final int maxRegionChars;

  /// 整次 [fill] 的工作量预算（Σ region 字符数 × 串内 cue 数），超过后剩余串
  /// 跳过。见 [defaultMaxTotalWork]。
  final int maxTotalWork;

  /// 返回回填后的新 [MatchResult]（不修改入参）。[result] 必须是对同一
  /// [sections] / [cues] 跑出来的。
  ///
  /// 承诺（见类注释「锚点不变式」）：硬锚点逐字段不变；软锚点只在原区间 ∪ 相邻
  /// 间隙内重切且相似度 ≥ [anchorMinSimilarity]；除伪锚点外任何已命中 cue 不会
  /// 变成未命中。末尾复核失败退回第一遍结果。
  MatchResult fill({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required MatchResult result,
  }) {
    if (cues.isEmpty || result.matches.length != cues.length) return result;
    // 与 EpubSrtMatcher._buildIndex 同一口径：逐节归一化拼接。
    final StringBuffer buf = StringBuffer();
    final List<int> sectionStarts = <int>[];
    for (final EpubSection s in sections) {
      sectionStarts.add(buf.length);
      AudioTextNormalizer.appendNormalized(buf, s.text);
    }
    final String big = buf.toString();
    if (big.isEmpty) return result;

    final _Ctx c = _Ctx(
      big: big,
      sectionStarts: sectionStarts,
      cues: cues,
      norms: <String>[
        for (final AudioCue cue in cues)
          AudioTextNormalizer.normalize(cue.text),
      ],
      first: List<CueMatch>.unmodifiable(result.matches),
      out: List<CueMatch>.of(result.matches),
      softAnchorMaxLen: softAnchorMaxLen,
    );

    int i = 0;
    while (i < cues.length) {
      if (c.out[i].matched) {
        i++;
        continue;
      }
      // 未命中串 [i, j)。
      int j = i;
      while (j < cues.length && !c.out[j].matched) {
        j++;
      }
      if (i == 0 || j >= cues.length) {
        i = j;
        continue;
      }
      // ① 连同两侧锚点按长度降序重切。
      final bool skipped = !_realign(c, i - 1, j);
      if (skipped) {
        // region 超限/预算耗尽：这串连比例认领也不做——那段正文本来就装不下
        // 这些 cue，硬切只会得到一堆错位的「命中」。
        i = j;
        continue;
      }
      // ② 剩下的每个子串以「当前已定位的邻句」为界按长度比例认领。邻句要现找：
      // ① 可能把伪锚点（原 i-1 / j 上的两字句）丢成未命中，不能再当它们是锚。
      int k = i;
      while (k < j) {
        if (c.out[k].matched) {
          k++;
          continue;
        }
        int e = k;
        while (e < j && !c.out[e].matched) {
          e++;
        }
        int leftAnchor = k - 1;
        while (leftAnchor >= 0 && !c.out[leftAnchor].matched) {
          leftAnchor--;
        }
        int rightAnchor = e;
        while (rightAnchor < cues.length && !c.out[rightAnchor].matched) {
          rightAnchor++;
        }
        if (leftAnchor >= 0 && rightAnchor < cues.length) {
          _splitProportionally(c, leftAnchor, rightAnchor);
        }
        k = e;
      }
      i = j;
    }

    final String? violation = _invariantViolation(c);
    if (violation != null) {
      // 不应发生：每串提交前已逐条检查。真到这里宁可放弃整次回填。
      debugPrint(
        '[sentenceAudioHighlight] gapFill REJECTED: $violation; '
        'keeping first-pass result',
      );
      return MatchResult(
        matches: result.matches,
        totalCues: result.totalCues,
        matchedCues: result.matchedCues,
        gapFill: c.stats.snapshot(invariantViolated: true),
      );
    }
    final int matched = c.out.where((CueMatch m) => m.matched).length;
    final GapFillStats stats = c.stats.snapshot(invariantViolated: false);
    if (stats.oversizeRuns > 0 || stats.budgetSkippedRuns > 0) {
      debugPrint(
        '[sentenceAudioHighlight] gapFill skipped runs: '
        'oversize=${stats.oversizeRuns} budget=${stats.budgetSkippedRuns} '
        'of ${stats.runs} (work=${stats.work}/$maxTotalWork)',
      );
    }
    return MatchResult(
      matches: c.out,
      totalCues: result.totalCues,
      matchedCues: matched,
      gapFill: stats,
    );
  }

  /// 逐条复核类注释里的锚点不变式；违反返回描述，否则 null。
  String? _invariantViolation(_Ctx c) {
    for (int k = 0; k < c.out.length; k++) {
      final CueMatch f = c.first[k];
      if (!f.matched || c.isPseudo(k)) continue;
      final CueMatch o = c.out[k];
      if (!o.matched) return 'matched cue #$k became unmatched';
      final bool same = o.sectionIndex == f.sectionIndex &&
          o.normCharStart == f.normCharStart &&
          o.normCharEnd == f.normCharEnd &&
          o.score == f.score;
      if (same) continue;
      if (c.isHard(k)) return 'hard anchor #$k changed';
      if (o.score < anchorMinSimilarity - 1e-9) {
        return 'soft anchor #$k re-cut below anchorMinSimilarity';
      }
      if (!c.withinFirstBounds(k, c.start(k), c.end(k))) {
        return 'soft anchor #$k re-cut outside its first-pass bounds';
      }
    }
    return null;
  }

  /// 重切 [left0..right0]（两端为已命中锚点，中间全部未命中）。
  ///
  /// 返回 false 表示这串因 region 超限或预算耗尽被整串跳过（调用方连比例认领也
  /// 不做）；true 表示已处理（提交或因不变式/相似度放弃）。
  bool _realign(_Ctx c, int left0, int right0) {
    int left = left0;
    while (left > 0 &&
        c.out[left - 1].matched &&
        c.norms[left].length <= softAnchorMaxLen) {
      left--;
    }
    int right = right0;
    while (right + 1 < c.out.length &&
        c.out[right + 1].matched &&
        c.norms[right].length <= softAnchorMaxLen) {
      right++;
    }
    final int unionStart = c.start(left);
    final int unionEnd = c.end(right);
    int regionStart = unionStart;
    for (int p = left - 1; p >= 0; p--) {
      if (c.out[p].matched) {
        regionStart = math.min(unionStart, c.end(p));
        break;
      }
    }
    int regionEnd = unionEnd;
    for (int p = right + 1; p < c.out.length; p++) {
      if (c.out[p].matched) {
        regionEnd = math.max(unionEnd, c.start(p));
        break;
      }
    }
    if (regionEnd <= regionStart) return true;
    final int count = right - left + 1;
    final int regionLen = regionEnd - regionStart;
    c.stats.runs++;
    if (regionLen > maxRegionChars) {
      c.stats.oversizeRuns++;
      debugPrint(
        '[sentenceAudioHighlight] gapFill.skip cues=[$left..$right] '
        'region=$regionLen > maxRegionChars=$maxRegionChars',
      );
      return false;
    }
    final int work = regionLen * count;
    if (c.stats.work + work > maxTotalWork) {
      c.stats.budgetSkippedRuns++;
      debugPrint(
        '[sentenceAudioHighlight] gapFill.skip cues=[$left..$right] '
        'work=${c.stats.work}+$work > maxTotalWork=$maxTotalWork',
      );
      return false;
    }
    c.stats.work += work;

    final String region = c.big.substring(regionStart, regionEnd);
    final List<_Span?> spans = List<_Span?>.filled(count, null);
    // 硬锚点先钉死：区间就是它现在的区间，后面任何一步都不碰。
    final List<bool> pinned = List<bool>.filled(count, false);
    for (int o = 0; o < count; o++) {
      final int k = left + o;
      if (!c.isHard(k)) continue;
      pinned[o] = true;
      spans[o] = _Span(
        c.start(k) - regionStart,
        c.end(k) - regionStart,
        c.out[k].score,
      );
    }
    final List<int> order = List<int>.generate(count, (int o) => o)
      ..sort((int a, int b) {
        final int byLen = c.norms[left + b].length.compareTo(
          c.norms[left + a].length,
        );
        return byLen != 0 ? byLen : a.compareTo(b);
      });
    for (final int o in order) {
      if (pinned[o]) continue;
      final int k = left + o;
      final String nc = c.norms[k];
      final bool isEnd = k == left || k == right;
      final bool soft = c.isSoftAnchor(k);
      if (nc.isEmpty) {
        if (isEnd) {
          c.stats.abandonedRuns++;
          return true;
        }
        continue;
      }
      int lb = 0;
      for (int q = o - 1; q >= 0; q--) {
        if (spans[q] != null) {
          lb = spans[q]!.end;
          break;
        }
      }
      int ub = region.length;
      for (int q = o + 1; q < count; q++) {
        if (spans[q] != null) {
          ub = spans[q]!.start;
          break;
        }
      }
      if (soft) {
        // 软锚点不出「原区间 ∪ 相邻间隙」：搜索范围直接夹到第一遍邻句之内。
        lb = math.max(lb, c.firstPrevEnd(k) - regionStart);
        ub = math.min(ub, c.firstNextStart(k) - regionStart);
      }
      final _Span? best = ub > lb ? _bestSpan(nc, region, lb, ub) : null;
      final double need = isEnd || soft ? anchorMinSimilarity : minSimilarity;
      if (best == null || best.similarity < need) {
        if (isEnd || soft) {
          c.stats.abandonedRuns++;
          return true;
        }
        continue;
      }
      spans[o] = best;
    }
    // 邻句让位：还放不下的中间句，看两侧已落位邻句能不能在同代价对齐里收缩边界，
    // 让出的区间够它用（相似度达标，或长度相称到可以整段认领）就三方一起改。
    for (int o = 1; o < count - 1; o++) {
      if (spans[o] != null || c.norms[left + o].isEmpty) continue;
      int q1 = o - 1;
      while (spans[q1] == null) {
        q1--;
      }
      int q2 = o + 1;
      while (spans[q2] == null) {
        q2++;
      }
      _negotiate(c, region, left, spans, o, q1, q2, pinned[q1], pinned[q2]);
    }
    // 长度相称认领：仍未落位的子串，按两侧已落位邻句夹出的空隙比例切开。放在提交
    // 判定之前，是为了让「短锚点被长句挤回原位」（うん 从 うか 退回 ふむ）算作
    // 挪位而不是丢失。
    int o2 = 1;
    while (o2 < count - 1) {
      if (spans[o2] != null) {
        o2++;
        continue;
      }
      int e = o2;
      while (e < count - 1 && spans[e] == null) {
        e++;
      }
      final List<_Span?>? parts = _proportional(
        <String>[for (int t = o2; t < e; t++) c.norms[left + t]],
        region,
        spans[o2 - 1]!.end,
        spans[e]!.start,
      );
      if (parts != null) {
        for (int t = o2; t < e; t++) {
          spans[t] = parts[t - o2];
        }
      }
      o2 = e;
    }
    // 提交门（所有分支都过）：
    // 1. 软锚点仍在位、相似度达标、不出第一遍邻句夹出的范围（硬锚点已钉死，
    //    伪锚点允许挪位/丢弃）；
    // 2. 净多命中 > 0，或没有丢失且两端锚点仍在原区间并集内（纯边界纠正）。
    for (int o = 0; o < count; o++) {
      final int k = left + o;
      if (pinned[o] || !c.isSoftAnchor(k)) continue;
      final _Span? sp = spans[o];
      if (sp == null ||
          sp.similarity < anchorMinSimilarity - 1e-9 ||
          !c.withinFirstBounds(
            k,
            regionStart + sp.start,
            regionStart + sp.end,
          )) {
        c.stats.abandonedRuns++;
        return true;
      }
    }
    int placed = 0;
    int dropped = 0;
    for (int o = 0; o < count; o++) {
      final bool was = c.out[left + o].matched;
      final bool now = spans[o] != null;
      if (!was && now) placed++;
      if (was && !now) dropped++;
    }
    final bool anchorsInsideUnion =
        regionStart + spans.first!.start >= unionStart &&
            regionStart + spans.last!.end <= unionEnd;
    if (placed <= dropped && !(dropped == 0 && anchorsInsideUnion)) {
      c.stats.abandonedRuns++;
      return true;
    }
    bool changed = false;
    for (int o = 0; o < count; o++) {
      if (pinned[o]) continue;
      final int k = left + o;
      final _Span? sp = spans[o];
      final CueMatch was = c.out[k];
      if (sp == null) {
        if (was.matched) {
          c.out[k] = CueMatch.unmatched;
          changed = true;
        }
        continue;
      }
      final CueMatch now = _match(
        c.cues[k],
        c.sectionStarts,
        regionStart + sp.start,
        regionStart + sp.end,
        sp.similarity,
      );
      if (was.matched &&
          was.sectionIndex == now.sectionIndex &&
          was.normCharStart == now.normCharStart &&
          was.normCharEnd == now.normCharEnd &&
          was.score == now.score) {
        continue;
      }
      c.out[k] = now;
      changed = true;
    }
    if (changed) {
      c.stats.filledRuns++;
    } else {
      c.stats.abandonedRuns++;
    }
    return true;
  }

  /// 让 [q1]（左邻）从右端、[q2]（右邻）从左端在同代价范围内收缩，给 [o] 腾地方。
  /// 成功则同时改写三条的区间。钉死的硬锚点（[pinnedA] / [pinnedB]）不收缩。
  void _negotiate(
    _Ctx c,
    String region,
    int left,
    List<_Span?> spans,
    int o,
    int q1,
    int q2,
    bool pinnedA,
    bool pinnedB,
  ) {
    final _Span a = spans[q1]!;
    final _Span b = spans[q2]!;
    final String na = c.norms[left + q1];
    final String nb = c.norms[left + q2];
    final String nm = c.norms[left + o];
    final List<int> shrinkA =
        pinnedA ? const <int>[0] : _tiedShrinks(na, region, a, fromRight: true);
    final List<int> shrinkB = pinnedB
        ? const <int>[0]
        : _tiedShrinks(nb, region, b, fromRight: false);
    if (shrinkA.length == 1 && shrinkB.length == 1) return;
    _Span? bestM;
    int bestDa = 0;
    int bestDb = 0;
    // 同一个 lb 下各 db 只是终点上限不同：Sellers 表按最大 ub 扫一次，逐 db 取
    // 前缀里的最优终点，不用每个 (da, db) 组合重扫。
    final int ubMax = b.start + shrinkB.last;
    for (final int da in shrinkA) {
      final int lb = a.end - da;
      if (ubMax <= lb) continue;
      final _SellersTable table = _sellers(nm, region, lb, ubMax);
      for (final int db in shrinkB) {
        if (da == 0 && db == 0) continue;
        final int ub = b.start + db;
        if (ub <= lb) continue;
        _Span? m = _bestEnd(nm, region, table, lb, ub);
        if (m == null || m.similarity < minSimilarity) {
          if (!_lengthPlausible(nm.length, ub - lb)) continue;
          m = _Span(lb, ub, _similarity(nm, region.substring(lb, ub)));
        }
        final bool better = bestM == null ||
            m.similarity > bestM.similarity + 1e-9 ||
            (m.similarity > bestM.similarity - 1e-9 &&
                da + db < bestDa + bestDb);
        if (better) {
          bestM = m;
          bestDa = da;
          bestDb = db;
        }
      }
    }
    if (bestM == null) return;
    spans[q1] = _Span(
      a.start,
      a.end - bestDa,
      _similarity(na, region.substring(a.start, a.end - bestDa)),
    );
    spans[q2] = _Span(
      b.start + bestDb,
      b.end,
      _similarity(nb, region.substring(b.start + bestDb, b.end)),
    );
    spans[o] = bestM;
  }

  /// 按各 cue 归一化长度比例把两锚点之间的间隙切给整串仍未命中的 cue（单句即
  /// 整段认领）。只在间隙总长与串总长之比在 [[minLengthRatio], [maxLengthRatio]]
  /// 内时生效。
  void _splitProportionally(_Ctx c, int left, int right) {
    final List<_Span?>? parts = _proportional(
      <String>[for (int k = left + 1; k < right; k++) c.norms[k]],
      c.big,
      c.end(left),
      c.start(right),
    );
    if (parts == null) return;
    for (int k = left + 1; k < right; k++) {
      final _Span? sp = parts[k - left - 1];
      if (sp == null) continue;
      c.out[k] = _match(
        c.cues[k],
        c.sectionStarts,
        sp.start,
        sp.end,
        sp.similarity,
      );
    }
  }

  /// 把 [text] 的 `[gapStart, gapEnd)` 按 [needles] 各自长度比例切开（累计比例取整，
  /// 最后一条吃到末尾避免舍入丢字）。总长与间隙不相称返回 null；空 needle 对应
  /// null 项。
  List<_Span?>? _proportional(
    List<String> needles,
    String text,
    int gapStart,
    int gapEnd,
  ) {
    if (gapEnd <= gapStart) return null;
    final int total = needles.fold<int>(0, (int a, String n) => a + n.length);
    if (total == 0 || !_lengthPlausible(total, gapEnd - gapStart)) return null;
    final String gap = text.substring(gapStart, gapEnd);
    final List<_Span?> out = List<_Span?>.filled(needles.length, null);
    int pos = 0;
    int used = 0;
    for (int t = 0; t < needles.length; t++) {
      final int len = needles[t].length;
      used += len;
      final int end = t == needles.length - 1
          ? gap.length
          : (gap.length * used / total).round();
      if (len == 0 || end <= pos) continue;
      out[t] = _Span(
        gapStart + pos,
        gapStart + end,
        _similarity(needles[t], gap.substring(pos, end)),
      );
      pos = end;
    }
    return out;
  }

  bool _lengthPlausible(int cueLen, int gapLen) {
    if (cueLen <= 0 || gapLen <= 0) return false;
    final double ratio = gapLen / cueLen;
    return ratio <= maxLengthRatio + 1e-9 && ratio >= minLengthRatio - 1e-9;
  }

  static CueMatch _match(
    AudioCue cue,
    List<int> sectionStarts,
    int globalStart,
    int globalEnd,
    double score,
  ) {
    int sec = 0;
    for (int s = 0; s < sectionStarts.length; s++) {
      if (sectionStarts[s] <= globalStart) sec = s;
    }
    final int base = sectionStarts[sec];
    return CueMatch(
      cueSentenceIndex: cue.sentenceIndex,
      sectionIndex: sec,
      normCharStart: globalStart - base,
      normCharEnd: globalEnd - base,
      score: score,
    );
  }

  /// [_bestSpan] 的测试/基准入口：返回 `text[lb, ub)` 里与 [needle] 编辑距离
  /// 相似度最高的子串（绝对偏移）。
  @visibleForTesting
  static ({int start, int end, double similarity})? bestSpanForTest(
    String needle,
    String text,
    int lb,
    int ub,
  ) {
    final _Span? s = _bestSpan(needle, text, lb, ub);
    return s == null
        ? null
        : (start: s.start, end: s.end, similarity: s.similarity);
  }

  /// 在 `text[lb, ub)` 里找与 [needle] 编辑距离相似度（`1 - lev / max(n, len)`）
  /// 最高、长度在 `[ceil(n/2), 2n]` 内的子串。
  ///
  /// 两步，整体 O((ub - lb) × n)：
  /// 1. [_sellers]：起点自由、终点自由的半全局 DP 一次扫完全段，得到每个终点的
  ///    最小编辑代价与对应起点，按相似度挑最优终点（起点由 DP 随手带出，同代价
  ///    时偏向长度不超过 needle 且最接近 needle 的，与 [_tieRank] 同向）；
  /// 2. [_refineStart]：在选定终点上反向再跑一次行 DP，把该终点下所有合法起点
  ///    的代价精确算出来，按原口径（相似度 + [_tieRank]）定起点。
  /// 原实现是「每个起点一次行 DP」的 O((ub - lb) × n²)，region 上万字时主线程冻结
  /// 几十秒（上游审查 A1）。
  static _Span? _bestSpan(String needle, String text, int lb, int ub) {
    final int n = needle.length;
    if (n == 0 || ub <= lb) return null;
    final int minLen = math.max(1, (n / 2).ceil());
    if (ub - lb < minLen) return null;
    final _SellersTable table = _sellers(needle, text, lb, ub);
    return _bestEnd(needle, text, table, lb, ub);
  }

  /// Sellers 半全局近似匹配：按正文列推进的编辑距离 DP，第 0 行恒为 0（起点
  /// 自由），第 n 行 `[j]` 就是「以 j 为终点、起点任意」的最小代价。两行滚动列
  /// 数组，随代价一起传播起点。
  static _SellersTable _sellers(String needle, String text, int lb, int ub) {
    final int n = needle.length;
    final int width = ub - lb;
    final List<int> endDist = List<int>.filled(width + 1, 0);
    final List<int> endStart = List<int>.filled(width + 1, lb);
    List<int> prevD = List<int>.generate(n + 1, (int i) => i);
    List<int> prevS = List<int>.filled(n + 1, lb);
    List<int> currD = List<int>.filled(n + 1, 0);
    List<int> currS = List<int>.filled(n + 1, lb);
    endDist[0] = n;
    for (int j = lb + 1; j <= ub; j++) {
      final int cj = text.codeUnitAt(j - 1);
      currD[0] = 0;
      currS[0] = j;
      for (int i = 1; i <= n; i++) {
        // 对角：needle[i-1] 对 text[j-1]（匹配/替换）。
        int d = prevD[i - 1] + (needle.codeUnitAt(i - 1) == cj ? 0 : 1);
        int s = prevS[i - 1];
        int rank = _tieRank(i, j - s);
        // 左：跳过一个正文字。
        final int dl = prevD[i] + 1;
        if (dl <= d) {
          final int rl = _tieRank(i, j - prevS[i]);
          if (dl < d || rl < rank) {
            d = dl;
            s = prevS[i];
            rank = rl;
          }
        }
        // 上：跳过一个 needle 字。
        final int du = currD[i - 1] + 1;
        if (du <= d) {
          final int ru = _tieRank(i, j - currS[i - 1]);
          if (du < d || ru < rank) {
            d = du;
            s = currS[i - 1];
          }
        }
        currD[i] = d;
        currS[i] = s;
      }
      endDist[j - lb] = currD[n];
      endStart[j - lb] = currS[n];
      final List<int> td = prevD;
      prevD = currD;
      currD = td;
      final List<int> ts = prevS;
      prevS = currS;
      currS = ts;
    }
    return _SellersTable(endDist, endStart);
  }

  /// 在 [table]（[_sellers] 对 `[lb, …)` 的结果）里取终点 ≤ [ubLimit] 的最优
  /// 区间：按相似度、同分按 [_tieRank] 选终点，再 [_refineStart] 精确定起点。
  static _Span? _bestEnd(
    String needle,
    String text,
    _SellersTable table,
    int lb,
    int ubLimit,
  ) {
    final int n = needle.length;
    final int minLen = math.max(1, (n / 2).ceil());
    final int maxLen = 2 * n;
    int bestEnd = -1;
    int bestLen = 0;
    double bestSim = -1;
    for (int j = lb + minLen; j <= ubLimit; j++) {
      final int len = j - table.endStart[j - lb];
      if (len < minLen || len > maxLen) continue;
      final double sim = 1 - table.endDist[j - lb] / math.max(n, len);
      if (sim > bestSim + 1e-9 ||
          (sim > bestSim - 1e-9 && _tieRank(n, len) < _tieRank(n, bestLen))) {
        bestSim = sim;
        bestEnd = j;
        bestLen = len;
      }
    }
    if (bestEnd < 0) return null;
    return _refineStart(needle, text, lb, bestEnd);
  }

  /// 固定终点 [end]，反向行 DP 一次算出所有起点 `s ∈ [max(lb, end-2n), end-⌈n/2⌉]`
  /// 的编辑代价，按原口径定起点。
  /// 同分时取长度不超过 needle 且最接近 needle 的：听写文本里假名展开
  /// （叩き→たたき）只会让 cue 比正文更长，正文候选比 needle 更长意味着多吞了
  /// 邻句的字，比 needle 短得多意味着丢了本句的字。同分但方向相反的歧义
  /// （多读的字是「删掉」还是「替换成邻句的字」）留给 [_negotiate] 用邻句的
  /// 需要来裁决。
  static _Span _refineStart(String needle, String text, int lb, int end) {
    final int n = needle.length;
    final int minLen = math.max(1, (n / 2).ceil());
    final int maxLen = math.min(2 * n, end - lb);
    // row[j] = lev(needle, text[end-j, end))：把 needle 与正文都倒过来读。
    List<int> prev = List<int>.generate(maxLen + 1, (int j) => j);
    List<int> curr = List<int>.filled(maxLen + 1, 0);
    for (int a = 1; a <= n; a++) {
      curr[0] = a;
      final int ca = needle.codeUnitAt(n - a);
      for (int j = 1; j <= maxLen; j++) {
        final int cost = ca == text.codeUnitAt(end - j) ? 0 : 1;
        int v = prev[j - 1] + cost;
        final int del = prev[j] + 1;
        final int ins = curr[j - 1] + 1;
        if (del < v) v = del;
        if (ins < v) v = ins;
        curr[j] = v;
      }
      final List<int> tmp = prev;
      prev = curr;
      curr = tmp;
    }
    int bestLen = minLen;
    double bestSim = -1;
    for (int len = minLen; len <= maxLen; len++) {
      final double sim = 1 - prev[len] / math.max(n, len);
      if (sim > bestSim + 1e-9 ||
          (sim > bestSim - 1e-9 && _tieRank(n, len) < _tieRank(n, bestLen))) {
        bestSim = sim;
        bestLen = len;
      }
    }
    return _Span(end - bestLen, end, bestSim);
  }

  /// 邻句让位：[needle] 对 [span] 的对齐里，从一端收缩 d 个字后**编辑代价**不增
  /// 的所有 d（含 0，升序）。代价不增意味着被收掉的字在原对齐里本来就是「needle
  /// 多出来的字替换成正文的字」，改成删除等价——那几个正文字其实不属于这句。
  /// 比的是代价不是相似度：相似度分母取 max(needle, 区间)，比 needle 更长的区间
  /// 同样代价会拿到更高分，用它比永远判不成同分。
  static List<int> _tiedShrinks(
    String needle,
    String region,
    _Span span, {
    required bool fromRight,
  }) {
    final int n = needle.length;
    final int len = span.end - span.start;
    final int minLen = math.max(1, (n / 2).ceil());
    final List<int> out = <int>[0];
    final int baseCost = _levenshtein(
      needle,
      region.substring(span.start, span.end),
    );
    for (int d = 1; len - d >= minLen; d++) {
      final String shrunk = fromRight
          ? region.substring(span.start, span.end - d)
          : region.substring(span.start + d, span.end);
      if (_levenshtein(needle, shrunk) <= baseCost) out.add(d);
    }
    return out;
  }

  /// 同分候选的排序键：越小越优。不超过 needle 长度的排前面，其中越接近越优。
  static int _tieRank(int needleLen, int len) =>
      len <= needleLen ? needleLen - len : 1000 + (len - needleLen);

  static double _similarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1;
    return 1 - _levenshtein(a, b) / math.max(a.length, b.length);
  }

  static int _levenshtein(String a, String b) {
    final int n = a.length;
    final int m = b.length;
    List<int> prev = List<int>.generate(m + 1, (int j) => j);
    List<int> curr = List<int>.filled(m + 1, 0);
    for (int i = 1; i <= n; i++) {
      curr[0] = i;
      for (int j = 1; j <= m; j++) {
        final int cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        curr[j] = math.min(
          math.min(prev[j] + 1, curr[j - 1] + 1),
          prev[j - 1] + cost,
        );
      }
      final List<int> tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[m];
  }
}

/// 一次 [AnchorGapFiller.fill] 的可观测结果，挂在 [MatchResult.gapFill] 上。
class GapFillStats {
  const GapFillStats({
    required this.runs,
    required this.filledRuns,
    required this.abandonedRuns,
    required this.oversizeRuns,
    required this.budgetSkippedRuns,
    required this.work,
    required this.invariantViolated,
  });

  /// 两侧都有锚点、进入重切的未命中串数。
  final int runs;

  /// 重切提交了改动的串数。
  final int filledRuns;

  /// 重切后一条都没改（相似度/不变式/提交门放弃，或本来就无事可做）、原样
  /// 保留的串数。
  final int abandonedRuns;

  /// region 超过 [AnchorGapFiller.maxRegionChars] 而整串跳过的数目。
  final int oversizeRuns;

  /// 工作量预算 [AnchorGapFiller.maxTotalWork] 耗尽后跳过的串数。
  final int budgetSkippedRuns;

  /// 实际消耗的工作量（Σ region 字符数 × 串内 cue 数）。
  final int work;

  /// 末尾复核发现锚点不变式被违反、整次回填被退回第一遍结果。
  final bool invariantViolated;

  /// 有串因超限/预算被跳过。
  bool get skippedAny => oversizeRuns > 0 || budgetSkippedRuns > 0;

  @override
  String toString() => 'GapFillStats(runs=$runs filled=$filledRuns '
      'abandoned=$abandonedRuns oversize=$oversizeRuns '
      'budgetSkipped=$budgetSkippedRuns work=$work '
      'invariantViolated=$invariantViolated)';
}

/// [GapFillStats] 的可变累加器。
class _Stats {
  int runs = 0;
  int filledRuns = 0;
  int abandonedRuns = 0;
  int oversizeRuns = 0;
  int budgetSkippedRuns = 0;
  int work = 0;

  GapFillStats snapshot({required bool invariantViolated}) => GapFillStats(
        runs: runs,
        filledRuns: filledRuns,
        abandonedRuns: abandonedRuns,
        oversizeRuns: oversizeRuns,
        budgetSkippedRuns: budgetSkippedRuns,
        work: work,
        invariantViolated: invariantViolated,
      );
}

/// 一次 [AnchorGapFiller.fill] 的工作集。
class _Ctx {
  _Ctx({
    required this.big,
    required this.sectionStarts,
    required this.cues,
    required this.norms,
    required this.first,
    required this.out,
    required int softAnchorMaxLen,
  })  : _softAnchorMaxLen = softAnchorMaxLen,
        _firstPrevEnd = List<int>.filled(first.length, 0),
        _firstNextStart = List<int>.filled(first.length, big.length) {
    // 第一遍里每条 cue 前/后最近一条命中 cue 的终点/起点（全局偏移），软锚点
    // 重切不得越过。
    int prevEnd = 0;
    for (int k = 0; k < first.length; k++) {
      _firstPrevEnd[k] = prevEnd;
      if (first[k].matched) prevEnd = _global(first[k], end: true);
    }
    int nextStart = big.length;
    for (int k = first.length - 1; k >= 0; k--) {
      _firstNextStart[k] = nextStart;
      if (first[k].matched) nextStart = _global(first[k], end: false);
    }
  }

  final String big;
  final List<int> sectionStarts;
  final List<AudioCue> cues;

  /// 每条 cue 的归一化文本（与 [big] 同口径）。
  final List<String> norms;

  /// 第一遍结果快照（不变），锚点分类与软锚点边界都以它为准。
  final List<CueMatch> first;

  /// 正在改写的结果（与 [cues] 一一对应）。
  final List<CueMatch> out;

  final _Stats stats = _Stats();

  final int _softAnchorMaxLen;
  final List<int> _firstPrevEnd;
  final List<int> _firstNextStart;

  int start(int k) => sectionStarts[out[k].sectionIndex] + out[k].normCharStart;
  int end(int k) => sectionStarts[out[k].sectionIndex] + out[k].normCharEnd;

  int _global(CueMatch m, {required bool end}) =>
      sectionStarts[m.sectionIndex] + (end ? m.normCharEnd : m.normCharStart);

  /// 硬锚点：第一遍精确命中且不是两字短句。
  bool isHard(int k) =>
      first[k].matched &&
      first[k].score >= 1.0 &&
      norms[k].length > _softAnchorMaxLen;

  /// 伪锚点：第一遍命中的两字短句（可挪位/丢弃）。
  bool isPseudo(int k) =>
      first[k].matched && norms[k].length <= _softAnchorMaxLen;

  /// 软锚点：第一遍模糊命中的长句（可在边界内重切，不可丢）。
  bool isSoftAnchor(int k) => first[k].matched && !isHard(k) && !isPseudo(k);

  /// 第一遍里 k 前一条命中 cue 的终点（全局偏移；没有则 0）。
  int firstPrevEnd(int k) => _firstPrevEnd[k];

  /// 第一遍里 k 后一条命中 cue 的起点（全局偏移；没有则正文末尾）。
  int firstNextStart(int k) => _firstNextStart[k];

  /// `[gStart, gEnd)` 是否落在 k 的「原区间 ∪ 相邻间隙」内。
  bool withinFirstBounds(int k, int gStart, int gEnd) =>
      gStart >= _firstPrevEnd[k] && gEnd <= _firstNextStart[k];
}

/// [AnchorGapFiller._sellers] 的输出：下标 `j - lb` 对应终点 j。
class _SellersTable {
  const _SellersTable(this.endDist, this.endStart);

  /// 以 j 为终点、起点任意的最小编辑代价。
  final List<int> endDist;

  /// 取到该代价的起点（绝对偏移）。
  final List<int> endStart;
}

class _Span {
  const _Span(this.start, this.end, this.similarity);
  final int start;
  final int end;
  final double similarity;
}

/// 把命中 cue 的文本换成正文原文（含标点等被归一化剥掉的字符）。
///
/// 用途：ASR 产物的 cue 文本是听写，阅读器高亮时用 cue 文本在 DOM 里就近重定位
/// （`audiobook_bridge.dart`），听写差会让重定位失败；换成正文后重定位精确，
/// 歌词模式显示的也是正文。只改命中的 cue；未命中的保留听写文本。
void replaceMatchedCueTextWithBookText({
  required List<EpubSection> sections,
  required List<AudioCue> cues,
  required MatchResult result,
}) {
  if (result.matches.length != cues.length) return;
  final Map<int, NormalizedTextWithOffsets> normalized =
      <int, NormalizedTextWithOffsets>{};
  for (int i = 0; i < cues.length; i++) {
    final CueMatch m = result.matches[i];
    if (!m.matched || m.sectionIndex >= sections.length) continue;
    final NormalizedTextWithOffsets norm = normalized.putIfAbsent(
      m.sectionIndex,
      () => AudioTextNormalizer.normalizeWithOffsets(
        sections[m.sectionIndex].text,
      ),
    );
    final String slice = _bookSliceWithPunctuation(
      sections[m.sectionIndex].text,
      norm,
      m.normCharStart,
      m.normCharEnd,
    );
    if (slice.isNotEmpty) cues[i].text = slice;
  }
}

/// 归一化区间 `[from, to)` 对应的原文，并把归一化时剥掉的标点带回来：向后一直
/// 带到下一个保留字符之前（句号、引号、逗号都属于本句），但把紧挨下一句的开引号
/// 留给下一句；向前只带紧邻的开引号/开括号。空白按 [_collapseWhitespace] 折叠：
/// CJK 之间的换行/空格去掉，拉丁词之间保留一个空格。
String _bookSliceWithPunctuation(
  String original,
  NormalizedTextWithOffsets norm,
  int from,
  int to,
) {
  if (to <= from || from < 0 || to > norm.text.length) return '';
  int start = norm.starts[from];
  while (start > 0 && _isOpeningMark(original.codeUnitAt(start - 1))) {
    start--;
  }
  int end = to < norm.text.length ? norm.starts[to] : original.length;
  while (end > norm.ends[to - 1] &&
      (_isOpeningMark(original.codeUnitAt(end - 1)) ||
          _isWhitespace(original.codeUnitAt(end - 1)))) {
    end--;
  }
  return _collapseWhitespace(original.substring(start, end));
}

/// 折叠正文里的空白：一段空白若两侧都是非 CJK 字符（英文词与词之间）压成一个
/// 空格，否则整段去掉（日文正文里的换行/缩进不是内容）。首尾空白一律去掉。
///
/// 原先「空白一律去掉」只对日文成立：英语有声书的 cue 换成正文后会变成
/// `Mr.Dursleywasthedirector…`，歌词模式显示与导出全废（2026-09-06 英语模型
/// 接入时在《Harry Potter》真实数据上发现）。
String _collapseWhitespace(String s) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  final int n = s.length;
  while (i < n) {
    final int c = s.codeUnitAt(i);
    if (!_isAnyWhitespace(c)) {
      out.writeCharCode(c);
      i++;
      continue;
    }
    int j = i;
    while (j < n && _isAnyWhitespace(s.codeUnitAt(j))) {
      j++;
    }
    final bool atEdge = out.isEmpty || j >= n;
    if (!atEdge) {
      final int prev = s.codeUnitAt(i - 1);
      final int next = s.codeUnitAt(j);
      if (!_isCjk(prev) && !_isCjk(next)) out.writeCharCode(0x20);
    }
    i = j;
  }
  return out.toString();
}

bool _isAnyWhitespace(int c) =>
    _isWhitespace(c) || c == 0x0B || c == 0x0C || c == 0xA0;

/// 粗判 CJK：假名、汉字、全角标点与兼容区。只用来决定空白该不该保留，
/// 不要求与 [AudioTextNormalizer] 的白名单逐段一致。
bool _isCjk(int c) =>
    (c >= 0x2E80 && c <= 0x9FFF) ||
    (c >= 0xF900 && c <= 0xFAFF) ||
    (c >= 0xFF00 && c <= 0xFFEF) ||
    (c >= 0x3000 && c <= 0x303F);

bool _isOpeningMark(int c) =>
    c == 0x300C || // 「
    c == 0x300E || // 『
    c == 0xFF08 || // （
    c == 0x28 || // (
    c == 0x3010 || // 【
    c == 0x3014 || // 〔
    c == 0x300A || // 《
    c == 0x3008 || // 〈
    c == 0x201C || // “
    c == 0x2018; // ‘

bool _isWhitespace(int c) =>
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x3000;
