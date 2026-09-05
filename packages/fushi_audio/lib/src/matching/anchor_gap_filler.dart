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
/// - 单条 cue 独占一段间隙、且间隙长度与 cue 归一化长度在 [1/[maxLengthRatio],
///   [maxLengthRatio]] 内：整段就是它，不看相似度（朗读者不会在两句已对上的句子
///   之间读别的东西）。
/// - 其它情况：在间隙里从游标起做编辑距离滑窗，相似度 ≥ [minSimilarity] 才接受，
///   游标单调推进；接受不了的保持未命中（可能是朗读者加的旁白，或正文被跳过）。
/// - 回填命中的 [CueMatch.score] 就是编辑距离相似度（< 1）。
class AnchorGapFiller {
  const AnchorGapFiller({this.minSimilarity = 0.45, this.maxLengthRatio = 2.5});

  /// 编辑距离相似度门槛（`1 - lev / max(len)`）。0.45 允许一半左右的字被替换或
  /// 增删——比 Dice 的 0.6 宽得多，因为搜索范围已被锚点钉死。
  final double minSimilarity;

  /// 单 cue 独占间隙时允许的长度比上限。
  final double maxLengthRatio;

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

    final List<CueMatch> out = List<CueMatch>.of(result.matches);
    int globalStart(CueMatch m) =>
        sectionStarts[m.sectionIndex] + m.normCharStart;
    int globalEnd(CueMatch m) => sectionStarts[m.sectionIndex] + m.normCharEnd;

    int matchedDelta = 0;
    int i = 0;
    while (i < cues.length) {
      if (out[i].matched) {
        i++;
        continue;
      }
      // 未命中串 [i, j)。
      int j = i;
      while (j < cues.length && !out[j].matched) {
        j++;
      }
      if (i == 0 || j >= cues.length) {
        i = j;
        continue;
      }
      final int gapStart = globalEnd(out[i - 1]);
      final int gapEnd = globalStart(out[j]);
      if (gapEnd > gapStart) {
        matchedDelta += _fillRun(
          big: big,
          sectionStarts: sectionStarts,
          cues: cues,
          out: out,
          from: i,
          to: j,
          gapStart: gapStart,
          gapEnd: gapEnd,
        );
      }
      i = j;
    }
    return MatchResult(
      matches: out,
      totalCues: result.totalCues,
      matchedCues: result.matchedCues + matchedDelta,
    );
  }

  int _fillRun({
    required String big,
    required List<int> sectionStarts,
    required List<AudioCue> cues,
    required List<CueMatch> out,
    required int from,
    required int to,
    required int gapStart,
    required int gapEnd,
  }) {
    final String gap = big.substring(gapStart, gapEnd);
    int filled = 0;
    // 单 cue 独占间隙：长度合理就整段认领。
    if (to - from == 1) {
      final String nc = AudioTextNormalizer.normalize(cues[from].text);
      if (nc.isNotEmpty && _lengthPlausible(nc.length, gap.length)) {
        out[from] = _match(
          cues[from],
          sectionStarts,
          gapStart,
          gapEnd,
          _similarity(nc, gap),
        );
        return 1;
      }
    }
    int cursor = 0;
    for (int k = from; k < to; k++) {
      final String nc = AudioTextNormalizer.normalize(cues[k].text);
      if (nc.isEmpty || cursor >= gap.length) continue;
      final _Span? best = _bestSpan(nc, gap, cursor);
      if (best == null || best.similarity < minSimilarity) continue;
      out[k] = _match(
        cues[k],
        sectionStarts,
        gapStart + best.start,
        gapStart + best.end,
        best.similarity,
      );
      cursor = best.end;
      filled++;
    }
    // 第二遍：贪心滑窗靠字符重叠，纯かな⇄漢字改写（たぶん/多分）零重叠会漏。但
    // 只要它两侧的 cue 都已定位（回填的或锚点），它就独占夹在中间的子间隙——
    // 套用单 cue 整段认领的规则。
    for (int k = from; k < to; k++) {
      if (out[k].matched) continue;
      if (k > from && !out[k - 1].matched) continue;
      if (k + 1 < to && !out[k + 1].matched) continue;
      final int left = k > from
          ? _globalEnd(out[k - 1], sectionStarts)
          : gapStart;
      final int right = k + 1 < to
          ? _globalStart(out[k + 1], sectionStarts)
          : gapEnd;
      if (right <= left) continue;
      final String nc = AudioTextNormalizer.normalize(cues[k].text);
      if (nc.isEmpty || !_lengthPlausible(nc.length, right - left)) continue;
      out[k] = _match(
        cues[k],
        sectionStarts,
        left,
        right,
        _similarity(nc, big.substring(left, right)),
      );
      filled++;
    }
    return filled;
  }

  static int _globalStart(CueMatch m, List<int> sectionStarts) =>
      sectionStarts[m.sectionIndex] + m.normCharStart;

  static int _globalEnd(CueMatch m, List<int> sectionStarts) =>
      sectionStarts[m.sectionIndex] + m.normCharEnd;

  bool _lengthPlausible(int cueLen, int gapLen) {
    if (cueLen <= 0 || gapLen <= 0) return false;
    final double ratio = gapLen / cueLen;
    return ratio <= maxLengthRatio && ratio >= 1 / maxLengthRatio;
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
        // 邻句的字，比 needle 短得多意味着丢了本句的字。
        final bool better =
            best == null ||
            sim > best.similarity + 1e-9 ||
            (sim > best.similarity - 1e-9 &&
                _tieRank(n, len) < _tieRank(n, best.end - best.start));
        if (better) best = _Span(s, s + len, sim);
      }
    }
    return best;
  }

  /// 同分候选的排序键：越小越优。不超过 needle 长度的排前面，其中越接近越优。
  static int _tieRank(int needleLen, int len) =>
      len <= needleLen ? needleLen - len : 1000 + (len - needleLen);

  static double _similarity(String a, String b) {
    if (a.isEmpty && b.isEmpty) return 1;
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
    return 1 - prev[m] / math.max(n, m);
  }
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
