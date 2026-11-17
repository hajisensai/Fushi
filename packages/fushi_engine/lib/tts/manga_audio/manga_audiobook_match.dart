/// 已有有声书当漫画台词的音源（设计 §9）：演出稿的每一句去关联有声书的 cue 文本里
/// 找最相近的一句，命中就引用「音频文件 + 起止时间」，不复制音频，也不跑 ASR。
///
/// 规则（一条一条对应设计）：
/// - **文本对文本**：两边都按有声书匹配的同一套归一化（[AudioTextNormalizer]：只留
///   假名 / 汉字 / 字母数字，片假名折成平假名、全角折成半角）后比对编辑距离相似度。
/// - **按故事顺序单调推进**：关联的书按用户给的顺序接成一条语料，游标只往前走；每句
///   只在游标之后 [MangaAudiobookMatchOptions.window] 条 cue 里找，避免同一句短台词命中
///   到远处的章节。没命中的句子不动游标。
/// - **短句不匹配**：归一化后不足 [MangaAudiobookMatchOptions.minChars]（6）字的句子
///   直接判 [MangaAudiobookLineOutcome.tooShort]。
/// - **整句命中**：台词与一条 cue、或同一音频文件里相邻的 2～3 条 cue 拼起来近似相等
///   （小说一句被切成两条 cue、漫画把两句并成一个气泡），片段边界取 cue 边界。
/// - **半句命中**：台词只是 cue 的一部分时，cue 带逐 token 时间（[CueTokenTiming] 的
///   形状）才按 token 裁出对应区间；不带就**不算命中**，单独计为
///   [MangaAudiobookLineOutcome.partialNoTiming]，好让命中统计说清楚「有多少句是因为
///   这本书没有逐 token 时间而没用上」。
///
/// 匹配只产出结果（[MangaAudiobookMatchResult]），落到演出稿由
/// [applyMangaAudiobookMatches] 按作品音源策略做，用户亲手定的音源不覆盖。
library;

import 'dart:math' as math;

import 'package:fushi_audio/fushi_audio_core.dart'
    show AudioCue, AudioTextNormalizer;

import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';

/// 语料里的一条 cue（关联有声书的一句）。与 `AudioCue` 解耦，只带匹配要用的字段。
class MangaAudiobookCue {
  const MangaAudiobookCue({
    required this.bookKey,
    required this.fileIndex,
    required this.startMs,
    required this.endMs,
    required this.text,
    this.tokens,
    this.tokenOffsetsMs,
  }) : assert(
         (tokens == null) == (tokenOffsetsMs == null),
         'tokens and offsets come together',
       );

  /// 有声书的 bookKey（`Audiobooks.bookKey`）。
  final String bookKey;

  /// `AudioCue.audioFileIndex`。
  final int fileIndex;
  final int startMs;
  final int endMs;

  /// cue 文本（`AudioCue.text`）。
  final String text;

  /// 逐 token 文本与相对 cue 起点的发射时刻（`CueTokenTiming`）；没有 = null。
  final List<String>? tokens;
  final List<int>? tokenOffsetsMs;

  bool get hasTokenTiming =>
      tokens != null &&
      tokens!.isNotEmpty &&
      tokens!.length == tokenOffsetsMs!.length;

  /// 从数据库 cue 取（逐 token 时间是瞬态字段，落库往返不携带——见
  /// `AudioCue.tokenTiming`；有就带上）。
  factory MangaAudiobookCue.fromAudioCue(AudioCue cue) => MangaAudiobookCue(
    bookKey: cue.bookKey,
    fileIndex: cue.audioFileIndex,
    startMs: cue.startMs,
    endMs: cue.endMs,
    text: cue.text,
    tokens: cue.tokenTiming?.tokens,
    tokenOffsetsMs: cue.tokenTiming?.offsetsMs,
  );
}

/// 要匹配的一句台词（会发声的行，文本已按 OCR / 修正 / 手填解析好）。
typedef MangaAudiobookQueryLine = ({String lineId, String text});

/// 匹配参数。默认值见各字段；不是测量结果，是保守取值（宁可漏也不错配）。
class MangaAudiobookMatchOptions {
  const MangaAudiobookMatchOptions({
    this.minChars = 6,
    this.threshold = 0.8,
    this.window = 600,
    this.lookahead = 3,
    this.maxSpan = 3,
    this.minClipMs = 200,
  });

