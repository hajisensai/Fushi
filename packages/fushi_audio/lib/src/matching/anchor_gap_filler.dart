import 'dart:math' as math;

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
///   硬锚点（两端的长句）必须以 ≥ [anchorMinSimilarity] 落位，否则整体放弃；
///   中间句 ≥ [minSimilarity] 才接受。提交条件：净多命中 > 0，或没有丢失且两端
///   锚点仍在原区间并集内（纯边界纠正）。
/// - ② 剩下仍未命中的子串：其总归一化长度与所在间隙长度之比在
///   [[minLengthRatio], [maxLengthRatio]] 内时，按各句长度比例切开认领（单句就是
///   整段认领），不看相似度——朗读者不会在两句已对上的句子之间读别的东西，而
///   纯かな⇄漢字改写（たぶん/多分、せいれい/精霊）编辑距离是零重叠的。
/// - 回填命中的 [CueMatch.score] 就是编辑距离相似度（< 1）。
class AnchorGapFiller {
  const AnchorGapFiller({
    this.minSimilarity = 0.45,
    this.maxLengthRatio = 2.5,
    this.minLengthRatio = 0.3,
    this.anchorMinSimilarity = 0.5,
    this.softAnchorMaxLen = 2,
  });

  /// 编辑距离相似度门槛（`1 - lev / max(len)`）。0.45 允许一半左右的字被替换或
  /// 增删——比 Dice 的 0.6 宽得多，因为搜索范围已被锚点钉死。
  final double minSimilarity;

  /// 邻句重切时锚点自身重切后必须达到的相似度（原本就是命中的，放宽只会让它
  /// 挪去吞别的东西）。
  final double anchorMinSimilarity;

  /// 间隙长度 / cue 归一化长度 的上限（比这更长说明正文里有被跳读的句子）。
  final double maxLengthRatio;

  /// 间隙长度 / cue 归一化长度 的下限。かな 听写对漢字正文（あーすふぉーとれす
  /// / 土砦）常到 3 倍，比这更短说明 cue 是正文里没有的旁白。
  final double minLengthRatio;

  /// 不超过这个归一化长度的锚点视为「软锚点」：重切时向外多扩一条，让它作为
  /// 中间句参与重排（可被挪位或丢弃）。
  final int softAnchorMaxLen;

