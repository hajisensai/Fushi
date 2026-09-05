import 'package:flutter/foundation.dart';
import 'audio_text_normalizer.dart';
import '../audiobook/audiobook_model.dart';

/// EPUB 一个章节，供 [EpubSrtMatcher] 使用。
///
/// `text` 必须是剥离 HTML（含 ruby `<rt>/<rp>`）后的纯文本，一般通过
/// EpubBooks 数据库的 `elementHtml` 或原始 XHTML 抽取得到。
class EpubSection {
  const EpubSection({
    required this.index,
    required this.href,
    required this.text,
  });

  final int index;
  final String href;
  final String text;
}

/// 单条 cue 在 EPUB 里的匹配结果。
///
/// 偏移以**规范化后**（白名单保留假名/汉字/字母数字，其余剥掉）的字符位置
/// 给出。运行时高亮若需要 DOM 坐标，WebView 侧必须用**完全相同的规范化
/// 规则**（见 `audiobook_bridge.dart::__fushiIsSkippable`）走 text node 数过来。
class CueMatch {
  const CueMatch({
    required this.cueSentenceIndex,
    required this.sectionIndex,
    required this.normCharStart,
    required this.normCharEnd,
    required this.score,
  });

  static const CueMatch unmatched = CueMatch(
    cueSentenceIndex: -1,
    sectionIndex: -1,
    normCharStart: -1,
    normCharEnd: -1,
    score: 0,
  );

  final int cueSentenceIndex;
  final int sectionIndex;
  final int normCharStart;
  final int normCharEnd;

  /// 精确子串匹配命中 = 1.0，Dice 模糊命中 = 阈值..1.0，未命中 = 0.0。
  final double score;

  bool get matched => sectionIndex >= 0;
}

class MatchResult {
  const MatchResult({
    required this.matches,
    required this.totalCues,
    required this.matchedCues,
  });

  final List<CueMatch> matches;
  final int totalCues;
  final int matchedCues;

  double get matchRate => totalCues == 0 ? 0.0 : matchedCues / totalCues;
}

/// EPUB↔字幕匹配器，移植自 ttu-whispersync 的 Dice 系数模糊匹配。
///
/// 算法：
/// 1. 章节文本拼成一串 `big`，同时记录每章在 `big` 里的起点。
/// 2. 规范化用**白名单**：只保留 假名 / 汉字 / CJK 扩展 A / ASCII & 全角字母
///    数字 / 半角假名。其它（句读、引号、`＊` 叙述标记、空白、ruby 注音
///    剥完后的残留空格等）一律扔掉。
/// 3. **起点检测**：取前 15 条 cue，跳过以 `＊` 开头的旁白 / 标题 cue，
///    跳过规范化后 < 6 字的短 cue，在全书做精确 `indexOf`（+ 模糊兜底），
///    取最小命中位置作为 cursor 起点。
/// 4. **主循环**（移植自 ttu-whispersync Match.svelte）：
///    a. 快速通道：精确 `indexOf` 命中 → score=1.0，cursor 推进。
///    b. 模糊兜底：在 `[cursor, cursor+searchWindow]` 内单次 Dice 滑窗扫描，
///       取最高位置；达到 [similarityThreshold] 则接受。**仅长 cue
///       （规范化后 >= [defaultProbeMinLen]）走模糊**；更短的 cue 只接受
///       精确子串命中，避免高频短虚词（うん/はい）的 unigram Dice 误判
///       抬高匹配率（TODO-906）。
///    c. 恢复机制：连续 miss 达 [maxConsecutiveMisses] 时，用精确 `indexOf`
///       在全书 `[cursor..]` 范围做一次恢复扫描。cursor 不做逐字偏移重试
///       （O(attempts×window) 太慢），只靠恢复扫描跳过不匹配的段落。
class EpubSrtMatcher {
  static const int defaultSearchWindow = 200;
  static const int defaultProbeCount = 24;

  /// 起点候选的「同伙半径」：两条探测 cue 的命中相距不超过这么多归一化字符就算
  /// 互相佐证（前 24 条 cue 的正文通常几百到两千字）。
  static const int startClusterSpan = 3000;

