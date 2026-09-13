import 'dart:math' as math;

import '../audiobook/audiobook_model.dart';
import 'audio_text_normalizer.dart';
import 'epub_srt_matcher.dart';

/// 命中 cue 按**正文句界**重切（设备端转录产物专用）。
///
/// ASR 的 cue 是按听写文本里的标点与 token 间静默切出来的，与正文句界并不一致：
/// 一条 cue 盖两句半（`えば、夢見る時がある。転入生がやってくる。`）、词中切开
/// （`私｜に近づき`、`ひ｜さしぶり`——RNN-T 发射时间的一次停顿被当成句间静默）。
/// 匹配之后每条命中 cue 都对上了正文的一段归一化区间，而转录产物的每个 token
/// 又都有发射时间（`AudioCue.tokenTiming`），于是可以：
///
/// 1. 把**连续命中且正文区间首尾相接**的 cue 串看成一段 token 流，每个 token 经
///    「cue 归一化文本 ↔ 正文归一化切片」的对齐映射到正文偏移（精确命中是恒等
///    映射，模糊/回填命中走编辑距离对齐）；
/// 2. 在正文里**两个保留字符之间夹着句末标点**的位置切一刀（新增边界）；
/// 3. 原有 cue 边界**落在正文里两个保留字符紧挨着的地方**（词中）就抹掉（合并）；
///    落在有标点/空白的间隙上则保留，连原来的时间一起保留（那是 VAD 静默边缘或
///    已按 token 算好的分界，比重算更准）；
/// 4. 新增边界的时间 = 下一句首 token 发射时间 − [leadInMs]（与 `AsrCueBuilder`
///    同一补偿），不早于上一句末 token + [frameMs]；串的首尾时间原样保留。
///
/// 建串之前先**合缝**（`_closeGaps`）：匹配器只把「听到的字」映射到正文，正文里
/// 没被任何 cue 认领的字——ASR 整句掉字（4 s 的 cue 只吐了一个「こ」）、模糊命中
/// 的词尾（`気にし出｜す。`）、书写假名而听写成汉字（`こころ` ↔ `心`）——就成了
/// 相邻区间之间的缝；缝一出现串就断，两侧的词中边界永远合不回去（2026-09-13
/// kagami 实测 32 条词中边界里 24 条是这么来的）。规则只有一条：**缝归缝隙期间
/// 正在发声的 cue**——中间有未命中 cue 就按发声时长比例切给它们（0 字的缝 =
/// ASR 幻觉，也认领，token 折进前一片后幻觉 cue 自然消失）；没有就在缝内第一个
/// 标点/空白边界处切开分给两侧。判据是朗读速度：认领后该 cue 的「正文字数 /
/// 时长」不得超过本次结果命中 cue 密度中位数的 [maxDensityRatio] 倍，旁白真跳过
/// 一段时缝仍留着（行为与合缝前相同）。中位数是自适应的，日语（3–4 字/s）与英语
/// （空格已剥、~12 字母/s）都不用配常量。
///
/// 未命中 / 没有 token 时间 / 区间不相接的 cue 原样透传（对象复用）。产出的
/// [MatchResult] 与新 cue 列表一一对应，偏移仍在正文归一化坐标系上——阅读器
/// 高亮、`fushi-cue://` 编码、换正文都不用改。
class CueSentenceResegmenter {
  const CueSentenceResegmenter({
    this.leadInMs = 150,
    this.minCueMs = 300,
    this.frameMs = 40,
    this.maxAlignCells = 400000,
    this.maxDensityRatio = 2.0,
  }) : assert(
          frameMs > 0,
          'frameMs 是时长下限：合缝按时长分权重，0 会让全零时长的中间 cue 除零',
        );

  /// 新边界起点在该句首 token 之前预留的毫秒数（补偿 RNN-T 发射延迟）。
  final int leadInMs;

  /// 新切出的 cue 最短时长。
  final int minCueMs;

  /// 编码器一帧的毫秒数：上一句终点至少落在其末 token 之后一帧。
  final int frameMs;

  /// 模糊命中做位置对齐的编辑距离 DP 单元数上限，超过退化为按比例映射。
  final int maxAlignCells;

