import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart';

import 'anchor_gap_filler.dart';
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
    this.rubies = const <EpubRubySpan>[],
  });

  final int index;
  final String href;
  final String text;

  /// [text] 里每处 ruby 的基底区间与读音（按出现顺序、互不重叠）。匹配器据此
  /// 另建一条**读音轨**：听写かな（うらやましい）对正文漢字（羨ましい）在
  /// 基底轨上零重叠，在读音轨上却是精确子串。没有 ruby 的书为空，行为与
  /// 只有基底轨时逐字节相同。
  final List<EpubRubySpan> rubies;
}

/// 一处 ruby：基底在 [EpubSection.text] 里的 UTF-16 码元区间 `[start, end)`
/// 与读音（原文，匹配前再归一化）。
class EpubRubySpan {
  const EpubRubySpan({
    required this.start,
    required this.end,
    required this.reading,
  });

  final int start;
  final int end;
  final String reading;
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
    this.gapFill,
  });

  final List<CueMatch> matches;
  final int totalCues;
  final int matchedCues;

  /// 锚点间隙回填（[AnchorGapFiller.fill]）的统计；第一遍结果上为 null。
  /// 回填跳过/放弃了哪些串、有没有因不变式退回，都从这里看。
  final GapFillStats? gapFill;

  double get matchRate => totalCues == 0 ? 0.0 : matchedCues / totalCues;
}

/// EPUB↔字幕匹配器，移植自 ttu-whispersync 的 Dice 系数模糊匹配。
///
/// 算法：
/// 1. 章节文本拼成一串 `big`，同时记录每章在 `big` 里的起点。
/// 2. 规范化用**白名单**：只保留 假名 / 汉字 / CJK 扩展 A / ASCII & 全角字母
///    数字 / 半角假名。其它（句读、引号、`＊` 叙述标记、空白、ruby 注音
///    剥完后的残留空格等）一律扔掉。
/// 3. **起点检测**：取前 [defaultProbeCount] 条探测 cue（跳过以 `＊` 开头的
///    旁白 / 标题 cue 与规范化后 < [defaultProbeMinLen] 字的短 cue），在全书做精确
///    `indexOf`（+ 模糊兜底），选被最多条探测 cue 佐证的簇（BUG-2147），再收敛到
///    簇内按 cue 序单调递增的那条命中链的首处（见 [_clusterAnchor]）。
/// 4. **主循环**（移植自 ttu-whispersync Match.svelte）：
///    a. 快速通道：精确 `indexOf` 命中 → score=1.0，cursor 推进。
///    b. 模糊兜底：在 `[cursor, cursor+searchWindow]` 内单次 Dice 滑窗扫描，
///       取最高位置；达到 [similarityThreshold] 则接受。**仅长 cue
///       （规范化后 >= [defaultProbeMinLen]）走模糊**；更短的 cue 只接受
///       精确子串命中，避免高频短虚词（うん/はい）的 unigram Dice 误判
///       抬高匹配率（TODO-906）。
///    c. 恢复机制：连续 miss 达 [maxConsecutiveMisses] 时做一次恢复扫描——与起点
///       检测同一套「聚簇佐证」：从当前 cue 起收集 [defaultProbeCount] 条探测 cue
///       在全书找候选，取被最多条 cue 佐证的位置，至少 [recoverMinSupport] 条才
///       搬游标（同分优先游标之后最近处；佐证更多时允许回退）。cursor 不做逐字
///       偏移重试（O(attempts×window) 太慢），只靠恢复扫描跳过不匹配的段落。
///       旧实现是「单条 cue 在 `[cursor..]` 做一次 `indexOf`」：ASR 片头的登场人物
///       页（不在正文里）攒满 20 次 miss 后，「大野アシュリー」在正文里第一次出现
///       是第 18 节，游标就被钉到那里；之后每次恢复都只会再往后跳、永不回头，
///       整本 4719 条 cue 只命中 79 条（『妹さえいればいい。』第 2 卷）。
class EpubSrtMatcher {
  static const int defaultSearchWindow = 200;
  static const int defaultProbeCount = 24;