  /// 起点之后至少要剩下 cue 总归一化长度的这个比例，否则音频塞不进去——出版社名
  /// 只在书尾版权页命中就是这样被淘汰的。
  static const double startMinRemainingRatio = 0.5;
  static const int defaultProbeMinLen = 6;
  static const double defaultSimilarityThreshold = 0.8;
  static const int defaultMaxConsecutiveMisses = 20;

  /// 规范化后 ≤ 此长度的 cue 视为「超短 cue」：精确命中只在游标附近
  /// [shortCueMaxAdvance] 字以内才作数（理由见主循环快速通道注释）。
  static const int shortCueMaxLen = 2;
  static const int shortCueMaxAdvance = 16;

  static Future<MatchResult> matchInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = defaultSearchWindow,
    double similarityThreshold = defaultSimilarityThreshold,
    int maxConsecutiveMisses = defaultMaxConsecutiveMisses,
  }) {
    final _MatchRequest req = _MatchRequest(
      sections: sections,
      cueTexts: <String>[for (final AudioCue c in cues) c.text],
      cueIndexes: <int>[for (final AudioCue c in cues) c.sentenceIndex],
      searchWindow: searchWindow,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
    );
    return compute(_matchEntrypoint, req);
  }

  static Future<ProbeResult> probeInIsolate({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required List<int> windows,
    double similarityThreshold = defaultSimilarityThreshold,
    int maxConsecutiveMisses = defaultMaxConsecutiveMisses,
  }) {
    final _ProbeRequest req = _ProbeRequest(
      sections: sections,
      cueTexts: <String>[for (final AudioCue c in cues) c.text],
      cueIndexes: <int>[for (final AudioCue c in cues) c.sentenceIndex],
      windows: windows,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
    );
    return compute(_probeEntrypoint, req);
  }

  static MatchResult match({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    int searchWindow = defaultSearchWindow,
    double similarityThreshold = defaultSimilarityThreshold,
    int maxConsecutiveMisses = defaultMaxConsecutiveMisses,
  }) {
    if (cues.isEmpty) {
      return const MatchResult(
        matches: <CueMatch>[],
        totalCues: 0,
        matchedCues: 0,
      );
    }
    if (sections.isEmpty) {
      return MatchResult(
        matches: List<CueMatch>.filled(cues.length, CueMatch.unmatched),
        totalCues: cues.length,
        matchedCues: 0,
      );
    }

    final List<String> normCueTexts = <String>[
      for (final AudioCue c in cues) AudioTextNormalizer.normalize(c.text),
    ];
    return _matchCore(
      idx: _buildIndex(sections),
      sections: sections,
      cues: cues,
      searchWindow: searchWindow,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
      preNormCueTexts: normCueTexts,
    );
  }

  static MatchResult _matchCore({
    required _Index idx,
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required int searchWindow,
    required double similarityThreshold,
    required int maxConsecutiveMisses,
    List<String>? preNormCueTexts,
  }) {
    final String big = idx.normText;
    final int totalLen = big.length;

    final int start = _findStart(
      big,
      cues,
      similarityThreshold,
      preNormCueTexts,
    );
    debugPrint(
      '[sentenceAudioHighlight] matcher: sections=${sections.length} '
      'totalNormLen=$totalLen cues=${cues.length} startCursor=$start '
      'threshold=$similarityThreshold',
    );
    for (int si = 0; si < sections.length; si++) {
      final int s0 = idx.sectionNormStarts[si];
      final int s1 =
          (si + 1 < sections.length) ? idx.sectionNormStarts[si + 1] : totalLen;
      debugPrint(
        '[sentenceAudioHighlight] matcher.section[$si] href="${sections[si].href}" '
        'normStart=$s0 normLen=${s1 - s0}',
      );
    }

    final List<CueMatch> results = <CueMatch>[];
    int cursor = start;
    int matched = 0;
    int consecutiveMisses = 0;

    for (int ci = 0; ci < cues.length; ci++) {
      final AudioCue cue = cues[ci];
      final String nc = preNormCueTexts != null
          ? preNormCueTexts[ci]
          : AudioTextNormalizer.normalize(cue.text);
      if (nc.isEmpty) {
        results.add(CueMatch.unmatched);
        continue;
      }

      // --- 恢复机制：连续 miss 过多时在全书剩余文本做 indexOf 重锚 ---
      if (consecutiveMisses >= maxConsecutiveMisses &&
          nc.length >= defaultProbeMinLen) {
        final int recovered = big.indexOf(nc, cursor);
        if (recovered >= 0) {
          cursor = recovered;
          consecutiveMisses = 0;
          debugPrint(
            '[sentenceAudioHighlight] matcher.recover cursor=$cursor '
            'cue="${_clip(cue.text, 24)}"',
          );
        }
      }

      // --- 快速通道：精确 indexOf ---
      final int windowEnd = (cursor + searchWindow).clamp(0, totalLen);
      if (windowEnd - cursor >= nc.length) {
        final int found = big.indexOf(nc, cursor);
        // 超短 cue（≤ [shortCueMaxLen] 字）的精确命中只认紧邻游标的位置：一两个
        // 字在 200 字窗口里几乎必然能撞上（「一」「え」「ああ」），撞上就把游标
        // 拽走，后面整段正文全 miss。2026-09-05 无職転生 01 真机对照：ASR 字幕的
        // 卷号 cue「一」命中了第七节「第一章」，游标越过第六节题词，12 条 cue
        // 连锁错过（SubPlz 那份写作「＊1」，规范化后是数字 1 才侥幸没撞）。
        final bool tooFarForShortCue =
            nc.length <= shortCueMaxLen && found > cursor + shortCueMaxAdvance;
        if (found >= 0 &&
            found + nc.length <= windowEnd &&
            !tooFarForShortCue) {
          final int matchEnd = found + nc.length;
          final int secIdx = _sectionForOffset(idx.sectionNormStarts, found);
          results.add(
            CueMatch(
              cueSentenceIndex: cue.sentenceIndex,
              sectionIndex: secIdx,
              normCharStart: found - idx.sectionNormStarts[secIdx],
              normCharEnd: matchEnd - idx.sectionNormStarts[secIdx],
              score: 1,
            ),
          );
          _logHit(
            matched,
            cue,
            nc,
            big,
            found,
            matchEnd,
            secIdx,
            idx.sectionNormStarts[secIdx],
            1,
            ci == cues.length - 1,
          );
          cursor = matchEnd;
          matched++;
          consecutiveMisses = 0;
          continue;
        }
      }

      // --- 模糊通道：滚动窗口 Dice 系数，O(window) 而非 O(window×len) ---
      // 收紧虚高（TODO-906）：规范化后 < [defaultProbeMinLen] 的短 cue 退化为
      // unigram Dice（[_slidingDice] 在 nLen<5 时 n=1），日语高频短虚词
      // （うん / はい 等）极易在正文任意位置凑够字符重叠误判命中，整体抬高
      // matchRate。这类短 cue 一律要求精确子串命中（上面的快速通道已处理），
      // 模糊兜底只留给长 cue（听写/排版 1~2 字差异的真实正文句）。
      double bestSim = 0;
      int bestPos = -1;
      int bestLen = nc.length;

      final bool allowFuzzy = nc.length >= defaultProbeMinLen;
      if (allowFuzzy && windowEnd - cursor >= nc.length) {
        final _SlidingDiceResult r = _slidingDice(
          needle: nc,
          haystack: big,
          start: cursor,
          end: windowEnd,
        );
        if (r.score > bestSim) {
          bestSim = r.score;
          bestPos = r.pos;
          bestLen = r.len;
        }
      }

      if (bestSim >= similarityThreshold && bestPos >= 0) {
        final int matchEnd = bestPos + bestLen;
        final int secIdx = _sectionForOffset(idx.sectionNormStarts, bestPos);
        results.add(
          CueMatch(
            cueSentenceIndex: cue.sentenceIndex,
            sectionIndex: secIdx,
            normCharStart: bestPos - idx.sectionNormStarts[secIdx],
            normCharEnd: matchEnd - idx.sectionNormStarts[secIdx],
            score: bestSim,
          ),
        );
        _logHit(
          matched,
          cue,
          nc,
          big,
          bestPos,
          matchEnd,
          secIdx,
          idx.sectionNormStarts[secIdx],
          bestSim,
          ci == cues.length - 1,
        );
        cursor = matchEnd;
        matched++;
        consecutiveMisses = 0;
      } else {
        results.add(CueMatch.unmatched);
        consecutiveMisses++;
        debugPrint(
          '[sentenceAudioHighlight] matcher.miss sid=${cue.sentenceIndex} '
          'cue="${_clip(cue.text, 24)}" consecutive=$consecutiveMisses',
        );
      }
    }

    debugPrint(
      '[sentenceAudioHighlight] matcher done: matched=$matched/${cues.length} '
      'rate=${(matched * 100 / cues.length).toStringAsFixed(1)}% '
      'finalCursor=$cursor/$totalLen',
    );

    return MatchResult(
      matches: results,
      totalCues: cues.length,
      matchedCues: matched,
    );
  }

  static void _logHit(
    int hitIndex,
    AudioCue cue,
    String nc,
    String big,
    int found,
    int matchEnd,
    int secIdx,
    int secBase,
    double score,
    bool isLast,
  ) {
    if (hitIndex < 5 || isLast) {
      final String snippet = big.substring(found, matchEnd);
      debugPrint(
        '[sentenceAudioHighlight] matcher.hit#$hitIndex sid=${cue.sentenceIndex} '
        'sec=$secIdx ns=${found - secBase} '
        'score=${score.toStringAsFixed(3)} '
        'cue="${_clip(cue.text, 24)}" '
        'norm="${_clip(nc, 24)}" '
        'big="${_clip(snippet, 24)}"',
      );
    }
  }

  // ---------- Dice 系数（bigram sliding window） ----------

  /// Sliding-window Dice coefficient scan. For each candidate length in
  /// [needle.length-1, needle.length, needle.length+1], slides across
  /// [haystack] from [start] to [end], returning the best match.
  ///
  /// True O(window) per tryLen: incremental gram-map update AND incremental
  /// match counting (no full recount per position).
  static _SlidingDiceResult _slidingDice({
    required String needle,
    required String haystack,
    required int start,
    required int end,
  }) {
    double bestSim = 0;
    int bestPos = -1;
    int bestLen = needle.length;

    final int nLen = needle.length;
    final int n = (nLen < 5) ? 1 : 2;

    // Build needle gram map once (shared across all tryLen variants with same n).
    final Map<int, int> nGrams = <int, int>{};
    for (int i = 0; i <= nLen - n; i++) {
      final int key = n == 1
          ? needle.codeUnitAt(i)
          : (needle.codeUnitAt(i) << 16) | needle.codeUnitAt(i + 1);
      nGrams[key] = (nGrams[key] ?? 0) + 1;
    }
    for (final int tryLen in <int>[nLen, nLen - 1, nLen + 1]) {
      if (tryLen <= 0) continue;
      final int scanEnd = end - tryLen + 1;
      if (scanEnd <= start) continue;

      // Use same n decision as original _diceSimilarity: unigram if either < 5.
      final int tn = (nLen < 5 || tryLen < 5) ? 1 : 2;
      final int tNeedleGramCount = nLen - tn + 1;
      final int candidateGramCount = tryLen - tn + 1;
      if (tNeedleGramCount <= 0 || candidateGramCount <= 0) continue;
      final double denom = (tNeedleGramCount + candidateGramCount).toDouble();

      // If tn differs from n (edge case: needle=4, tryLen=5), rebuild needle grams.
      Map<int, int> effectiveNGrams;
      if (tn != n) {
        effectiveNGrams = <int, int>{};
        for (int i = 0; i <= nLen - tn; i++) {
          final int key = tn == 1
              ? needle.codeUnitAt(i)
              : (needle.codeUnitAt(i) << 16) | needle.codeUnitAt(i + 1);
          effectiveNGrams[key] = (effectiveNGrams[key] ?? 0) + 1;
        }
      } else {
        effectiveNGrams = nGrams;
      }

      // Build initial candidate gram map for position [start].
      final Map<int, int> cGrams = <int, int>{};
      for (int i = start; i <= start + tryLen - tn; i++) {
        final int key = tn == 1
            ? haystack.codeUnitAt(i)
            : (haystack.codeUnitAt(i) << 16) | haystack.codeUnitAt(i + 1);
        cGrams[key] = (cGrams[key] ?? 0) + 1;
      }

      // Compute initial match count (full scan, only once).
      int matches = 0;
      for (final MapEntry<int, int> e in cGrams.entries) {
        final int nCount = effectiveNGrams[e.key] ?? 0;
        if (nCount > 0) {
          matches += e.value < nCount ? e.value : nCount;
        }
      }

      double sim = (matches * 2) / denom;
      if (sim > bestSim) {
        bestSim = sim;
        bestPos = start;
        bestLen = tryLen;
      }
      if (bestSim >= 1.0) break;

      // Slide with incremental match update.
      for (int pos = start + 1; pos < scanEnd; pos++) {
        // Remove gram leaving the window (at pos-1).
        final int outIdx = pos - 1;
        final int outKey = tn == 1
            ? haystack.codeUnitAt(outIdx)
            : (haystack.codeUnitAt(outIdx) << 16) |
                haystack.codeUnitAt(outIdx + 1);
        final int outOldCount = cGrams[outKey]!;
        final int outNCount = effectiveNGrams[outKey] ?? 0;
        // If this gram was contributing to matches, check if removing reduces it.
        if (outNCount > 0 && outOldCount <= outNCount) {
          matches--;
        }
        if (outOldCount <= 1) {
          cGrams.remove(outKey);
        } else {
          cGrams[outKey] = outOldCount - 1;
        }

        // Add gram entering the window (at pos + tryLen - tn).
        final int inIdx = pos + tryLen - tn;
        final int inKey = tn == 1
            ? haystack.codeUnitAt(inIdx)
            : (haystack.codeUnitAt(inIdx) << 16) |
                haystack.codeUnitAt(inIdx + 1);
        final int inOldCount = cGrams[inKey] ?? 0;
        final int inNCount = effectiveNGrams[inKey] ?? 0;
        // If adding this gram brings the candidate count to within needle range.
        if (inNCount > 0 && inOldCount < inNCount) {
          matches++;
        }
        cGrams[inKey] = inOldCount + 1;

        sim = (matches * 2) / denom;
        if (sim > bestSim) {
          bestSim = sim;
          bestPos = pos;
          bestLen = tryLen;
        }
        if (bestSim >= 1.0) break;
      }
      if (bestSim >= 1.0) break;
    }

    return _SlidingDiceResult(bestSim, bestPos, bestLen);
  }

  // ---------- 起点检测 ----------

  /// 前 [defaultProbeCount] 条 cue（跳过 `＊` 开头与短于 [defaultProbeMinLen] 的）
  /// 各自在全书找候选位置——精确匹配取全部出现（上限几处），精确失败则做一次全书
  /// 滚动 Dice，≥ [similarityThreshold] 才算——然后选**被最多条 cue 佐证**的位置：
  /// 候选 p 的支持数 = 有候选落在 `[p, p + startClusterSpan]` 内的 cue 条数，取最大，
  /// 同分取最早。任何候选若其后剩余正文不足 cue 总长 × [startMinRemainingRatio]
  /// 则淘汰（BUG：ASR 片头的「株式会社KADOKAWA」只在书尾版权页精确命中，旧实现
  /// 「任一条精确命中的最小偏移」就把游标钉到全书末尾，之后 8000 条 cue 全 miss、
  /// 匹配率 0%；主循环的恢复只会向前 indexOf，回不来）。全部 miss 回到 0。
  ///
  /// 全书模糊扫描的代价：每条 O(全书长度)，最多 24 条，13 万字的书约几十毫秒，
  /// 且本函数只在导入时跑一次（在 isolate 里）。
  static int _findStart(
    String big,
    List<AudioCue> cues,
    double similarityThreshold, [
    List<String>? preNormCueTexts,
  ]) {
    final int limit =
        cues.length < defaultProbeCount ? cues.length : defaultProbeCount;
    // 每条 cue 的候选起点（去重）。
    final List<List<int>> perCue = <List<int>>[];
    int totalCueLen = 0;
    for (int i = 0; i < cues.length; i++) {
      totalCueLen += preNormCueTexts != null
          ? preNormCueTexts[i].length
          : AudioTextNormalizer.normalize(cues[i].text).length;
    }
    for (int i = 0; i < limit; i++) {
      final String raw = cues[i].text;
      if (raw.startsWith('＊') || raw.startsWith('*')) {
        continue;
      }
      final String nc = preNormCueTexts != null
          ? preNormCueTexts[i]
          : AudioTextNormalizer.normalize(raw);
      if (nc.length < defaultProbeMinLen) {
        continue;
      }
      final List<int> found = <int>[];
      int from = 0;
      while (found.length < 8) {
        final int at = big.indexOf(nc, from);
        if (at < 0) break;
        found.add(at);
        from = at + 1;
      }
      if (found.isEmpty) {
        final _SlidingDiceResult r = _slidingDice(
          needle: nc,
          haystack: big,
          start: 0,
          end: big.length,
        );
        if (r.pos >= 0 && r.score >= similarityThreshold) found.add(r.pos);
      }
      if (found.isNotEmpty) perCue.add(found);
    }
    if (perCue.isEmpty) return 0;

    // 余量检查：起点之后剩下的正文得装得下音频。
    final int minRemaining = (totalCueLen * startMinRemainingRatio).ceil();
    final List<int> candidates = <int>[
      for (final List<int> f in perCue)
        for (final int p in f)
          if (big.length - p >= minRemaining) p,
    ]..sort();
    if (candidates.isEmpty) return 0;

    int bestPos = candidates.first;
    int bestSupport = -1;
    for (final int p in candidates) {
      int support = 0;
      for (final List<int> f in perCue) {
        if (f.any((int q) => q >= p && q <= p + startClusterSpan)) support++;
      }
      if (support > bestSupport) {
        bestSupport = support;
        bestPos = p;
      }
    }
    return bestPos;
  }

  static String _clip(String s, int n) {
    final String r = s.replaceAll('\n', '\\n').replaceAll('\r', '\\r');
    return r.length <= n ? r : '${r.substring(0, n)}…';
  }

  // ---------- index ----------

  static _Index _buildIndex(List<EpubSection> sections) {
    final StringBuffer buf = StringBuffer();
    final List<int> normStarts = <int>[];
    for (final EpubSection s in sections) {
      normStarts.add(buf.length);
      AudioTextNormalizer.appendNormalized(buf, s.text);
    }
    return _Index(buf.toString(), normStarts);
  }

  static int _sectionForOffset(List<int> starts, int offset) {
    int lo = 0;
    int hi = starts.length - 1;
    int ans = 0;
    while (lo <= hi) {
      final int mid = (lo + hi) >> 1;
      if (starts[mid] <= offset) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}

class _SlidingDiceResult {
  const _SlidingDiceResult(this.score, this.pos, this.len);

  final double score;
  final int pos;
  final int len;
}

class _Index {
  const _Index(this.normText, this.sectionNormStarts);

  final String normText;
  final List<int> sectionNormStarts;
}

class _MatchRequest {
  const _MatchRequest({
    required this.sections,
    required this.cueTexts,
    required this.cueIndexes,
    required this.searchWindow,
    required this.similarityThreshold,
    required this.maxConsecutiveMisses,
  });

  final List<EpubSection> sections;
  final List<String> cueTexts;
  final List<int> cueIndexes;
  final int searchWindow;
  final double similarityThreshold;
  final int maxConsecutiveMisses;
}

MatchResult _matchEntrypoint(_MatchRequest req) {
  final List<AudioCue> cues = _rebuildCues(req.cueTexts, req.cueIndexes);
  if (cues.isEmpty) {
    return const MatchResult(
      matches: <CueMatch>[],
      totalCues: 0,
      matchedCues: 0,
    );
  }
  if (req.sections.isEmpty) {
    return MatchResult(
      matches: List<CueMatch>.filled(cues.length, CueMatch.unmatched),
      totalCues: cues.length,
      matchedCues: 0,
    );
  }
  final List<String> normCueTexts = <String>[
    for (final String t in req.cueTexts) AudioTextNormalizer.normalize(t),
  ];
  return EpubSrtMatcher._matchCore(
    idx: EpubSrtMatcher._buildIndex(req.sections),
    sections: req.sections,
    cues: cues,
    searchWindow: req.searchWindow,
    similarityThreshold: req.similarityThreshold,
    maxConsecutiveMisses: req.maxConsecutiveMisses,
    preNormCueTexts: normCueTexts,
  );
}

/// [EpubSrtMatcher.probeInIsolate] 的结果。
class ProbeResult {
  const ProbeResult({required this.perWindow, this.bestResult});

  /// window（字符数） → matchRate（0..1）。
  final Map<int, double> perWindow;

  /// 最优 window 跑出的完整匹配结果，调用方可直接使用而无需再跑一遍。
  final MatchResult? bestResult;

  /// 取命中率最高者；并列时取窗口较小的一档（更抗短 cue 噪声）。
  /// perWindow 为空返回 null。
  MapEntry<int, double>? get best {
    MapEntry<int, double>? top;
    for (final MapEntry<int, double> e in perWindow.entries) {
      if (top == null ||
          e.value > top.value + 1e-9 ||
          (e.value > top.value - 1e-9 && e.key < top.key)) {
        top = e;
      }
    }
    return top;
  }
}

class _ProbeRequest {
  const _ProbeRequest({
    required this.sections,
    required this.cueTexts,
    required this.cueIndexes,
    required this.windows,
    required this.similarityThreshold,
    required this.maxConsecutiveMisses,
  });

  final List<EpubSection> sections;
  final List<String> cueTexts;
  final List<int> cueIndexes;
  final List<int> windows;
  final double similarityThreshold;
  final int maxConsecutiveMisses;
}

ProbeResult _probeEntrypoint(_ProbeRequest req) {
  final Map<int, double> map = <int, double>{};
  int bestWindow = req.windows.first;
  double bestRate = -1;
  MatchResult? bestResult;

  final _Index idx = EpubSrtMatcher._buildIndex(req.sections);
  final List<String> normCueTexts = <String>[
    for (final String t in req.cueTexts) AudioTextNormalizer.normalize(t),
  ];

  for (final int w in req.windows) {
    final List<AudioCue> cues = _rebuildCues(req.cueTexts, req.cueIndexes);
    final MatchResult r = EpubSrtMatcher._matchCore(
      idx: idx,
      sections: req.sections,
      cues: cues,
      searchWindow: w,
      similarityThreshold: req.similarityThreshold,
      maxConsecutiveMisses: req.maxConsecutiveMisses,
      preNormCueTexts: normCueTexts,
    );
    map[w] = r.matchRate;
    if (r.matchRate > bestRate + 1e-9 ||
        (r.matchRate > bestRate - 1e-9 && w < bestWindow)) {
      bestRate = r.matchRate;
      bestWindow = w;
      bestResult = r;
    }
  }
  return ProbeResult(perWindow: map, bestResult: bestResult);
}

List<AudioCue> _rebuildCues(List<String> texts, List<int> indexes) {
  return <AudioCue>[
    for (int i = 0; i < texts.length; i++)
      (AudioCue()
        ..bookKey = ''
        ..chapterHref = ''
        ..sentenceIndex = indexes[i]
        ..textFragmentId = ''
        ..text = texts[i]
        ..startMs = 0
        ..endMs = 0
        ..audioFileIndex = 0),
  ];
}