  /// 合缝判据：认领缝隙后 cue 的正文字数密度（字/ms）不得超过本次结果命中 cue
  /// 密度中位数的这个倍数。
  final double maxDensityRatio;

  /// 正文里的句末标点（与 `AsrCueBuilder.sentenceTerminators` 同源同义）。
  static const String sentenceTerminators = '。！？!?…‥．.';

  CueResegmentResult resegment({
    required List<EpubSection> sections,
    required List<AudioCue> cues,
    required MatchResult result,
  }) {
    if (result.matches.length != cues.length) {
      return CueResegmentResult(
        cues: cues,
        result: result,
        stats: const CueResegmentStats(),
      );
    }
    final Map<int, _SectionGaps> gapsBySection = <int, _SectionGaps>{};
    _SectionGaps gapsFor(int section) => gapsBySection.putIfAbsent(
          section,
          () => _SectionGaps.build(sections[section].text),
        );

    // 命中区间可能越过章节末尾（匹配器把跨章命中记在起始章上），那种 cue 不
    // 参与重切——正文偏移在下一章里，本章的间隙表管不到它。
    bool eligibleIn(List<CueMatch> ms, int k) {
      final CueMatch m = ms[k];
      return _eligible(cues[k], m, sections.length) &&
          m.normCharEnd <= gapsFor(m.sectionIndex).norm.text.length;
    }

    final _ClosedGaps closed = _closeGaps(
      cues: cues,
      matches: result.matches,
      eligible: (int k) => eligibleIn(result.matches, k),
      gapsFor: gapsFor,
    );
    final List<CueMatch> matches = closed.matches;
    bool eligible(int k) => eligibleIn(matches, k);

    final List<AudioCue> outCues = <AudioCue>[];
    final List<CueMatch> outMatches = <CueMatch>[];
    int runs = 0;
    int added = 0;
    int removed = 0;
    int i = 0;
    while (i < cues.length) {
      if (!eligible(i)) {
        outCues.add(cues[i]);
        outMatches.add(matches[i]);
        i++;
        continue;
      }
      int j = i;
      while (j + 1 < cues.length &&
          eligible(j + 1) &&
          _contiguous(
            cues[j],
            matches[j],
            cues[j + 1],
            matches[j + 1],
          )) {
        j++;
      }
      runs++;
      final _RunOutput run = _resegmentRun(
        cues: cues,
        matches: matches,
        from: i,
        to: j,
        gaps: gapsFor(matches[i].sectionIndex),
      );
      outCues.addAll(run.cues);
      outMatches.addAll(run.matches);
      added += run.boundariesAdded;
      removed += run.boundariesRemoved;
      i = j + 1;
    }

    // 序号重编：cue 数变了，sentenceIndex 必须连续且与 matches 一一对应。
    int matched = 0;
    final List<CueMatch> renumbered = <CueMatch>[];
    for (int k = 0; k < outCues.length; k++) {
      outCues[k].sentenceIndex = k;
      final CueMatch m = outMatches[k];
      if (m.matched) matched++;
      renumbered.add(
        m.matched
            ? CueMatch(
                cueSentenceIndex: k,
                sectionIndex: m.sectionIndex,
                normCharStart: m.normCharStart,
                normCharEnd: m.normCharEnd,
                score: m.score,
              )
            : CueMatch.unmatched,
      );
    }
    return CueResegmentResult(
      cues: outCues,
      result: MatchResult(
        matches: renumbered,
        totalCues: outCues.length,
        matchedCues: matched,
        gapFill: result.gapFill,
      ),
      stats: CueResegmentStats(
        runs: runs,
        cuesIn: cues.length,
        cuesOut: outCues.length,
        boundariesAdded: added,
        boundariesRemoved: removed,
        gapsClosed: closed.gapsClosed,
      ),
    );
  }