  /// 归一化后不足这么多字的句子不匹配（设计：6 字以下太容易撞上无关句子）。
  final int minChars;

  /// 相似度下限（1 - 编辑距离 / 较长一方长度；半句时分母是台词长度）。
  final double threshold;

  /// 游标之后最多看多少条 cue。
  final int window;

  /// 找到第一处够格的候选后，再往后看几条有没有更像的（同分取靠前的）。
  final int lookahead;

  /// 整句命中时最多拼几条相邻 cue。
  final int maxSpan;

  /// 半句裁出来短于这个时长的不算命中（token 时间退化时的保护）。
  final int minClipMs;
}

/// 一句的匹配结果。
enum MangaAudiobookLineOutcome {
  /// 整句命中（一条或相邻几条 cue）。
  hit,

  /// 半句命中，按逐 token 时间裁出了区间。
  partialHit,

  /// 台词是某条 cue 的一部分，但那条 cue 没有逐 token 时间，裁不了——不算命中。
  partialNoTiming,

  /// 没找到。
  miss,

  /// 归一化后太短，不参与匹配。
  tooShort,
}

class MangaAudiobookLineMatch {
  const MangaAudiobookLineMatch({
    required this.lineId,
    required this.outcome,
    this.clip,
    this.score,
    this.cueIndex,
  });

  final String lineId;
  final MangaAudiobookLineOutcome outcome;

  /// 命中时的片段（[MangaAudiobookLineOutcome.hit] / [partialHit] 才有）。
  final MangaAudiobookClip? clip;

  /// 相似度 0..1（找到候选时才有，含 [partialNoTiming]）。
  final double? score;

  /// 命中 / 候选所在的语料下标（首条 cue）。
  final int? cueIndex;

  bool get isHit =>
      outcome == MangaAudiobookLineOutcome.hit ||
      outcome == MangaAudiobookLineOutcome.partialHit;
}

/// 发起前给用户看的命中统计。
class MangaAudiobookMatchStats {
  const MangaAudiobookMatchStats({
    required this.lines,
    required this.hits,
    required this.partialHits,
    required this.partialNoTiming,
    required this.misses,
    required this.tooShort,
    required this.hitDurationMs,
    required this.cues,
    required this.cuesWithTokenTiming,
  });

  /// 参与统计的句子数（会发声的行）。
  final int lines;
  final int hits;
  final int partialHits;

  /// 本可半句命中、但有声书没有逐 token 时间而放弃的句子数。
  final int partialNoTiming;
  final int misses;
  final int tooShort;

  /// 命中片段的总时长。
  final int hitDurationMs;

  /// 语料 cue 总数与其中带逐 token 时间的条数（0 = 这些书一句都裁不了）。
  final int cues;
  final int cuesWithTokenTiming;

  int get matched => hits + partialHits;

  /// 参与匹配的句子（去掉太短的）。
  int get eligible => lines - tooShort;

  bool get tokenTimingAvailable => cuesWithTokenTiming > 0;
}

class MangaAudiobookMatchResult {
  MangaAudiobookMatchResult({
    required List<MangaAudiobookLineMatch> lines,
    required this.stats,
  }) : lines = List<MangaAudiobookLineMatch>.unmodifiable(lines);

  /// 与输入同序。
  final List<MangaAudiobookLineMatch> lines;
  final MangaAudiobookMatchStats stats;

  MangaAudiobookLineMatch? byLineId(String lineId) {
    for (final MangaAudiobookLineMatch m in lines) {
      if (m.lineId == lineId) return m;
    }
    return null;
  }
}

/// 归一化口：输入一批文本，各自归一化（与输入同序）。默认走
/// [AudioTextNormalizer.normalizeBatch]（与有声书匹配同一份 Rust 实现、整批一次 FFI）。
typedef MangaAudiobookNormalizer = List<String> Function(List<String> texts);

List<String> _defaultNormalize(List<String> texts) => texts.isEmpty
    ? const <String>[]
    : AudioTextNormalizer.normalizeBatch(texts);