  /// 恢复扫描搬动游标所需的最少佐证 cue 数：单条精确命中在 8 万字里随处可撞，
  /// 三条 ≥6 字的 cue 落在同一 [startClusterSpan] 内才算找到了正文。
  static const int recoverMinSupport = 3;

  /// 恢复扫描从当前 cue 起最多往后扫这么多条来凑探测 cue（短 cue / `＊` 不算）。
  static const int recoverScanLimit = defaultProbeCount * 3;

  /// 恢复扫描里精确失败后允许做全书模糊扫描的探测 cue 上限（每条 O(全书)，
  /// 起点检测只跑一次不设限，恢复每 [defaultMaxConsecutiveMisses] 次 miss 就可能
  /// 跑一次，得封顶）。
  static const int recoverMaxFuzzyProbes = 8;

  /// 整次匹配里恢复扫描累计允许的全书模糊扫描次数。每次尝试封顶
  /// [recoverMaxFuzzyProbes] 只兜住单次；选错卷 EPUB（全书零命中）时每 20 条 cue
  /// 就尝试一次、每次 8 条全书 Dice，4700 条 cue 的书单遍实测 58 s（旧实现 2.6 s），
  /// app 侧三档窗口 + isolate 复跑共 4 遍。配对正确的书只在音频独有段落触发恢复，
  /// 64 次足够；用完后恢复只靠精确命中。
  static const int recoverFuzzyBudgetTotal = recoverMaxFuzzyProbes * 8;

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