  /// 合缝（类文档第二段）。[eligible] 判定原始 [matches] 里哪些 cue 是锚点
  /// （命中 + 带 token 时间 + 区间在本章内）；返回补齐后的 match 列表，未动的
  /// 下标复用原对象。只在**相邻两个锚点之间**动手：同章、同音频文件、时间单调、
  /// 区间不重叠，中间要么没有 cue、要么全是带时间的未命中 cue。
  _ClosedGaps _closeGaps({
    required List<AudioCue> cues,
    required List<CueMatch> matches,
    required bool Function(int) eligible,
    required _SectionGaps Function(int) gapsFor,
  }) {
    final List<int> anchors = <int>[
      for (int k = 0; k < cues.length; k++)
        if (eligible(k)) k,
    ];
    final double? reference = _medianDensity(cues, matches, anchors);
    if (reference == null) return _ClosedGaps(matches, 0);
    final double ceiling = reference * maxDensityRatio;
    final List<CueMatch> out = List<CueMatch>.of(matches);
    int closedCount = 0;

    // 认领后密度不超上限才成交；[chars] 是认领后该 cue 的正文字数。
    bool affordable(AudioCue cue, int chars) {
      final int dur = math.max(cue.endMs - cue.startMs, frameMs);
      return chars / dur <= ceiling;
    }

    for (int a = 0; a + 1 < anchors.length; a++) {
      final int i = anchors[a];
      final int j = anchors[a + 1];
      final CueMatch mi = out[i];
      final CueMatch mj = out[j];
      if (mi.sectionIndex != mj.sectionIndex ||
          cues[i].audioFileIndex != cues[j].audioFileIndex ||
          cues[j].startMs < cues[i].startMs ||
          mj.normCharStart < mi.normCharEnd) {
        continue;
      }
      final int gapStart = mi.normCharEnd;
      final int gapEnd = mj.normCharStart;
      final int gapLen = gapEnd - gapStart;
      final List<int> interior = <int>[for (int k = i + 1; k < j; k++) k];
      // 中间 cue 与两侧锚点同一音频文件、时间单调，否则它认领的区间会在
      // 建串时被 _contiguous 断开、以独立「命中」输出（换上从没读过的正文）。
      final bool interiorClaimable = interior.every((int k) {
        final CueTokenTiming? t = cues[k].tokenTiming;
        return !out[k].matched &&
            t != null &&
            !t.isEmpty &&
            cues[k].audioFileIndex == cues[i].audioFileIndex &&
            cues[k].startMs >= cues[i].startMs &&
            cues[k].startMs <= cues[j].startMs;
      });
      if (!interiorClaimable) continue;

      if (interior.isEmpty) {
        if (gapLen == 0) continue;
        final int cut =
            _firstBoundary(gapsFor(mi.sectionIndex), gapStart, gapEnd);
        final int left = cut - gapStart;
        final int right = gapEnd - cut;
        if (left > 0 &&
            affordable(cues[i], mi.normCharEnd - mi.normCharStart + left)) {
          out[i] = _withRange(mi, mi.normCharStart, cut);
          closedCount++;
        }
        if (right > 0 &&
            affordable(cues[j], mj.normCharEnd - mj.normCharStart + right)) {
          out[j] = _withRange(mj, cut, mj.normCharEnd);
          closedCount++;
        }
        continue;
      }

      // 中间的未命中 cue 按**发声时长**比例分缝（0 字缝也分：空区间）：正文字是
      // 在谁发声时被读的就归谁。按听写长度分会把 7 s 只吐一个「そ」的掉字 cue
      // 与旁边 0.25 s 的「う」平分，后者密度立刻炸掉、整对被拒。
      final List<int> weights = <int>[
        for (final int k in interior)
          math.max(cues[k].endMs - cues[k].startMs, frameMs),
      ];
      // 密度按整块判，不按单条：0.25 s 的 cue 分到 1 字还是 2 字是量化噪音。
      final int totalWeight = weights.fold<int>(0, (int s, int w) => s + w);
      if (gapLen / totalWeight > ceiling) continue;
      int pos = gapStart;
      int acc = 0;
      for (int n = 0; n < interior.length; n++) {
        acc += weights[n];
        final int end = n == interior.length - 1
            ? gapEnd
            : gapStart + (gapLen * acc / totalWeight).floor();
        out[interior[n]] = CueMatch(
          cueSentenceIndex: cues[interior[n]].sentenceIndex,
          sectionIndex: mi.sectionIndex,
          normCharStart: pos,
          normCharEnd: end,
          score: 0,
        );
        pos = end;
      }
      closedCount += interior.length;
    }
    return _ClosedGaps(out, closedCount);
  }