/// 预处理过的一条语料 cue。
class _Cue {
  _Cue(this.source, this.text, this.tokenText, this.tokenStarts);

  final MangaAudiobookCue source;

  /// 归一化后的 cue 文本（整句比对用）。
  final String text;

  /// 有逐 token 时间时：归一化后的 token 拼接（半句裁剪在它上面定位）与各 token
  /// 在其中的起点；没有时 null。
  final String? tokenText;
  final List<int>? tokenStarts;

  Set<int>? _bigrams;
  Set<int> get bigrams => _bigrams ??= _bigramSet(_searchText);

  /// 预筛与半句定位用的文本：有 token 时用 token 拼接，保证定位坐标与裁剪一致。
  String get _searchText => tokenText ?? text;
}

/// 跑一遍匹配。纯计算（除了归一化的那两次批量 FFI），可放后台 isolate。
MangaAudiobookMatchResult matchMangaLinesToAudiobook({
  required List<MangaAudiobookQueryLine> lines,
  required List<MangaAudiobookCue> corpus,
  MangaAudiobookMatchOptions options = const MangaAudiobookMatchOptions(),
  MangaAudiobookNormalizer normalize = _defaultNormalize,
}) {
  final List<String> lineTexts = normalize(<String>[
    for (final MangaAudiobookQueryLine l in lines) l.text,
  ]);
  final List<String> cueTexts = normalize(<String>[
    for (final MangaAudiobookCue c in corpus) c.text,
  ]);
  // 带 token 的 cue：所有 token 一次归一化，再按 cue 切回去。
  final List<String> allTokens = <String>[
    for (final MangaAudiobookCue c in corpus)
      if (c.hasTokenTiming) ...c.tokens!,
  ];
  final List<String> normTokens = normalize(allTokens);
  final List<_Cue> cues = <_Cue>[];
  int tokenAt = 0;
  int withTiming = 0;
  for (int i = 0; i < corpus.length; i++) {
    final MangaAudiobookCue c = corpus[i];
    if (!c.hasTokenTiming) {
      cues.add(_Cue(c, cueTexts[i], null, null));
      continue;
    }
    withTiming++;
    final StringBuffer buf = StringBuffer();
    final List<int> starts = <int>[];
    for (int k = 0; k < c.tokens!.length; k++) {
      starts.add(buf.length);
      buf.write(normTokens[tokenAt + k]);
    }
    tokenAt += c.tokens!.length;
    cues.add(_Cue(c, cueTexts[i], buf.toString(), starts));
  }

  final List<MangaAudiobookLineMatch> out = <MangaAudiobookLineMatch>[];
  int cursor = 0;
  int hits = 0;
  int partialHits = 0;
  int partialNoTiming = 0;
  int misses = 0;
  int tooShort = 0;
  int hitMs = 0;
  for (int li = 0; li < lines.length; li++) {
    final String lineId = lines[li].lineId;
    final String a = lineTexts[li];
    if (a.length < options.minChars) {
      tooShort++;
      out.add(
        MangaAudiobookLineMatch(
          lineId: lineId,
          outcome: MangaAudiobookLineOutcome.tooShort,
        ),
      );
      continue;
    }
    final _Candidate? best = _bestCandidate(a, cues, cursor, options);
    if (best == null) {
      misses++;
      out.add(
        MangaAudiobookLineMatch(
          lineId: lineId,
          outcome: MangaAudiobookLineOutcome.miss,
        ),
      );
      continue;
    }
    final MangaAudiobookLineMatch match = best.toMatch(lineId, cues, options);
    switch (match.outcome) {
      case MangaAudiobookLineOutcome.hit:
        hits++;
        hitMs += match.clip!.durationMs;
        // 整句用掉了这几条 cue，下一句从它们后面找。
        cursor = best.end;
      case MangaAudiobookLineOutcome.partialHit:
        partialHits++;
        hitMs += match.clip!.durationMs;
        // 同一条 cue 里还可能有下一句台词（漫画把一句小说拆成两个气泡）。
        cursor = best.start;
      case MangaAudiobookLineOutcome.partialNoTiming:
        partialNoTiming++;
        // 位置是可信的，只是裁不了：照样推进游标，保持单调。
        cursor = best.start;
      case MangaAudiobookLineOutcome.miss:
        misses++;
      case MangaAudiobookLineOutcome.tooShort:
        tooShort++;
    }
    out.add(match);
  }
  return MangaAudiobookMatchResult(
    lines: out,
    stats: MangaAudiobookMatchStats(
      lines: lines.length,
      hits: hits,
      partialHits: partialHits,
      partialNoTiming: partialNoTiming,
      misses: misses,
      tooShort: tooShort,
      hitDurationMs: hitMs,
      cues: corpus.length,
      cuesWithTokenTiming: withTiming,
    ),
  );
}