  /// 前一条 cue 的尾巴允许被下一条「吃回去」的最大字数（BUG-2204）。ASR 字幕的
  /// 切句边界会漂：前句文本多带了下一句的首字（无職転生 21：「…高い所。と」+
  /// 「とはいえ、」），命中后游标已越过下一句的真实起点，下一句在游标后找不到就
  /// 撞上远处的同前缀句（155 字外的第二个「とはいえ、」），夹在中间的十几句全部
  /// miss、播放时视口跳到下一页。搜索起点因此允许回退到 `cursor - 本值`（但不越过
  /// 前一条命中的起点），命中在游标之前时把前一条的终点裁到本条起点。
  static const int cueTailOverlap = 4;

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
    return Isolate.run(() => _matchEntrypoint(req));
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
    return Isolate.run(() => _probeEntrypoint(req));
  }

  /// [probeInIsolate] 的同步版：在当前 isolate 里对多档 window 各跑一遍
  /// [match]（共用一份归一化索引），返回命中率最高的那档。测试 / 小数据场景，
  /// 或已经身在后台 isolate 时（`EpubCueMatcher.probeInIsolate` 的入口函数）用。
  static ProbeResult probe({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required List<int> windows,
    double similarityThreshold = defaultSimilarityThreshold,
    int maxConsecutiveMisses = defaultMaxConsecutiveMisses,
  }) {
    final Map<int, double> map = <int, double>{};
    int bestWindow = windows.first;
    double bestRate = -1;
    MatchResult? bestResult;

    final _Index idx = _buildIndex(sections);
    final List<String> normCueTexts = <String>[
      for (final AudioCue c in cues) AudioTextNormalizer.normalize(c.text),
    ];

    for (final int w in windows) {
      final MatchResult r = _matchCore(
        idx: idx,
        sections: sections,
        cues: cues,
        searchWindow: w,
        similarityThreshold: similarityThreshold,
        maxConsecutiveMisses: maxConsecutiveMisses,
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
    fushiDebugPrint(
      '[sentenceAudioHighlight] matcher: sections=${sections.length} '
      'totalNormLen=$totalLen cues=${cues.length} startCursor=$start '
      'threshold=$similarityThreshold',
    );
    for (int si = 0; si < sections.length; si++) {
      final int s0 = idx.sectionNormStarts[si];
      final int s1 = (si + 1 < sections.length)
          ? idx.sectionNormStarts[si + 1]
          : totalLen;
      fushiDebugPrint(
        '[sentenceAudioHighlight] matcher.section[$si] href="${sections[si].href}" '
        'normStart=$s0 normLen=${s1 - s0}',
      );
    }

    final List<CueMatch> results = <CueMatch>[];
    int cursor = start;
    int matched = 0;
    int consecutiveMisses = 0;
    final _FuzzyBudget recoverFuzzyBudget = _FuzzyBudget(
      recoverFuzzyBudgetTotal,
    );
    // 最近一次命中：results 下标与全书绝对起点（尾巴回吃 / 裁剪用，BUG-2204）。
    int lastHitResult = -1;
    int lastHitAbsStart = -1;

    /// 本条在游标之前 [found] 处命中：把前一条的终点裁到 [found]（它多吃的尾巴
    /// 还给本条），高亮 range 才不重叠。
    void trimPreviousTo(int found) {
      if (lastHitResult < 0 || found >= cursor) return;
      final CueMatch prev = results[lastHitResult];
      final int prevSectionStart = idx.sectionNormStarts[prev.sectionIndex];
      final int newEnd = found - prevSectionStart;
      if (newEnd <= prev.normCharStart) return;
      results[lastHitResult] = CueMatch(
        cueSentenceIndex: prev.cueSentenceIndex,
        sectionIndex: prev.sectionIndex,
        normCharStart: prev.normCharStart,
        normCharEnd: newEnd,
        score: prev.score,
      );
    }

    for (int ci = 0; ci < cues.length; ci++) {
      final AudioCue cue = cues[ci];
      final String nc = preNormCueTexts != null
          ? preNormCueTexts[ci]
          : AudioTextNormalizer.normalize(cue.text);
      if (nc.isEmpty) {
        results.add(CueMatch.unmatched);
        continue;
      }

      // --- 恢复机制：连续 miss 过多时用聚簇佐证在全书重锚 ---
      // 找不到够佐证的位置就原地不动，再攒 [maxConsecutiveMisses] 次 miss 才
      // 试下一回（每次尝试最多 O(探测数 × 全书)，不能每条 miss 都跑）。
      if (consecutiveMisses >= maxConsecutiveMisses) {
        consecutiveMisses = 0;
        final _ClusterAnchor? anchor = _clusterAnchor(
          big: big,
          cues: cues,
          preNormCueTexts: preNormCueTexts,
          fromCue: ci,
          scanLimit: recoverScanLimit,
          maxFuzzyProbes: recoverMaxFuzzyProbes,
          fuzzyBudget: recoverFuzzyBudget,
          similarityThreshold: similarityThreshold,
          // 不做余量检查：剩余音频里可能整段都不在书里（片尾花絮），书尾最后
          // 几句会被「装不下」误杀；恢复靠佐证条数守门。
          minRemainingRatio: 0,
          preferFrom: cursor,
        );
        // 往前搬：够 [recoverMinSupport] 条佐证，或（至少两条且）所有有候选的
        // 探测 cue 都落在这一簇**且每条在全书都只精确出现一次**——书尾只剩两三条
        // 正文 cue 时凑不满三条，但它们彼此一致、没有反证；候选只收前 8 处出现，
        // 两条泛用短语在全书某处 3000 字内共现几乎必然，不要求唯一就会在长段人物
        // 卡 / 广告后前跳到那个假簇。单条撞中一律不搬（泛用短语 / 版权页出版社
        // 名）；往回搬只认前者。
        if (anchor != null &&
            (anchor.support >= recoverMinSupport ||
                (anchor.pos >= cursor &&
                    anchor.hittingProbes >= 2 &&
                    anchor.support == anchor.hittingProbes &&
                    anchor.allExactUnique))) {
          fushiDebugPrint(
            '[sentenceAudioHighlight] matcher.recover cursor=$cursor -> '
            '${anchor.pos} support=${anchor.support} '
            'cue="${_clip(cue.text, 24)}"',
          );
          cursor = anchor.pos;
          // 游标可能回退到上一条命中之前：尾巴回吃 / 裁剪的参照作废。
          lastHitResult = -1;
          lastHitAbsStart = -1;
        }
      }

      // --- 快速通道：精确 indexOf ---
      final int windowEnd = (cursor + searchWindow).clamp(0, totalLen);
      // 读音轨只给 ≥ [defaultProbeMinLen] 的 cue 用：全假名的读音轨里三四个字
      // 的串随处可撞（与模糊通道限长同一理由，TODO-906）。
      final _ReadingTrack? reading = nc.length >= defaultProbeMinLen
          ? idx.reading
          : null;
      // BUG-2204：搜索起点允许回到游标前 [cueTailOverlap] 字（不越过前一条命中的
      // 起点），让被前一条多吃掉首字的本句仍能在真实位置命中。
      final int searchFrom = lastHitResult >= 0
          ? (cursor - cueTailOverlap > lastHitAbsStart + 1
                ? cursor - cueTailOverlap
                : lastHitAbsStart + 1)
          : cursor;
      if (windowEnd - searchFrom >= nc.length) {
        int found = big.indexOf(nc, searchFrom);
        int matchEnd = found + nc.length;
        // 超短 cue（≤ [shortCueMaxLen] 字）的精确命中只认紧邻游标的位置：一两个
        // 字在 200 字窗口里几乎必然能撞上（「一」「え」「ああ」），撞上就把游标
        // 拽走，后面整段正文全 miss。2026-09-05 无職転生 01 真机对照：ASR 字幕的
        // 卷号 cue「一」命中了第七节「第一章」，游标越过第六节题词，12 条 cue
        // 连锁错过（SubPlz 那份写作「＊1」，规范化后是数字 1 才侥幸没撞）。
        final bool tooFarForShortCue =
            nc.length <= shortCueMaxLen && found > cursor + shortCueMaxAdvance;
        bool hit = found >= 0 && matchEnd <= windowEnd && !tooFarForShortCue;
        if (!hit && reading != null) {
          // 基底轨没有精确命中：同一窗口在读音轨再找一次，命中换算回基底偏移。
          final int rFound = reading.text.indexOf(
            nc,
            reading.fromBase[searchFrom],
          );
          if (rFound >= 0 &&
              rFound + nc.length <= reading.fromBase[windowEnd]) {
            found = reading.toBaseStart[rFound];
            matchEnd = reading.toBaseEnd[rFound + nc.length];
            hit = matchEnd > found;
          }
        }
        if (hit) {
          final int secIdx = _sectionForOffset(idx.sectionNormStarts, found);
          trimPreviousTo(found);
          lastHitResult = results.length;
          lastHitAbsStart = found;
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
          start: searchFrom,
          end: windowEnd,
        );
        if (r.score > bestSim) {
          bestSim = r.score;
          bestPos = r.pos;
          bestLen = r.len;
        }
        // 基底轨够不到阈值时在读音轨同一窗口再扫一遍，取更高分者；区间换算回
        // 基底轨（整个 ruby 为原子）。
        if (bestSim < similarityThreshold && reading != null) {
          final int rStart = reading.fromBase[searchFrom];
          final int rEnd = reading.fromBase[windowEnd];
          if (rEnd - rStart >= nc.length) {
            final _SlidingDiceResult rr = _slidingDice(
              needle: nc,
              haystack: reading.text,
              start: rStart,
              end: rEnd,
            );
            if (rr.score > bestSim && rr.pos >= 0) {
              final int b0 = reading.toBaseStart[rr.pos];
              final int b1 = reading.toBaseEnd[rr.pos + rr.len];
              if (b1 > b0) {
                bestSim = rr.score;
                bestPos = b0;
                bestLen = b1 - b0;
              }
            }
          }
        }
      }

      if (bestSim >= similarityThreshold && bestPos >= 0) {
        final int matchEnd = bestPos + bestLen;
        final int secIdx = _sectionForOffset(idx.sectionNormStarts, bestPos);
        trimPreviousTo(bestPos);
        lastHitResult = results.length;
        lastHitAbsStart = bestPos;
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
        fushiDebugPrint(
          '[sentenceAudioHighlight] matcher.miss sid=${cue.sentenceIndex} '
          'cue="${_clip(cue.text, 24)}" consecutive=$consecutiveMisses',
        );
      }
    }

    fushiDebugPrint(
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
      fushiDebugPrint(
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
    final _ClusterAnchor? anchor = _clusterAnchor(
      big: big,
      cues: cues,
      preNormCueTexts: preNormCueTexts,
      fromCue: 0,
      scanLimit: defaultProbeCount,
      maxFuzzyProbes: defaultProbeCount,
      fuzzyBudget: _FuzzyBudget(defaultProbeCount),
      similarityThreshold: similarityThreshold,
      minRemainingRatio: startMinRemainingRatio,
      preferFrom: null,
    );
    return anchor?.pos ?? 0;
  }

  /// 起点检测与恢复扫描共用的「聚簇佐证」：从 [fromCue] 起最多扫 [scanLimit] 条
  /// cue，凑 [defaultProbeCount] 条探测 cue（跳过 `＊` 开头与短于
  /// [defaultProbeMinLen] 的），每条在全书找候选（精确取全部出现、上限 8 处；精确
  /// 失败且模糊配额 [maxFuzzyProbes] 未用完则做一次全书滚动 Dice，≥
  /// [similarityThreshold] 才算）。候选 p 的支持数 = 有候选落在
  /// `[p, p + startClusterSpan]` 内的探测 cue 条数；余量不足（其后正文装不下
  /// [fromCue] 起的 cue 总长 × [startMinRemainingRatio]）的候选淘汰。
  ///
  /// 选法：支持数最大者；同分时 [preferFrom] 为 null（起点）取最早，否则优先
  /// `p >= preferFrom` 且离 [preferFrom] 最近——恢复时只有佐证**更多**的簇才会把
  /// 游标往回搬。返回的位置再收敛：簇内每条探测 cue 的命中按 cue 序排成
  /// (cue 序, 位置) 对，取**最长递增子序列**的首处——正文 cue 的命中天然按 cue 序
  /// 单调递增，簇内乱序的那条（cue 序靠前却命中在后：片头人名 / 泛用短语在正文
  /// 里的偶然出现）进不了链；「cue 序最靠前的探测 cue」会被这种撞中拽走，把簇里
  /// 其余二十几条真正文甩到游标之前。
  ///
  /// 一条探测 cue 都没有候选返回 null。[fuzzyBudget] 是调用方整次匹配级的全书
  /// 模糊扫描总预算（每次调用另受 [maxFuzzyProbes] 封顶）。
  static _ClusterAnchor? _clusterAnchor({
    required String big,
    required List<AudioCue> cues,
    required List<String>? preNormCueTexts,
    required int fromCue,
    required int scanLimit,
    required int maxFuzzyProbes,
    required _FuzzyBudget fuzzyBudget,
    required double similarityThreshold,
    required double minRemainingRatio,
    required int? preferFrom,
  }) {
    String norm(int i) => preNormCueTexts != null
        ? preNormCueTexts[i]
        : AudioTextNormalizer.normalize(cues[i].text);

    // 每条探测 cue 的候选位置（cue 序保持）；[perCueExactUnique] 同序，标记该
    // 条是否在全书恰好精确出现一次（模糊命中不算）。
    final List<List<int>> perCue = <List<int>>[];
    final List<bool> perCueExactUnique = <bool>[];
    int fuzzyUsed = 0;
    for (
      int i = fromCue;
      i < cues.length &&
          i - fromCue < scanLimit &&
          perCue.length < defaultProbeCount;
      i++
    ) {
      final String raw = cues[i].text;
      if (raw.startsWith('＊') || raw.startsWith('*')) {
        continue;
      }
      final String nc = norm(i);
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
      final bool exactUnique = found.length == 1;
      if (found.isEmpty &&
          fuzzyUsed < maxFuzzyProbes &&
          fuzzyBudget.remaining > 0) {
        fuzzyUsed++;
        fuzzyBudget.remaining--;
        final _SlidingDiceResult r = _slidingDice(
          needle: nc,
          haystack: big,
          start: 0,
          end: big.length,
        );
        if (r.pos >= 0 && r.score >= similarityThreshold) found.add(r.pos);
      }
      if (found.isNotEmpty) {
        perCue.add(found);
        perCueExactUnique.add(exactUnique);
      }
    }
    if (perCue.isEmpty) return null;

    // 余量检查：锚点之后剩下的正文得装得下剩余音频（[minRemainingRatio] 为 0
    // 时不查）。
    int minRemaining = 0;
    if (minRemainingRatio > 0) {
      int remainingCueLen = 0;
      for (int i = fromCue; i < cues.length; i++) {
        remainingCueLen += norm(i).length;
      }
      minRemaining = (remainingCueLen * minRemainingRatio).ceil();
    }
    // 淘汰后按探测 cue 分组保留（佐证计数与收敛都只看幸存候选：版权页那条精确
    // 命中不能再以「簇内 cue 序最靠前」的身份把收敛后的位置拖到书尾）。
    final List<List<int>> kept = <List<int>>[];
    final List<bool> keptExactUnique = <bool>[];
    for (int k = 0; k < perCue.length; k++) {
      final List<int> f = <int>[
        for (final int p in perCue[k])
          if (big.length - p >= minRemaining) p,
      ];
      if (f.isEmpty) continue;
      kept.add(f);
      keptExactUnique.add(perCueExactUnique[k]);
    }
    final List<int> candidates = <int>[for (final List<int> f in kept) ...f]
      ..sort();
    if (candidates.isEmpty) return null;

    int bestPos = candidates.first;
    int bestSupport = -1;
    for (final int p in candidates) {
      int support = 0;
      for (final List<int> f in kept) {
        if (f.any((int q) => q >= p && q <= p + startClusterSpan)) support++;
      }
      if (support > bestSupport) {
        bestSupport = support;
        bestPos = p;
      } else if (support == bestSupport &&
          preferFrom != null &&
          _closerAhead(preferFrom, p, bestPos)) {
        bestPos = p;
      }
    }

    // 收敛：簇内命中按 (cue 序, 位置) 取最长递增子序列，锚到链首。
    final int refined = _monotoneChainStart(
      kept,
      bestPos,
      bestPos + startClusterSpan,
    );
    if (refined >= 0) bestPos = refined;
    return _ClusterAnchor(
      bestPos,
      bestSupport,
      kept.length,
      allExactUnique: keptExactUnique.every((bool u) => u),
    );
  }

  /// 簇 `[from, to]` 内各探测 cue（[kept] 按 cue 序）的命中位置，按 cue 序与位置
  /// **同时**严格递增取最长子序列，返回链首位置；簇内没有命中返回 -1。
  /// 每条探测 cue 的多处命中都参与（同一条只能入链一次），探测 ≤ 24 条 × ≤ 8 处，
  /// O(n²) 足够。同长链取先枚举到的（位置更靠前）。
  static int _monotoneChainStart(List<List<int>> kept, int from, int to) {
    final List<(int, int)> items =
        <(int, int)>[
          for (int k = 0; k < kept.length; k++)
            for (final int q in kept[k])
              if (q >= from && q <= to) (k, q),
        ]..sort(((int, int) a, (int, int) b) {
          final int byCue = a.$1.compareTo(b.$1);
          return byCue != 0 ? byCue : a.$2.compareTo(b.$2);
        });
    if (items.isEmpty) return -1;
    final List<int> length = List<int>.filled(items.length, 1);
    final List<int> previous = List<int>.filled(items.length, -1);
    int bestEnd = 0;
    for (int j = 0; j < items.length; j++) {
      for (int i = 0; i < j; i++) {
        if (items[i].$1 < items[j].$1 &&
            items[i].$2 < items[j].$2 &&
            length[i] + 1 > length[j]) {
          length[j] = length[i] + 1;
          previous[j] = i;
        }
      }
      if (length[j] > length[bestEnd]) bestEnd = j;
    }
    int head = bestEnd;
    while (previous[head] >= 0) {
      head = previous[head];
    }
    return items[head].$2;
  }

  /// 同分候选取舍：[p] 是否比当前 [best] 更该选——先看是否在 [from] 之后，都在
  /// （或都不在）则取离 [from] 更近者。
  static bool _closerAhead(int from, int p, int best) {
    final bool pAhead = p >= from;
    final bool bestAhead = best >= from;
    if (pAhead != bestAhead) return pAhead;
    return (p - from).abs() < (best - from).abs();
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
    final String big = buf.toString();
    final bool anyRuby = sections.any((EpubSection s) => s.rubies.isNotEmpty);
    return _Index(
      big,
      normStarts,
      anyRuby ? _ReadingTrack.build(sections, normStarts, big.length) : null,
    );
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

/// [EpubSrtMatcher._clusterAnchor] 的结果：锚点在全书归一化串里的位置与佐证条数。
class _ClusterAnchor {
  const _ClusterAnchor(
    this.pos,
    this.support,
    this.hittingProbes, {
    required this.allExactUnique,
  });

  /// 收敛后的锚点（≥ 选出的簇起点）。
  final int pos;

  /// 落在选出的簇（收敛前的 `[簇起点, +startClusterSpan]`）内的探测 cue 条数。
  final int support;

  /// 在全书至少有一处候选（余量检查后）的探测 cue 条数；`support ==
  /// hittingProbes` 即没有任何探测 cue 指向别处。
  final int hittingProbes;

  /// 有候选的探测 cue 是否每条都在全书恰好精确出现一次（模糊命中不算）。
  final bool allExactUnique;
}

/// 整次匹配级的全书模糊扫描总预算（见 [EpubSrtMatcher.recoverFuzzyBudgetTotal]）。
class _FuzzyBudget {
  _FuzzyBudget(this.remaining);

  int remaining;
}

class _SlidingDiceResult {
  const _SlidingDiceResult(this.score, this.pos, this.len);

  final double score;
  final int pos;
  final int len;
}

class _Index {
  const _Index(this.normText, this.sectionNormStarts, this.reading);

  final String normText;
  final List<int> sectionNormStarts;

  /// 读音轨（任一章节带 ruby 时才有）。
  final _ReadingTrack? reading;
}

/// 读音轨：基底轨归一化文本里每处 ruby 的基底区间换成归一化读音后的全书串，
/// 以及两轨之间的偏移映射。命中永远换算回**基底轨**偏移再产出 [CueMatch]——
/// `fushi-cue://`、阅读器高亮、阅读位置、统计水位全建立在基底轨上，读音轨只
/// 用于判定命中。
///
/// 映射粒度是整个 ruby 区间：命中落在某处读音中间时，起点取该 ruby 基底起点、
/// 终点取其基底终点（一个词只有整词读音，不能按字符线性插值）。
class _ReadingTrack {
  const _ReadingTrack({
    required this.text,
    required this.toBaseStart,
    required this.toBaseEnd,
    required this.fromBase,
  });

  /// 读音轨归一化全书串。
  final String text;

  /// 读音轨位置 `p`（0..length）作为**起点**时对应的基底轨位置。
  final Int32List toBaseStart;

  /// 读音轨位置 `p`（0..length）作为**终点**时对应的基底轨位置。
  final Int32List toBaseEnd;

  /// 基底轨位置 `b`（0..baseLength）对应的读音轨位置（落在 ruby 基底中间的
  /// 位置映到该 ruby 读音起点，游标只会偏早不会跳过）。
  final Int32List fromBase;

  static _ReadingTrack build(
    List<EpubSection> sections,
    List<int> sectionNormStarts,
    int baseLength,
  ) {
    final StringBuffer buf = StringBuffer();
    final List<int> toStart = <int>[];
    final List<int> toEnd = <int>[];
    final Int32List fromBase = Int32List(baseLength + 1);
    for (int si = 0; si < sections.length; si++) {
      final EpubSection s = sections[si];
      final int baseOffset = sectionNormStarts[si];
      final NormalizedTextWithOffsets norm =
          AudioTextNormalizer.normalizeWithOffsets(s.text);
      // ruby 基底 → 基底轨归一化区间 [i, j)；基底里没有保留字符或读音归一化后
      // 为空的跳过。
      final List<int> spanStart = <int>[];
      final List<int> spanEnd = <int>[];
      final List<String> spanReading = <String>[];
      for (final EpubRubySpan r in s.rubies) {
        final String reading = AudioTextNormalizer.normalize(r.reading);
        if (reading.isEmpty || r.end <= r.start) continue;
        final int i = _lowerBound(norm.starts, r.start);
        int j = i;
        while (j < norm.ends.length && norm.ends[j] <= r.end) {
          j++;
        }
        if (j <= i) continue;
        if (spanStart.isNotEmpty && i < spanEnd.last) continue; // 重叠丢弃
        spanStart.add(i);
        spanEnd.add(j);
        spanReading.add(reading);
      }
      int b = 0;
      int k = 0;
      while (b < norm.text.length) {
        if (k < spanStart.length && b == spanStart[k]) {
          final int b0 = baseOffset + spanStart[k];
          final int b1 = baseOffset + spanEnd[k];
          final String reading = spanReading[k];
          final int r0 = buf.length;
          for (int q = 0; q < reading.length; q++) {
            toStart.add(b0);
            toEnd.add(q == 0 ? b0 : b1);
          }
          buf.write(reading);
          for (int bb = spanStart[k]; bb < spanEnd[k]; bb++) {
            fromBase[baseOffset + bb] = r0;
          }
          b = spanEnd[k];
          k++;
          continue;
        }
        toStart.add(baseOffset + b);
        toEnd.add(baseOffset + b);
        fromBase[baseOffset + b] = buf.length;
        buf.writeCharCode(norm.text.codeUnitAt(b));
        b++;
      }
    }
    toStart.add(baseLength);
    toEnd.add(baseLength);
    fromBase[baseLength] = buf.length;
    return _ReadingTrack(
      text: buf.toString(),
      toBaseStart: Int32List.fromList(toStart),
      toBaseEnd: Int32List.fromList(toEnd),
      fromBase: fromBase,
    );
  }

  /// 第一个 `>= value` 的下标（[sorted] 单调不减）。
  static int _lowerBound(List<int> sorted, int value) {
    int lo = 0;
    int hi = sorted.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (sorted[mid] < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
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
  return EpubSrtMatcher.probe(
    sections: req.sections,
    cues: _rebuildCues(req.cueTexts, req.cueIndexes),
    windows: req.windows,
    similarityThreshold: req.similarityThreshold,
    maxConsecutiveMisses: req.maxConsecutiveMisses,
  );
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