  /// 锚点 cue 的正文字数密度（字/ms）中位数；没有锚点返回 null。
  static double? _medianDensity(
    List<AudioCue> cues,
    List<CueMatch> matches,
    List<int> anchors,
  ) {
    if (anchors.isEmpty) return null;
    final List<double> densities = <double>[
      for (final int k in anchors)
        (matches[k].normCharEnd - matches[k].normCharStart) /
            math.max(cues[k].endMs - cues[k].startMs, 1),
    ]..sort();
    return densities[densities.length ~/ 2];
  }

  /// `[from, to]` 内第一个不在词中的位置（标点/空白间隙），没有就 [to]。
  static int _firstBoundary(_SectionGaps gaps, int from, int to) {
    for (int p = from; p <= to; p++) {
      if (gaps.kindAt(p) != _GapKind.none) return p;
    }
    return to;
  }

  static CueMatch _withRange(CueMatch m, int start, int end) => CueMatch(
        cueSentenceIndex: m.cueSentenceIndex,
        sectionIndex: m.sectionIndex,
        normCharStart: start,
        normCharEnd: end,
        score: m.score,
      );

  /// 空区间（`end == start`）也算：那是合缝时认领了 0 字缝的幻觉 cue。
  static bool _eligible(AudioCue cue, CueMatch m, int sectionCount) {
    final CueTokenTiming? timing = cue.tokenTiming;
    return m.matched &&
        m.sectionIndex < sectionCount &&
        m.normCharEnd >= m.normCharStart &&
        timing != null &&
        !timing.isEmpty;
  }

  static bool _contiguous(
    AudioCue a,
    CueMatch ma,
    AudioCue b,
    CueMatch mb,
  ) =>
      ma.sectionIndex == mb.sectionIndex &&
      a.audioFileIndex == b.audioFileIndex &&
      mb.normCharStart == ma.normCharEnd &&
      b.startMs >= a.startMs;

