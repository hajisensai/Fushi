import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';
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
///    簇内按 cue 序单调递增的那条命中链的首处（native `cluster_anchor`）。
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
///
/// 3~4 步（算法主体）只有一份实现：native/fushi_compute 的 `ffc_text_cue_match`
/// （Rust，`src/text.rs`），本类只做归一化 / 读音轨等数据准备与结果装配，调参常量
/// 仍以这里的 static const 为准、按调用传过去。原生库是硬依赖，缺库时抛
/// [FushiComputeUnavailableError]。
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

    final List<MatchResult> results = _matchWindows(
      idx: _buildIndex(sections),
      sections: sections,
      cues: cues,
      windows: windows,
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
      normCueTexts: <String>[
        for (final AudioCue c in cues) _normalizeForMatch(c.text),
      ],
    );
    for (int i = 0; i < windows.length; i++) {
      final int w = windows[i];
      final MatchResult r = results[i];
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

    return _matchWindows(
      idx: _buildIndex(sections),
      sections: sections,
      cues: cues,
      windows: <int>[searchWindow],
      similarityThreshold: similarityThreshold,
      maxConsecutiveMisses: maxConsecutiveMisses,
      normCueTexts: <String>[
        for (final AudioCue c in cues) _normalizeForMatch(c.text),
      ],
    ).single;
  }

  /// 每条聚簇探测 cue 在全书最多收集的精确出现处数。
  static const int maxExactHitsPerProbe = 8;

  /// 算法主体（起点检测 / 主循环 / 恢复扫描，见类注释）在
  /// native/fushi_compute `ffc_text_cue_match` 里，一次调用跑完 [windows] 各档
  /// （互不依赖，原生侧并行）。这里只把索引与归一化后的 cue 交过去、把结果装回
  /// [CueMatch]，并打诊断日志。
  static List<MatchResult> _matchWindows({
    required _Index idx,
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required List<int> windows,
    required double similarityThreshold,
    required int maxConsecutiveMisses,
    required List<String> normCueTexts,
  }) {
    final String big = idx.normText;
    if (cues.isEmpty || sections.isEmpty) {
      return <MatchResult>[
        for (final int _ in windows)
          MatchResult(
            matches: List<CueMatch>.filled(cues.length, CueMatch.unmatched),
            totalCues: cues.length,
            matchedCues: 0,
          ),
      ];
    }
    final Uint8List flags = Uint8List(cues.length);
    for (int i = 0; i < cues.length; i++) {
      final String raw = cues[i].text;
      if (raw.startsWith('＊') || raw.startsWith('*')) {
        flags[i] = kCueMatchFlagSkipProbe;
      }
    }
    final Int32List intParams = Int32List(CueMatchIntParam.count);
    intParams[CueMatchIntParam.probeCount] = defaultProbeCount;
    intParams[CueMatchIntParam.recoverMinSupport] = recoverMinSupport;
    intParams[CueMatchIntParam.recoverScanLimit] = recoverScanLimit;
    intParams[CueMatchIntParam.recoverMaxFuzzyProbes] = recoverMaxFuzzyProbes;
    intParams[CueMatchIntParam.recoverFuzzyBudgetTotal] =
        recoverFuzzyBudgetTotal;
    intParams[CueMatchIntParam.startClusterSpan] = startClusterSpan;
    intParams[CueMatchIntParam.probeMinLen] = defaultProbeMinLen;
    intParams[CueMatchIntParam.shortCueMaxLen] = shortCueMaxLen;
    intParams[CueMatchIntParam.shortCueMaxAdvance] = shortCueMaxAdvance;
    intParams[CueMatchIntParam.cueTailOverlap] = cueTailOverlap;
    intParams[CueMatchIntParam.maxExactHits] = maxExactHitsPerProbe;
    intParams[CueMatchIntParam.maxConsecutiveMisses] = maxConsecutiveMisses;
    final _ReadingTrack? reading = idx.reading;
    final List<CueMatchWindowResult> raw = FushiComputeText.instance.match(
      base: big,
      sectionStarts: Int32List.fromList(idx.sectionNormStarts),
      reading: reading == null
          ? null
          : CueMatchReadingTrack(
              text: reading.text,
              toBaseStart: reading.toBaseStart,
              toBaseEnd: reading.toBaseEnd,
              atomReadStart: reading.atomReadStart,
              atomReadEnd: reading.atomReadEnd,
              fromBase: reading.fromBase,
            ),
      cueTexts: normCueTexts,
      cueFlags: flags,
      windows: windows,
      intParams: intParams,
      threshold: similarityThreshold,
      startMinRemainingRatio: startMinRemainingRatio,
    );

    final List<MatchResult> out = <MatchResult>[];
    for (int wi = 0; wi < windows.length; wi++) {
      final CueMatchWindowResult r = raw[wi];
      final List<CueMatch> matches = <CueMatch>[
        for (int ci = 0; ci < cues.length; ci++)
          r.section[ci] < 0
              ? CueMatch.unmatched
              : CueMatch(
                  cueSentenceIndex: cues[ci].sentenceIndex,
                  sectionIndex: r.section[ci],
                  normCharStart: r.start[ci],
                  normCharEnd: r.end[ci],
                  score: r.score[ci],
                ),
      ];
      _logWindow(
        idx: idx,
        sections: sections,
        cues: cues,
        normCueTexts: normCueTexts,
        window: windows[wi],
        similarityThreshold: similarityThreshold,
        raw: r,
        matches: matches,
      );
      out.add(
        MatchResult(
          matches: matches,
          totalCues: cues.length,
          matchedCues: r.matched,
        ),
      );
    }
    return out;
  }

  static void _logWindow({
    required _Index idx,
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required List<String> normCueTexts,
    required int window,
    required double similarityThreshold,
    required CueMatchWindowResult raw,
    required List<CueMatch> matches,
  }) {
    final String big = idx.normText;
    final int totalLen = big.length;
    fushiDebugPrint(
      '[sentenceAudioHighlight] matcher: sections=${sections.length} '
      'totalNormLen=$totalLen cues=${cues.length} startCursor=${raw.startCursor} '
      'window=$window threshold=$similarityThreshold',
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
    for (final (int ci, int from, int to, int support) in raw.recoveries) {
      fushiDebugPrint(
        '[sentenceAudioHighlight] matcher.recover cursor=$from -> $to '
        'support=$support cue="${_clip(cues[ci].text, 24)}"',
      );
    }
    int hitIndex = 0;
    int lastHit = -1;
    for (int ci = 0; ci < matches.length; ci++) {
      if (matches[ci].matched) lastHit = ci;
    }
    for (int ci = 0; ci < matches.length; ci++) {
      final CueMatch m = matches[ci];
      if (!m.matched) continue;
      if (hitIndex < 5 || ci == lastHit) {
        final int secBase = idx.sectionNormStarts[m.sectionIndex];
        final String snippet = big.substring(
          secBase + m.normCharStart,
          secBase + m.normCharEnd,
        );
        fushiDebugPrint(
          '[sentenceAudioHighlight] matcher.hit#$hitIndex '
          'sid=${m.cueSentenceIndex} sec=${m.sectionIndex} '
          'ns=${m.normCharStart} score=${m.score.toStringAsFixed(3)} '
          'cue="${_clip(cues[ci].text, 24)}" '
          'norm="${_clip(normCueTexts[ci], 24)}" '
          'big="${_clip(snippet, 24)}"',
        );
      }
      hitIndex++;
    }
    fushiDebugPrint(
      '[sentenceAudioHighlight] matcher done: matched=${raw.matched}/${cues.length} '
      'rate=${(raw.matched * 100 / cues.length).toStringAsFixed(1)}% '
      'finalCursor=${raw.finalCursor}/$totalLen',
    );
  }

  static String _clip(String s, int n) {
    final String r = s.replaceAll('\n', '\\n').replaceAll('\r', '\\r');
    return r.length <= n ? r : '${r.substring(0, n)}…';
  }

  // ---------- index ----------

  /// 匹配专用归一化：[AudioTextNormalizer.normalize] 之后再把小書き仮名折成並字
  /// （ぁぃぅぇぉっゃゅょゎゕゖ → あいうえおつやゆよわかけ）。
  ///
  /// 传统排版的 ruby 不用小书き仮名（BUG-2928：『やはり俺の青春ラブコメはまちがって
  /// いる。』的 rt 是「オイレン・シルフイード」「きようがく」），ASR 却总吐现代
  /// 写法「シルフィード」「きょうがく」——读音轨上真位置只拿到 0.78 分，过不了
  /// 0.8 的阈值；bigram Dice 不看顺序，窗口里紧挨着的两处同读音 ruby 拼出的
  /// 「ーど|おいれんしるふ」反而 0.82，游标越过中间七句正文，VN 随 cue 跳过三段。
  ///
  /// 只在匹配器内部折（全书索引两条轨 + cue 两侧同一口径）：逐码元 1:1，偏移不变，
  /// [CueMatch] 照旧落在基底轨坐标上。共享的 [AudioTextNormalizer] 不动——它与阅读器
  /// JS 的 `foldCodePoint` 逐值对齐，那条链路不需要这层宽松。
  static String _normalizeForMatch(String s) =>
      _foldSmallKana(AudioTextNormalizer.normalize(s));

  static String _foldSmallKana(String s) {
    StringBuffer? out;
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      final int f = _foldSmallKanaUnit(c);
      if (f != c && out == null) {
        out = StringBuffer(s.substring(0, i));
      }
      out?.writeCharCode(f);
    }
    return out?.toString() ?? s;
  }

  /// 归一化后（片假名已折成平假名）的小書き仮名 → 並字；其余原样。
  static int _foldSmallKanaUnit(int c) {
    switch (c) {
      case 0x3041: // ぁ
      case 0x3043: // ぃ
      case 0x3045: // ぅ
      case 0x3047: // ぇ
      case 0x3049: // ぉ
      case 0x3063: // っ
      case 0x3083: // ゃ
      case 0x3085: // ゅ
      case 0x3087: // ょ
      case 0x308E: // ゎ
        return c + 1;
      case 0x3095: // ゕ
        return 0x304B; // か
      case 0x3096: // ゖ
        return 0x3051; // け
      default:
        return c;
    }
  }

  static _Index _buildIndex(List<EpubSection> sections) {
    final StringBuffer buf = StringBuffer();
    final List<int> normStarts = <int>[];
    for (final EpubSection s in sections) {
      normStarts.add(buf.length);
      AudioTextNormalizer.appendNormalized(buf, s.text);
    }
    final String big = _foldSmallKana(buf.toString());
    final bool anyRuby = sections.any((EpubSection s) => s.rubies.isNotEmpty);
    return _Index(
      big,
      normStarts,
      anyRuby ? _ReadingTrack.build(sections, normStarts, big.length) : null,
    );
  }
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
    required this.atomReadStart,
    required this.atomReadEnd,
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

  /// 读音轨位置 `p` 所在原子（一整段 ruby 读音，或一个非 ruby 字符）在读音轨上的
  /// 区间 `[atomReadStart[p], atomReadEnd[p])`；`atomReadStart[p] < p` 即 `p` 落在
  /// 某段读音中间。
  final Int32List atomReadStart;
  final Int32List atomReadEnd;

  static _ReadingTrack build(
    List<EpubSection> sections,
    List<int> sectionNormStarts,
    int baseLength,
  ) {
    final StringBuffer buf = StringBuffer();
    final List<int> toStart = <int>[];
    final List<int> toEnd = <int>[];
    final List<int> atomStart = <int>[];
    final List<int> atomEnd = <int>[];
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
        final String reading = EpubSrtMatcher._normalizeForMatch(r.reading);
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
            atomStart.add(r0);
            atomEnd.add(r0 + reading.length);
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
        atomStart.add(buf.length);
        atomEnd.add(buf.length + 1);
        fromBase[baseOffset + b] = buf.length;
        buf.writeCharCode(
          EpubSrtMatcher._foldSmallKanaUnit(norm.text.codeUnitAt(b)),
        );
        b++;
      }
    }
    toStart.add(baseLength);
    toEnd.add(baseLength);
    atomStart.add(buf.length);
    atomEnd.add(buf.length);
    fromBase[baseLength] = buf.length;
    return _ReadingTrack(
      text: buf.toString(),
      toBaseStart: Int32List.fromList(toStart),
      toBaseEnd: Int32List.fromList(toEnd),
      fromBase: fromBase,
      atomReadStart: Int32List.fromList(atomStart),
      atomReadEnd: Int32List.fromList(atomEnd),
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
    for (final String t in req.cueTexts) EpubSrtMatcher._normalizeForMatch(t),
  ];
  return EpubSrtMatcher._matchWindows(
    idx: EpubSrtMatcher._buildIndex(req.sections),
    sections: req.sections,
    cues: cues,
    windows: <int>[req.searchWindow],
    similarityThreshold: req.similarityThreshold,
    maxConsecutiveMisses: req.maxConsecutiveMisses,
    normCueTexts: normCueTexts,
  ).single;
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