  /// 返回回填后的新 [MatchResult]（不修改入参）。[result] 必须是对同一
  /// [sections] / [cues] 跑出来的。
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
      out: List<CueMatch>.of(result.matches),
    );

    int matchedDelta = 0;
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
      matchedDelta += _realign(c, i - 1, j);
      // ② 剩下的每个子串以「当前已定位的邻句」为界按长度比例认领。邻句要现找：
      // ① 可能把软锚点（原 i-1 / j 上的两字句）丢成未命中，不能再当它们是锚。
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
          matchedDelta += _splitProportionally(c, leftAnchor, rightAnchor);
        }
        k = e;
      }
      i = j;
    }
    return MatchResult(
      matches: c.out,
      totalCues: result.totalCues,
      matchedCues: result.matchedCues + matchedDelta,
    );
  }

  /// 重切 [left0..right0]（两端为已命中锚点，中间全部未命中）。返回净多命中数。
  int _realign(_Ctx c, int left0, int right0) {
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
    if (regionEnd <= regionStart) return 0;
    final String region = c.big.substring(regionStart, regionEnd);
    final int count = right - left + 1;
    final List<_Span?> spans = List<_Span?>.filled(count, null);
    final List<int> order = List<int>.generate(count, (int o) => o)
      ..sort((int a, int b) {
        final int byLen = c.norms[left + b].length.compareTo(
          c.norms[left + a].length,
        );
        return byLen != 0 ? byLen : a.compareTo(b);
      });
    for (final int o in order) {
      final int k = left + o;
      final String nc = c.norms[k];
      final bool hard = k == left || k == right;
      if (nc.isEmpty) {
        if (hard) return 0;
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
      final _Span? best =
          ub > lb ? _bestSpan(nc, region.substring(0, ub), lb) : null;
      if (best == null ||
          best.similarity < (hard ? anchorMinSimilarity : minSimilarity)) {
        if (hard) return 0;
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
      _negotiate(c, region, left, spans, o, q1, q2);
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
    if (placed <= dropped && !(dropped == 0 && anchorsInsideUnion)) return 0;
    for (int o = 0; o < count; o++) {
      final int k = left + o;
      final _Span? sp = spans[o];
      if (sp == null) {
        if (c.out[k].matched) c.out[k] = CueMatch.unmatched;
        continue;
      }
      c.out[k] = _match(
        c.cues[k],
        c.sectionStarts,
        regionStart + sp.start,
        regionStart + sp.end,
        sp.similarity,
      );
    }
    return placed - dropped;
  }

  /// 让 [q1]（左邻）从右端、[q2]（右邻）从左端在同代价范围内收缩，给 [o] 腾地方。
  /// 成功则同时改写三条的区间。
  void _negotiate(
    _Ctx c,
    String region,
    int left,
    List<_Span?> spans,
    int o,
    int q1,
    int q2,
  ) {
    final _Span a = spans[q1]!;
    final _Span b = spans[q2]!;
    final String na = c.norms[left + q1];
    final String nb = c.norms[left + q2];
    final String nm = c.norms[left + o];
    final List<int> shrinkA = _tiedShrinks(na, region, a, fromRight: true);
    final List<int> shrinkB = _tiedShrinks(nb, region, b, fromRight: false);
    if (shrinkA.length == 1 && shrinkB.length == 1) return;
    _Span? bestM;
    int bestDa = 0;
    int bestDb = 0;
    for (final int da in shrinkA) {
      for (final int db in shrinkB) {
        if (da == 0 && db == 0) continue;
        final int lb = a.end - da;
        final int ub = b.start + db;
        if (ub <= lb) continue;
        _Span? m = _bestSpan(nm, region.substring(0, ub), lb);
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
  int _splitProportionally(_Ctx c, int left, int right) {
    final List<_Span?>? parts = _proportional(
      <String>[for (int k = left + 1; k < right; k++) c.norms[k]],
      c.big,
      c.end(left),
      c.start(right),
    );
    if (parts == null) return 0;
    int placed = 0;
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
      placed++;
    }
    return placed;
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

  /// 在 `gap[cursor..]` 里找与 [needle] 编辑距离相似度最高的子串。候选长度
  /// [ceil(n/2), 2n]，起点从 cursor 到末尾；用一次 DP 行算出同一起点下所有长度的
  /// 距离。
  /// 在 [gap] 里从 [cursor] 起找与 [needle] 编辑距离相似度最高的子串。
  static _Span? _bestSpan(String needle, String gap, int cursor) {
    final int n = needle.length;
    if (n == 0 || cursor >= gap.length) return null;
    final int minLen = math.max(1, (n / 2).ceil());
    final int maxLen = math.min(2 * n, gap.length - cursor);
    if (maxLen < minLen) return null;
    _Span? best;
    for (int s = cursor; s + minLen <= gap.length; s++) {
      final int limit = math.min(maxLen, gap.length - s);
      // DP：row[j] = lev(needle, gap[s, s+j)).
      List<int> prev = List<int>.generate(limit + 1, (int j) => j);
      List<int> curr = List<int>.filled(limit + 1, 0);
      for (int a = 1; a <= n; a++) {
        curr[0] = a;
        final int ca = needle.codeUnitAt(a - 1);
        for (int j = 1; j <= limit; j++) {
          final int cost = ca == gap.codeUnitAt(s + j - 1) ? 0 : 1;
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
      for (int len = minLen; len <= limit; len++) {
        final double sim = 1 - prev[len] / math.max(n, len);
        // 同分时取长度不超过 needle 且最接近 needle 的：听写文本里假名展开
        // （叩き→たたき）只会让 cue 比正文更长，正文候选比 needle 更长意味着多吞了
        // 邻句的字，比 needle 短得多意味着丢了本句的字。同分但方向相反的歧义
        // （多读的字是「删掉」还是「替换成邻句的字」）留给 [_negotiate] 用邻句的
        // 需要来裁决。
        final bool better = best == null ||
            sim > best.similarity + 1e-9 ||
            (sim > best.similarity - 1e-9 &&
                _tieRank(n, len) < _tieRank(n, best.end - best.start));
        if (better) best = _Span(s, s + len, sim);
      }
    }
    return best;
  }

  /// 邻句让位：[needle] 对 [span] 的对齐里，从一端收缩 d 个字后**编辑代价**不增
  /// 的所有 d（含 0）。代价不增意味着被收掉的字在原对齐里本来就是「needle 多出来
  /// 的字替换成正文的字」，改成删除等价——那几个正文字其实不属于这句。比的是
  /// 代价不是相似度：相似度分母取 max(needle, 区间)，比 needle 更长的区间同样
  /// 代价会拿到更高分，用它比永远判不成同分。
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

/// 一次 [AnchorGapFiller.fill] 的工作集。
class _Ctx {
  _Ctx({
    required this.big,
    required this.sectionStarts,
    required this.cues,
    required this.norms,
    required this.out,
  });

  final String big;
  final List<int> sectionStarts;
  final List<AudioCue> cues;

  /// 每条 cue 的归一化文本（与 [big] 同口径）。
  final List<String> norms;

  /// 正在改写的结果（与 [cues] 一一对应）。
  final List<CueMatch> out;

  int start(int k) => sectionStarts[out[k].sectionIndex] + out[k].normCharStart;
  int end(int k) => sectionStarts[out[k].sectionIndex] + out[k].normCharEnd;
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
/// 留给下一句；向前只带紧邻的开引号/开括号。空白一律去掉。
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
  return original.substring(start, end).replaceAll(RegExp(r'\s+'), '');
}

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