  _RunOutput _resegmentRun({
    required List<AudioCue> cues,
    required List<CueMatch> matches,
    required int from,
    required int to,
    required _SectionGaps gaps,
  }) {
    final int runStart = matches[from].normCharStart;
    final int runEnd = matches[to].normCharEnd;

    // 1. token 流：每个 token 的发射时间与正文归一化偏移。
    final List<_Token> tokens = <_Token>[];
    for (int c = from; c <= to; c++) {
      _appendTokens(tokens, cues[c], matches[c], gaps.norm.text);
    }
    if (tokens.isEmpty) return _RunOutput.unchanged(cues, matches, from, to);

    // 2. 切点：原边界（落在间隙上的保留、词中的抹掉）+ 句末标点处新增。
    final Map<int, _Boundary?> boundaries = <int, _Boundary?>{};
    int removed = 0;
    for (int c = from; c < to; c++) {
      final int p = matches[c].normCharEnd;
      if (p == matches[c].normCharStart) {
        // 空区间（认领了 0 字缝的幻觉 cue）：它自己不构成边界，抹掉。
        removed++;
        continue;
      }
      if (gaps.kindAt(p) == _GapKind.none) {
        removed++;
      } else {
        boundaries[p] = _Boundary(
          endMs: cues[c].endMs,
          startMs: cues[c + 1].startMs,
        );
      }
    }
    int added = 0;
    for (int p = runStart + 1; p < runEnd; p++) {
      if (gaps.kindAt(p) == _GapKind.sentence && !boundaries.containsKey(p)) {
        boundaries[p] = null;
        added++;
      }
    }
    if (removed == 0 && added == 0) {
      return _RunOutput.unchanged(cues, matches, from, to);
    }

    // 3. 切成片，token 按正文偏移落片；空片并入前一片（首片空则并入后一片）。
    final List<int> cuts = boundaries.keys.toList()..sort();
    final List<int> edges = <int>[runStart, ...cuts, runEnd];
    final List<List<_Token>> pieceTokens = List<List<_Token>>.generate(
      edges.length - 1,
      (int _) => <_Token>[],
    );
    int piece = 0;
    for (final _Token t in tokens) {
      while (piece + 1 < pieceTokens.length && t.bookPos >= edges[piece + 1]) {
        piece++;
      }
      pieceTokens[piece].add(t);
    }
    final List<_Piece> pieces = <_Piece>[];
    for (int k = 0; k < pieceTokens.length; k++) {
      final List<_Token> ts = pieceTokens[k];
      if (ts.isEmpty) {
        if (pieces.isEmpty) {
          // 首片没有 token：并入后一片（把起点拉到串首）。
          if (k + 1 < pieceTokens.length) {
            pieceTokens[k + 1].insertAll(0, ts);
            edges[k + 1] = edges[k];
          }
          continue;
        }
        pieces.last.end = edges[k + 1];
        continue;
      }
      pieces.add(_Piece(start: edges[k], end: edges[k + 1], tokens: ts));
    }
    if (pieces.length <= 1 && removed == 0) {
      return _RunOutput.unchanged(cues, matches, from, to);
    }

    // 4. 时间：串首尾原样，内部边界优先用原边界时间，新边界按 token 算。
    final int n = pieces.length;
    final List<int> starts = List<int>.filled(n, 0);
    final List<int> ends = List<int>.filled(n, 0);
    for (int k = 0; k < n; k++) {
      final _Piece p = pieces[k];
      if (k == 0) {
        starts[k] = cues[from].startMs;
      } else {
        final _Boundary? kept = boundaries[p.start];
        starts[k] = kept?.startMs ?? (p.firstTokenMs - leadInMs);
      }
      if (k == n - 1) {
        ends[k] = cues[to].endMs;
      } else {
        final _Boundary? kept = boundaries[pieces[k + 1].start];
        ends[k] = kept?.endMs ?? (pieces[k + 1].firstTokenMs - leadInMs);
      }
    }
    for (int k = 0; k < n; k++) {
      if (k > 0 && starts[k] < ends[k - 1]) starts[k] = ends[k - 1];
      final int floor = pieces[k].lastTokenMs + frameMs;
      if (ends[k] < floor) ends[k] = floor;
      if (ends[k] - starts[k] < minCueMs) ends[k] = starts[k] + minCueMs;
      if (k == n - 1) {
        ends[k] = math.max(cues[to].endMs, starts[k] + frameMs);
      }
    }

    // 5. 产出新 cue（听写文本；换正文由调用方按新 MatchResult 做）。
    final AudioCue proto = cues[from];
    final List<AudioCue> outCues = <AudioCue>[];
    final List<CueMatch> outMatches = <CueMatch>[];
    for (int k = 0; k < n; k++) {
      final _Piece p = pieces[k];
      final AudioCue cue = AudioCue()
        ..bookKey = proto.bookKey
        ..chapterHref = proto.chapterHref
        ..sentenceIndex = 0
        ..textFragmentId = ''
        ..text = p.tokens.map((_Token t) => t.text).join().trim()
        ..startMs = starts[k]
        ..endMs = ends[k]
        ..audioFileIndex = proto.audioFileIndex
        ..tokenTiming = CueTokenTiming(
          tokens: List<String>.unmodifiable(
            p.tokens.map((_Token t) => t.text),
          ),
          offsetsMs: List<int>.unmodifiable(
            p.tokens.map((_Token t) => t.timeMs - starts[k]),
          ),
        );
      outCues.add(cue);
      outMatches.add(
        CueMatch(
          cueSentenceIndex: 0,
          sectionIndex: matches[from].sectionIndex,
          normCharStart: p.start,
          normCharEnd: p.end,
          score: _scoreAt(matches, from, to, p.start),
        ),
      );
    }
    return _RunOutput(
      cues: outCues,
      matches: outMatches,
      boundariesAdded: added,
      boundariesRemoved: removed,
    );
  }

  /// 片起点落在哪条原 cue 的区间里，就沿用它的分数。
  static double _scoreAt(List<CueMatch> matches, int from, int to, int pos) {
    for (int c = from; c <= to; c++) {
      if (pos >= matches[c].normCharStart && pos < matches[c].normCharEnd) {
        return matches[c].score;
      }
    }
    return matches[from].score;
  }