/// 一个候选：整句（cue `[start, end)`）或半句（cue `start` 内 `[subStart, subEnd)`）。
class _Candidate {
  _Candidate.full(this.start, this.end, this.score)
    : partial = false,
      subStart = 0,
      subEnd = 0;

  _Candidate.partial(this.start, this.subStart, this.subEnd, this.score)
    : partial = true,
      end = start + 1;

  final int start;
  final int end;
  final bool partial;
  final int subStart;
  final int subEnd;
  final double score;

  /// 同分时整句优先（边界是 cue 边界，比按 token 裁更可靠）。
  bool beats(_Candidate other) =>
      score > other.score + 1e-9 ||
      ((score - other.score).abs() <= 1e-9 && !partial && other.partial);

  MangaAudiobookLineMatch toMatch(
    String lineId,
    List<_Cue> cues,
    MangaAudiobookMatchOptions options,
  ) {
    final MangaAudiobookCue first = cues[start].source;
    if (!partial) {
      final MangaAudiobookCue last = cues[end - 1].source;
      return MangaAudiobookLineMatch(
        lineId: lineId,
        outcome: MangaAudiobookLineOutcome.hit,
        score: score,
        cueIndex: start,
        clip: MangaAudiobookClip(
          bookKey: first.bookKey,
          fileIndex: first.fileIndex,
          startMs: first.startMs,
          endMs: math.max(last.endMs, first.startMs + 1),
        ),
      );
    }
    final _Cue cue = cues[start];
    final ({int startMs, int endMs})? cut = cue.tokenStarts == null
        ? null
        : _cutByTokens(cue, subStart, subEnd);
    if (cut == null || cut.endMs - cut.startMs < options.minClipMs) {
      return MangaAudiobookLineMatch(
        lineId: lineId,
        outcome: MangaAudiobookLineOutcome.partialNoTiming,
        score: score,
        cueIndex: start,
      );
    }
    return MangaAudiobookLineMatch(
      lineId: lineId,
      outcome: MangaAudiobookLineOutcome.partialHit,
      score: score,
      cueIndex: start,
      clip: MangaAudiobookClip(
        bookKey: first.bookKey,
        fileIndex: first.fileIndex,
        startMs: cut.startMs,
        endMs: cut.endMs,
      ),
    );
  }
}

_Candidate? _bestCandidate(
  String a,
  List<_Cue> cues,
  int cursor,
  MangaAudiobookMatchOptions options,
) {
  final Set<int> aBigrams = _bigramSet(a);
  final int limit = math.min(cues.length, cursor + options.window);
  _Candidate? best;
  int? firstFoundAt;
  for (int i = cursor; i < limit; i++) {
    if (firstFoundAt != null && i > firstFoundAt + options.lookahead) break;
    final _Candidate? here = _candidateAt(a, aBigrams, cues, i, options);
    if (here == null) continue;
    firstFoundAt ??= i;
    if (best == null || here.beats(best)) best = here;
  }
  return best;
}