  /// 把一条 cue 的 token 映射到正文归一化偏移。归一化后为空的 token（标点）
  /// 挂在前一个 token 上——句号属于它前面那句，不能因为映射到下一个保留字符而
  /// 被甩到下一句。
  void _appendTokens(
    List<_Token> out,
    AudioCue cue,
    CueMatch m,
    String bookNorm,
  ) {
    final CueTokenTiming timing = cue.tokenTiming!;
    final List<String> normTokens = <String>[
      for (final String t in timing.tokens) AudioTextNormalizer.normalize(t),
    ];
    final String cueNorm = normTokens.join();
    final String slice = bookNorm.substring(m.normCharStart, m.normCharEnd);
    final List<int> posMap = cueNorm == slice
        ? List<int>.generate(cueNorm.length + 1, (int i) => i)
        : _alignPositions(cueNorm, slice);
    int cursor = 0;
    for (int k = 0; k < timing.length; k++) {
      final int normLen = normTokens[k].length;
      final int timeMs = cue.startMs + timing.offsetsMs[k];
      int bookPos;
      if ((normLen == 0 || slice.isEmpty) && out.isNotEmpty) {
        // 标点 token / 认领了 0 字缝的幻觉 cue：挂到前一个 token 上。
        bookPos = out.last.bookPos;
      } else {
        bookPos = m.normCharStart +
            math.min(posMap[cursor], math.max(0, slice.length - 1));
      }
      out.add(_Token(text: timing.tokens[k], timeMs: timeMs, bookPos: bookPos));
      cursor += normLen;
    }
  }

  /// 编辑距离对齐：返回长度 `a.length + 1` 的映射，`map[i]` = `a[i]` 在 [b] 里
  /// 对应的位置（删除的字符指向下一个对应位置），`map[a.length] = b.length`。
  /// 单调不减。超过 [maxAlignCells] 退化为按比例线性映射。
  List<int> _alignPositions(String a, String b) {
    final int n = a.length;
    final int m = b.length;
    final List<int> map = List<int>.filled(n + 1, m);
    if (n == 0) return map;
    if (m == 0) {
      for (int i = 0; i <= n; i++) {
        map[i] = 0;
      }
      return map;
    }
    if (n * m > maxAlignCells) {
      for (int i = 0; i <= n; i++) {
        map[i] = (i * m / n).round();
      }
      return map;
    }
    final int w = m + 1;
    final List<int> dp = List<int>.filled((n + 1) * w, 0);
    for (int i = 1; i <= n; i++) {
      dp[i * w] = i;
    }
    for (int j = 1; j <= m; j++) {
      dp[j] = j;
    }
    for (int i = 1; i <= n; i++) {
      final int ca = a.codeUnitAt(i - 1);
      for (int j = 1; j <= m; j++) {
        final int sub =
            dp[(i - 1) * w + j - 1] + (ca == b.codeUnitAt(j - 1) ? 0 : 1);
        final int del = dp[(i - 1) * w + j] + 1;
        final int ins = dp[i * w + j - 1] + 1;
        dp[i * w + j] = math.min(sub, math.min(del, ins));
      }
    }
    // 回溯：a[i-1] 与 b[j-1] 配对 → map[i-1] = j-1；a[i-1] 被删 → map[i-1] = j。
    int i = n;
    int j = m;
    while (i > 0) {
      final int cur = dp[i * w + j];
      if (j > 0 &&
          cur ==
              dp[(i - 1) * w + j - 1] +
                  (a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1)) {
        map[i - 1] = j - 1;
        i--;
        j--;
      } else if (cur == dp[(i - 1) * w + j] + 1) {
        map[i - 1] = j;
        i--;
      } else {
        j--;
      }
    }
    return map;
  }
}

/// [CueSentenceResegmenter.resegment] 的产物：新 cue 列表 + 与之一一对应的
/// [MatchResult]（sentenceIndex 已重编）。
class CueResegmentResult {
  const CueResegmentResult({
    required this.cues,
    required this.result,
    required this.stats,
  });

  final List<AudioCue> cues;
  final MatchResult result;
  final CueResegmentStats stats;
}