/// 在语料下标 [i] 起找候选：单条 / 相邻多条整句，或单条内半句；取最像的那个。
_Candidate? _candidateAt(
  String a,
  Set<int> aBigrams,
  List<_Cue> cues,
  int i,
  MangaAudiobookMatchOptions options,
) {
  final _Cue cue = cues[i];
  _Candidate? best;
  void consider(_Candidate c) {
    if (c.score + 1e-9 < options.threshold) return;
    if (best == null || c.beats(best!)) best = c;
  }

  // 预筛：台词的二元组至少一半出现在这条 cue（或它起头的拼接）里才细算。
  if (_containment(aBigrams, cue.bigrams) >= 0.5 && cue.text.isNotEmpty) {
    consider(_Candidate.full(i, i + 1, _similarity(a, cue.text)));
    // 半句：cue 明显长于台词时在 cue 里找近似子串。
    final String hay = cue._searchText;
    if (hay.length * 4 >= a.length * 5) {
      final ({int start, int end, int distance}) sub = _approxSubstring(a, hay);
      consider(
        _Candidate.partial(i, sub.start, sub.end, 1 - sub.distance / a.length),
      );
    }
  }
  // 拼接：台词比这条 cue 长时，试接上同一文件里紧跟的 1～(maxSpan-1) 条。
  if (a.length * 5 > cue.text.length * 6) {
    final StringBuffer joined = StringBuffer(cue.text);
    for (int j = i + 1; j < cues.length && j < i + options.maxSpan; j++) {
      final MangaAudiobookCue next = cues[j].source;
      if (next.bookKey != cue.source.bookKey ||
          next.fileIndex != cue.source.fileIndex ||
          next.startMs < cue.source.startMs) {
        break;
      }
      joined.write(cues[j].text);
      final String b = joined.toString();
      if (_containment(aBigrams, _bigramSet(b)) < 0.5) continue;
      consider(_Candidate.full(i, j + 1, _similarity(a, b)));
      if (b.length * 5 > a.length * 6) break;
    }
  }
  return best;
}

/// 半句区间 → 时间：区间覆盖到的首末 token。起点取首 token 与前一 token 发射时刻的
/// 中点、终点取末 token 与后一 token 发射时刻的中点（RNN-T 发射偏晚，直接用发射时刻
/// 会切掉首音；用前一 token 的发射时刻又会带进上一个词）。夹在 cue 区间内。
({int startMs, int endMs})? _cutByTokens(_Cue cue, int subStart, int subEnd) {
  final List<int> starts = cue.tokenStarts!;
  final List<int> offsets = cue.source.tokenOffsetsMs!;
  final int base = cue.source.startMs;
  int first = -1;
  int last = -1;
  for (int k = 0; k < starts.length; k++) {
    final int tokStart = starts[k];
    final int tokEnd = k + 1 < starts.length
        ? starts[k + 1]
        : cue.tokenText!.length;
    if (tokEnd <= tokStart) continue; // 归一化后为空的 token（标点）
    if (tokEnd > subStart && tokStart < subEnd) {
      if (first < 0) first = k;
      last = k;
    }
  }
  if (first < 0) return null;
  final int startMs = first == 0
      ? cue.source.startMs
      : base + ((offsets[first - 1] + offsets[first]) ~/ 2);
  final int endMs = last + 1 >= offsets.length
      ? cue.source.endMs
      : base + ((offsets[last] + offsets[last + 1]) ~/ 2);
  final int s = startMs.clamp(cue.source.startMs, cue.source.endMs);
  final int e = endMs.clamp(cue.source.startMs, cue.source.endMs);
  if (e <= s) return null;
  return (startMs: s, endMs: e);
}

Set<int> _bigramSet(String s) {
  final Set<int> out = <int>{};
  final List<int> u = s.codeUnits;
  for (int i = 0; i + 1 < u.length; i++) {
    out.add((u[i] << 16) | u[i + 1]);
  }
  return out;
}

double _containment(Set<int> a, Set<int> b) {
  if (a.isEmpty) return 0;
  int n = 0;
  for (final int x in a) {
    if (b.contains(x)) n++;
  }
  return n / a.length;
}

/// 1 - 编辑距离 / 较长一方长度。
double _similarity(String a, String b) {
  final int longer = math.max(a.length, b.length);
  if (longer == 0) return 0;
  return 1 - _levenshtein(a, b) / longer;
}

int _levenshtein(String a, String b) {
  final List<int> x = a.codeUnits;
  final List<int> y = b.codeUnits;
  List<int> prev = List<int>.generate(y.length + 1, (int j) => j);
  List<int> cur = List<int>.filled(y.length + 1, 0);
  for (int i = 1; i <= x.length; i++) {
    cur[0] = i;
    for (int j = 1; j <= y.length; j++) {
      final int sub = prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1);
      cur[j] = math.min(sub, math.min(prev[j] + 1, cur[j - 1] + 1));
    }
    final List<int> t = prev;
    prev = cur;
    cur = t;
  }
  return prev[y.length];
}

/// [needle] 在 [hay] 里的最佳近似子串（两端免费的编辑距离，Sellers 算法），返回
/// 子串区间 `[start, end)` 与距离；同距离取最靠前的结尾。
({int start, int end, int distance}) _approxSubstring(
  String needle,
  String hay,
) {
  final List<int> x = needle.codeUnits;
  final List<int> y = hay.codeUnits;
  final int m = y.length;
  List<int> prev = List<int>.filled(m + 1, 0);
  List<int> prevStart = List<int>.generate(m + 1, (int j) => j);
  List<int> cur = List<int>.filled(m + 1, 0);
  List<int> curStart = List<int>.filled(m + 1, 0);
  for (int i = 1; i <= x.length; i++) {
    cur[0] = i;
    curStart[0] = 0;
    for (int j = 1; j <= m; j++) {
      final int diag = prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1);
      final int up = prev[j] + 1;
      final int left = cur[j - 1] + 1;
      if (diag <= up && diag <= left) {
        cur[j] = diag;
        curStart[j] = prevStart[j - 1];
      } else if (up <= left) {
        cur[j] = up;
        curStart[j] = prevStart[j];
      } else {
        cur[j] = left;
        curStart[j] = curStart[j - 1];
      }
    }
    final List<int> t = prev;
    prev = cur;
    cur = t;
    final List<int> ts = prevStart;
    prevStart = curStart;
    curStart = ts;
  }
  int bestEnd = 0;
  for (int j = 1; j <= m; j++) {
    if (prev[j] < prev[bestEnd]) bestEnd = j;
  }
  return (start: prevStart[bestEnd], end: bestEnd, distance: prev[bestEnd]);
}

/// 把匹配结果按作品音源策略写进演出稿后的计数。
class MangaAudiobookApplyReport {
  const MangaAudiobookApplyReport({
    required this.clipsWritten,
    required this.clipsCleared,
    required this.userKept,
  });

  /// 写入（或换成新的）有声书片段的行数。
  final int clipsWritten;

  /// 原来是匹配写的片段、这次没命中（或策略为只合成）而改回合成的行数。
  final int clipsCleared;

  /// 用户亲手定过音源、原样保留的行数。
  final int userKept;
}

/// 按 [MangaAudioScript.sourcePolicy] 把 [result] 写进 [script]（就地修改）：
/// - 用户亲手定的音源（[MangaLineAudioSource.byUser]）一律不动；
/// - 只合成：匹配写过的片段全部改回合成；
/// - 有声书优先 / 只用有声书：命中的写片段，没命中的改回合成（「只用有声书」下它们
///   由 [MangaAudioScript.audioPlanFor] 判成不读，不在这里改行的类型——不读是策略，
///   不是标注）。
/// 结果里没有的行（不读的行、匹配之后新加的行）不动。
MangaAudiobookApplyReport applyMangaAudiobookMatches(
  MangaAudioScript script,
  MangaAudiobookMatchResult result,
) {
  final Map<String, MangaAudiobookLineMatch> byId =
      <String, MangaAudiobookLineMatch>{
        for (final MangaAudiobookLineMatch m in result.lines) m.lineId: m,
      };
  final bool synthOnly =
      script.sourcePolicy == MangaAudioSourcePolicy.synthOnly;
  int written = 0;
  int cleared = 0;
  int kept = 0;
  for (int i = 0; i < script.lines.length; i++) {
    final MangaScriptLine line = script.lines[i];
    final MangaAudiobookLineMatch? m = byId[line.lineId];
    if (m == null) continue;
    if (line.audio.byUser) {
      kept++;
      continue;
    }
    final MangaAudiobookClip? clip = synthOnly ? null : m.clip;
    if (clip != null) {
      if (line.audio != clip) {
        script.lines[i] = line.copyWith(audio: clip);
        written++;
      }
    } else if (line.audio is MangaAudiobookClip) {
      script.lines[i] = line.copyWith(audio: const MangaSynthesized());
      cleared++;
    }
  }
  return MangaAudiobookApplyReport(
    clipsWritten: written,
    clipsCleared: cleared,
    userKept: kept,
  );
}