class CueResegmentStats {
  const CueResegmentStats({
    this.runs = 0,
    this.cuesIn = 0,
    this.cuesOut = 0,
    this.boundariesAdded = 0,
    this.boundariesRemoved = 0,
    this.gapsClosed = 0,
  });

  /// 参与重切的连续命中 cue 串数。
  final int runs;
  final int cuesIn;
  final int cuesOut;

  /// 在正文句末标点处新增的边界数。
  final int boundariesAdded;

  /// 落在词中而被抹掉的原 cue 边界数。
  final int boundariesRemoved;

  /// 合缝时区间被补齐的 cue 数（未命中 cue 认领缝 + 锚点向缝内延伸）。认领后
  /// 的 cue 换上的是正确的正文，**计入** [MatchResult.matchedCues] / 命中率——
  /// 这一项单列出来是为了对账：命中率里有多少是靠时间证据而非听写命中的。
  final int gapsClosed;

  bool get changed =>
      boundariesAdded > 0 || boundariesRemoved > 0 || gapsClosed > 0;

  @override
  String toString() => 'CueResegmentStats(runs=$runs cues=$cuesIn→$cuesOut '
      'added=$boundariesAdded removed=$boundariesRemoved '
      'gapsClosed=$gapsClosed)';
}

class _ClosedGaps {
  const _ClosedGaps(this.matches, this.gapsClosed);

  final List<CueMatch> matches;
  final int gapsClosed;
}

enum _GapKind { none, soft, sentence }

/// 一个章节归一化文本里每个位置 `p`（`0 < p < len`）前面的间隙类型：
/// 两个保留字符在原文里紧挨着 → [_GapKind.none]；中间夹着被剥掉的字符
/// （标点/空白/引号）→ [_GapKind.soft]；夹着的字符里有句末标点 →
/// [_GapKind.sentence]。
class _SectionGaps {
  _SectionGaps._(this.norm, this._kinds);

  factory _SectionGaps.build(String original) {
    final NormalizedTextWithOffsets norm =
        AudioTextNormalizer.normalizeWithOffsets(original);
    final int n = norm.text.length;
    final List<_GapKind> kinds = List<_GapKind>.filled(n + 1, _GapKind.none);
    for (int p = 1; p < n; p++) {
      final int from = norm.ends[p - 1];
      final int to = norm.starts[p];
      if (to <= from) continue;
      final String between = original.substring(from, to);
      bool sentence = false;
      for (int k = 0; k < between.length && !sentence; k++) {
        sentence =
            CueSentenceResegmenter.sentenceTerminators.contains(between[k]);
      }
      kinds[p] = sentence ? _GapKind.sentence : _GapKind.soft;
    }
    return _SectionGaps._(norm, kinds);
  }

  final NormalizedTextWithOffsets norm;
  final List<_GapKind> _kinds;

  _GapKind kindAt(int p) =>
      p > 0 && p < _kinds.length ? _kinds[p] : _GapKind.none;
}

class _Token {
  const _Token(
      {required this.text, required this.timeMs, required this.bookPos});

  final String text;
  final int timeMs;
  final int bookPos;
}

class _Boundary {
  const _Boundary({required this.endMs, required this.startMs});

  /// 边界前一条 cue 的终点 / 后一条 cue 的起点（原值）。
  final int endMs;
  final int startMs;
}

class _Piece {
  _Piece({required this.start, required this.end, required this.tokens});

  final int start;
  int end;
  final List<_Token> tokens;

  int get firstTokenMs => tokens.first.timeMs;

  int get lastTokenMs => tokens.fold<int>(
      tokens.first.timeMs, (int a, _Token t) => math.max(a, t.timeMs));
}

class _RunOutput {
  const _RunOutput({
    required this.cues,
    required this.matches,
    required this.boundariesAdded,
    required this.boundariesRemoved,
  });

  factory _RunOutput.unchanged(
    List<AudioCue> cues,
    List<CueMatch> matches,
    int from,
    int to,
  ) =>
      _RunOutput(
        cues: cues.sublist(from, to + 1),
        matches: matches.sublist(from, to + 1),
        boundariesAdded: 0,
        boundariesRemoved: 0,
      );

  final List<AudioCue> cues;
  final List<CueMatch> matches;
  final int boundariesAdded;
  final int boundariesRemoved;
}
