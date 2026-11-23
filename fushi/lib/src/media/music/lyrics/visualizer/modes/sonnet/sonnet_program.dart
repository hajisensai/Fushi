/// 商籁的「节目单」编译（folia `sonnetProgram.ts` / `sonnetSemantic.ts` /
/// `utils/lyrics/renderHints.ts`）：把歌词切成段落 → 镜头（shot）→ 语义片段，全部只由
/// 歌词与种子决定，跳转与连续播放得到同一帧。时间一律用**秒**（与 folia 常量对齐）。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

// ---------------------------------------------------------------------------
// 确定性散列（folia `visualizerSeedHash.ts`）
// ---------------------------------------------------------------------------

/// JS `Math.imul` 的 32 位乘法（结果按无符号 32 位返回）。
int sonnetImul(int a, int b) {
  final int x = a & 0xFFFFFFFF;
  final int y = b & 0xFFFFFFFF;
  final int lo = (x & 0xFFFF) * y;
  final int hi = ((x >> 16) * y) & 0xFFFF;
  return (lo + (hi << 16)) & 0xFFFFFFFF;
}

/// FNV-1a 32 位字符串散列（按 UTF-16 码元，与 JS `charCodeAt` 一致）。
int hashSonnetSeed(String value) {
  int hash = 2166136261;
  for (final int unit in value.codeUnits) {
    hash ^= unit;
    hash = sonnetImul(hash, 16777619);
  }
  return hash & 0xFFFFFFFF;
}

/// 数字种子加盐混合，让不同子系统互不相关。
int mixSonnetSeed(int seed, int salt) =>
    sonnetImul((seed ^ salt) & 0xFFFFFFFF, 2654435761);

/// 按元素下标取确定性的 0..1 抖动。
double sonnetHash01(int seed, int index, int salt) =>
    mixSonnetSeed(seed + sonnetImul(index + 1, 97), salt) / 4294967296.0;

/// 可连续取值的种子随机流（mulberry32，与 folia `createVisualizerRng` 同构）。
class SonnetRng {
  SonnetRng(int seed) : _state = seed & 0xFFFFFFFF;

  int _state;

  double next() {
    _state = (_state + 0x6D2B79F5) & 0xFFFFFFFF;
    int t = sonnetImul(_state ^ (_state >> 15), 1 | _state);
    t = ((t + sonnetImul(t ^ (t >> 7), 61 | t)) & 0xFFFFFFFF) ^ t;
    return ((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0;
  }
}

double _clamp(double v, double lo, double hi) => math.min(hi, math.max(lo, v));

// ---------------------------------------------------------------------------
// 类型
// ---------------------------------------------------------------------------

enum SonnetParagraphKind { breath, verse, lift, chorus, breakPart, outro }

enum SonnetParagraphBoundary {
  songStart,
  timeGap,
  metadata,
  durationCap,
  lineCap,
}

/// 七种镜头模板（顺序即 folia `SONNET_SHOT_KINDS`，参与种子选择，不可调换）。
enum SonnetShotKind {
  editorialColumn,
  typeImpact,
  fragmentCollage,
  trackingRibbon,
  maskReveal,
  posterBlocks,
  quietTableau,
}

/// 段落 / 镜头之间的三种转场（顺序即 folia `SONNET_TRANSITION_KINDS`）。
enum SonnetTransitionKind { fastBlur, monoGlitch, cameraPull }

/// 一个字形的时间（秒）。
class SonnetGrapheme {
  const SonnetGrapheme(this.char, this.start, this.end);

  final String char;
  final double start;
  final double end;
}

/// 语义片段：一个词（或粘上了标点的词）。
class SonnetSegment {
  SonnetSegment({
    required this.text,
    required this.startOffset,
    required this.endOffset,
    required this.start,
    required this.end,
    required this.graphemes,
    required this.isWordLike,
  });

  String text;
  final int startOffset;
  int endOffset;
  final double start;
  double end;
  final List<SonnetGrapheme> graphemes;
  final bool isWordLike;
}

class SonnetCompiledLine {
  const SonnetCompiledLine({
    required this.sourceIndex,
    required this.text,
    required this.start,
    required this.end,
    required this.renderEnd,
    required this.segments,
    this.isChorus = false,
    this.songPart,
    this.blockIndex,
  });

  /// 在 `runtime.lines` 里的下标（虚拟间奏行为负数以外的自增号）。
  final int sourceIndex;
  final String text;
  final double start;
  final double end;
  final double renderEnd;
  final List<SonnetSegment> segments;
  final bool isChorus;
  final String? songPart;
  final int? blockIndex;
}

/// 段落标注变了（folia `metadataChanged`）：两行都有编号且不同，或都有标注且不同。
bool _metadataChanged(SonnetCompiledLine previous, SonnetCompiledLine next) =>
    (previous.blockIndex != null &&
        next.blockIndex != null &&
        previous.blockIndex != next.blockIndex) ||
    (previous.songPart != null &&
        next.songPart != null &&
        previous.songPart != next.songPart);

final RegExp _chorusPartRe = RegExp('chorus|副歌', caseSensitive: false);
final RegExp _breakPartRe = RegExp(
  'bridge|break|間奏|ブリッジ',
  caseSensitive: false,
);

class SonnetCamera {
  const SonnetCamera(this.x, this.y, this.zoom, this.rotation);

  final double x;
  final double y;
  final double zoom;
  final double rotation;
}

class SonnetShot {
  const SonnetShot({
    required this.id,
    required this.kind,
    required this.start,
    required this.end,
    required this.lineIndices,
    required this.cueTimes,
    required this.camera,
  });

  final String id;
  final SonnetShotKind kind;
  final double start;
  final double end;
  final List<int> lineIndices;

  /// 每个片段的起点（folia `cues[].at`；MG 的绘制时长只看最后一个）。
  final List<double> cueTimes;
  final SonnetCamera camera;
}

class SonnetTransition {
  const SonnetTransition(this.kind, this.start, this.end);

  final SonnetTransitionKind kind;
  final double start;
  final double end;
}

class SonnetParagraph {
  const SonnetParagraph({
    required this.id,
    required this.kind,
    required this.boundary,
    required this.start,
    required this.end,
    required this.lines,
    required this.shots,
    required this.transitionOut,
  });

  final String id;
  final SonnetParagraphKind kind;
  final SonnetParagraphBoundary boundary;
  final double start;
  final double end;
  final List<SonnetCompiledLine> lines;
  final List<SonnetShot> shots;
  final SonnetTransition? transitionOut;
}

class SonnetProgram {
  const SonnetProgram({
    required this.seed,
    required this.paragraphGapThreshold,
    required this.paragraphs,
  });

  final String seed;
  final double paragraphGapThreshold;
  final List<SonnetParagraph> paragraphs;

  /// 当前时间所在段落（还没到第一段时为 0；folia `findSonnetParagraphIndexAtTime`）。
  int paragraphIndexAt(double time) {
    for (int i = paragraphs.length - 1; i >= 0; i--) {
      if (time >= paragraphs[i].start) return i;
    }
    return 0;
  }
}

// ---------------------------------------------------------------------------
// 源行：把 runtime 的行变成编译输入（含间奏虚拟行）
// ---------------------------------------------------------------------------

/// 编译输入的一行（秒）。
class SonnetSourceLine {
  const SonnetSourceLine({
    required this.text,
    required this.start,
    required this.end,
    required this.graphemes,
    this.wordRanges,
    this.isChorus = false,
    this.songPart,
    this.blockIndex,
  });

  final String text;
  final double start;
  final double end;
  final List<SonnetGrapheme> graphemes;

  /// 词组的字形区间 `[start, end)`（共享分词 `LyricVisualizerLine.segments`）；null = 现算。
  final List<(int, int)>? wordRanges;

  /// 副歌行（folia `line.isChorus`）。
  final bool isChorus;

  /// 来源的段落标注原文（folia `line.songPart`）；没有为 null。
  final String? songPart;

  /// 来源段落编号（folia `line.blockIndex`）；来源没有段落标注时为 null（段落只按空隙切）。
  final int? blockIndex;
}

/// runtime 行 → 编译输入。没有歌词（纯音乐）时与 folia 一样生成 60 行「♪」虚拟行，
/// 每 8 秒一行，画成五线谱。
List<SonnetSourceLine> sonnetSourceLinesOf(LyricVisualizerRuntime runtime) {
  if (runtime.lines.isEmpty) {
    return <SonnetSourceLine>[
      for (int i = 0; i < 60; i++)
        SonnetSourceLine(
          text: '♪',
          start: i * 8.0,
          end: i * 8.0 + 6,
          graphemes: <SonnetGrapheme>[SonnetGrapheme('♪', i * 8.0, i * 8 + 6)],
        ),
    ];
  }
  final bool sourced = runtime.hasSourceSongParts;
  return <SonnetSourceLine>[
    for (final LyricVisualizerLine l in runtime.lines)
      SonnetSourceLine(
        text: l.text,
        start: l.startMs / 1000,
        end: l.endMs / 1000,
        graphemes: <SonnetGrapheme>[
          for (final LyricVisualizerGlyph g in l.glyphs)
            SonnetGrapheme(g.text, g.startMs / 1000, g.endMs / 1000),
        ],
        wordRanges: <(int, int)>[
          for (final LyricVisualizerSegment s in l.segments)
            (s.firstGlyph, s.firstGlyph + s.glyphCount),
        ],
        isChorus: l.isChorus,
        songPart: l.songPartLabel,
        blockIndex: sourced ? l.blockIndex : null,
      ),
  ];
}

/// 行的视觉尾巴（folia `getLineRenderEndTime`）：正常行在末字之后再留出淡出时长。
double sonnetLineRenderEnd(SonnetSourceLine line) {
  final double raw = math.max(line.end - line.start, 0);
  final double lastWordEnd = line.graphemes.isEmpty
      ? line.end
      : line.graphemes.last.end;
  if (raw < 0.10) return math.max(line.end, line.start + 0.067);
  if (raw < 0.18) {
    final double enter = _clamp(raw * 0.45, 0.045, 0.06);
    final double exit = _clamp(raw * 0.22, 0.03, 0.04);
    final double passStart = math.max(lastWordEnd, line.start) + 0.03;
    final double exitStart = math.max(
      math.max(line.start + enter + 0.01, passStart),
      line.end - exit,
    );
    return math.max(line.end, exitStart + exit);
  }
  final double exit = math.min(
    0.32,
    math.max(0.18, math.max(raw, 0.12) * 0.18),
  );
  final double passStart = math.max(lastWordEnd, line.start) + 0.06;
  final double exitStart = math.max(passStart, line.end - exit);
  return math.max(line.end, exitStart + exit);
}

// ---------------------------------------------------------------------------
// 语义切词（folia `buildSonnetSemanticSegments`：词由共享分词给出，这里只补空白 / 标点并做粘连）
// ---------------------------------------------------------------------------

/// 字形 → 共享分词的词组区间（行里没带 [SonnetSourceLine.wordRanges] 时现算）。
List<(int, int)> _sharedWordRanges(List<SonnetGrapheme> g) {
  final List<LyricVisualizerGlyph> glyphs = <LyricVisualizerGlyph>[
    for (int i = 0; i < g.length; i++)
      LyricVisualizerGlyph(
        text: g[i].char,
        startMs: (g[i].start * 1000).round(),
        endMs: (g[i].end * 1000).round(),
        syllableIndex: i,
        isSpace: g[i].char.trim().isEmpty,
      ),
  ];
  return <(int, int)>[
    for (final LyricVisualizerSegment s in buildLyricVisualizerSegments(glyphs))
      (s.firstGlyph, s.firstGlyph + s.glyphCount),
  ];
}

/// 一行切成语义片段（字形下标区间 + 是否成词），再把非空白标点粘到前一段
/// （folia `buildSonnetSemanticSegments` 的 sticky 规则）。词组来自共享分词
/// （`LyricVisualizerLine.segments`）；词组之间的空白 / 孤立标点补成非词片段，整行不丢字。
List<SonnetSegment> buildSonnetSegments(SonnetSourceLine line) {
  final List<SonnetGrapheme> g = line.graphemes;
  final int n = g.length;
  final List<(int, int)> words = line.wordRanges ?? _sharedWordRanges(g);
  final List<(int, int, bool)> parts = <(int, int, bool)>[];
  int cursor = 0;
  void gapUntil(int to) {
    // 词组之间的空白与标点：空白、非空白各成一段。
    while (cursor < to) {
      final bool space = g[cursor].char.trim().isEmpty;
      int j = cursor;
      while (j < to && g[j].char.trim().isEmpty == space) {
        j++;
      }
      parts.add((cursor, j, false));
      cursor = j;
    }
  }

  for (final (int a, int b) in words) {
    final int s = a.clamp(0, n);
    final int e = b.clamp(s, n);
    if (e <= cursor) continue;
    gapUntil(math.max(cursor, s));
    parts.add((math.max(cursor, s), e, true));
    cursor = e;
  }
  gapUntil(n);

  final List<SonnetSegment> out = <SonnetSegment>[];
  for (final (int s, int e, bool word) in parts) {
    final List<SonnetGrapheme> gs = g.sublist(s, e);
    final String text = gs.map((SonnetGrapheme x) => x.char).join();
    final SonnetSegment? previous = out.isEmpty ? null : out.last;
    if (previous != null && !word && text.trim().isNotEmpty) {
      previous.text += text;
      previous.endOffset = e;
      previous.end = math.max(previous.end, gs.last.end);
      previous.graphemes.addAll(gs);
      continue;
    }
    out.add(
      SonnetSegment(
        text: text,
        startOffset: s,
        endOffset: e,
        start: gs.isEmpty ? line.start : gs.first.start,
        end: gs.isEmpty ? line.end : gs.last.end,
        graphemes: List<SonnetGrapheme>.of(gs),
        isWordLike: word,
      ),
    );
  }
  return out;
}

// ---------------------------------------------------------------------------
// 编译
// ---------------------------------------------------------------------------

double _median(List<double> values) {
  if (values.isEmpty) return 0.5;
  final List<double> sorted = List<double>.of(values)..sort();
  final int mid = sorted.length ~/ 2;
  return sorted.length.isEven
      ? (sorted[mid - 1] + sorted[mid]) / 2
      : sorted[mid];
}

/// 段落断点阈值：行间空隙中位数的 2.5 倍，夹在 1.25–3.5 秒。
double resolveSonnetParagraphGapThreshold(List<SonnetSourceLine> lines) {
  final List<double> gaps = <double>[];
  for (int i = 1; i < lines.length; i++) {
    final double gap =
        lines[i].start -
        math.min(sonnetLineRenderEnd(lines[i - 1]), lines[i].start);
    if (gap > 0) gaps.add(gap);
  }
  return _clamp(_median(gaps) * 2.5, 1.25, 3.5);
}

class _Draft {
  _Draft(this.lines, this.boundary);

  final List<SonnetCompiledLine> lines;
  final SonnetParagraphBoundary boundary;
}

List<_Draft> _splitOversized(_Draft draft) {
  final List<_Draft> out = <_Draft>[];
  List<SonnetCompiledLine> remaining = draft.lines;
  SonnetParagraphBoundary boundary = draft.boundary;
  int guard = 0;
  while (remaining.length > 6 ||
      (remaining.length > 1 &&
          remaining.last.renderEnd - remaining.first.start > 18)) {
    if (guard++ > 1000) break;
    int? best;
    double bestGap = double.negativeInfinity;
    // 候选断点 2..length-2，取前后空隙最大的（并列取最早的）。
    for (int offset = 0; offset + 2 < remaining.length - 1; offset++) {
      final int splitIndex = offset + 2;
      final double gap =
          remaining[splitIndex].start - remaining[offset + 1].renderEnd;
      if (gap.isNaN) continue;
      if (gap > bestGap) {
        bestGap = gap;
        best = splitIndex;
      }
    }
    final int splitIndex = math.max(
      1,
      best ?? math.min(4, remaining.length - 1),
    );
    out.add(_Draft(remaining.sublist(0, splitIndex), boundary));
    remaining = remaining.sublist(splitIndex);
    boundary = out.last.lines.length >= 6
        ? SonnetParagraphBoundary.lineCap
        : SonnetParagraphBoundary.durationCap;
  }
  out.add(_Draft(remaining, boundary));
  return out;
}

final RegExp _punctRe = RegExp(r'[!?！？…]');

SonnetParagraphKind _classify(
  List<SonnetCompiledLine> lines,
  int index,
  int total,
) {
  if (lines.any(
    (SonnetCompiledLine l) =>
        l.isChorus || _chorusPartRe.hasMatch(l.songPart ?? ''),
  )) {
    return SonnetParagraphKind.chorus;
  }
  if (lines.any(
    (SonnetCompiledLine l) => _breakPartRe.hasMatch(l.songPart ?? ''),
  )) {
    return SonnetParagraphKind.breakPart;
  }
  if (index == total - 1) return SonnetParagraphKind.outro;
  final double duration = lines.last.renderEnd - lines.first.start;
  int segmentCount = 0;
  int punctuation = 0;
  for (final SonnetCompiledLine l in lines) {
    segmentCount += l.segments.where((SonnetSegment s) => s.isWordLike).length;
    punctuation += _punctRe.allMatches(l.text).length;
  }
  if (duration <= 3.5 || segmentCount <= 3) return SonnetParagraphKind.breath;
  if (punctuation >= 2 || segmentCount / math.max(duration, 1) > 2.5) {
    return SonnetParagraphKind.lift;
  }
  return SonnetParagraphKind.verse;
}

T _chooseWithoutRepeat<T>(List<T> choices, String seed, T? previous) {
  final int start = hashSonnetSeed(seed) % choices.length;
  for (int offset = 0; offset < choices.length; offset++) {
    final T candidate = choices[(start + offset) % choices.length];
    if (candidate != previous) return candidate;
  }
  return choices[start];
}

List<List<SonnetCompiledLine>> _groupShotLines(List<SonnetCompiledLine> lines) {
  final List<List<SonnetCompiledLine>> groups = <List<SonnetCompiledLine>>[];
  List<SonnetCompiledLine> current = <SonnetCompiledLine>[];
  double groupStart = 0;
  for (final SonnetCompiledLine line in lines) {
    if (current.isEmpty) {
      current.add(line);
      groupStart = line.start;
    } else if (current.length < 4 && line.renderEnd - groupStart <= 6.0) {
      current.add(line);
    } else {
      groups.add(current);
      current = <SonnetCompiledLine>[line];
      groupStart = line.start;
    }
  }
  if (current.isNotEmpty) groups.add(current);
  return groups;
}

/// folia 镜头 kind 的字符串 id（参与种子散列时用原名，保证同一首歌的选择与 folia 一致）。
String sonnetShotKindId(SonnetShotKind kind) => const <String>[
  'editorial-column',
  'type-impact',
  'fragment-collage',
  'tracking-ribbon',
  'mask-reveal',
  'poster-blocks',
  'quiet-tableau',
][kind.index];

List<SonnetShot> _buildShots(
  List<SonnetCompiledLine> lines,
  SonnetParagraphKind kind,
  int paragraphIndex,
  String seed,
  SonnetShotKind? previousKind,
) {
  SonnetShotKind? lastKind = previousKind;
  final List<List<SonnetCompiledLine>> groups = _groupShotLines(lines);
  final List<SonnetShot> out = <SonnetShot>[];
  for (int shotIndex = 0; shotIndex < groups.length; shotIndex++) {
    final List<SonnetCompiledLine> group = groups[shotIndex];
    final String signature = group
        .map((SonnetCompiledLine l) => l.text)
        .join('|');
    SonnetShotKind shotKind = _chooseWithoutRepeat<SonnetShotKind>(
      SonnetShotKind.values,
      '$seed:$paragraphIndex:$shotIndex:$signature',
      lastKind,
    );
    int wordCount = 0;
    for (final SonnetCompiledLine l in group) {
      wordCount += l.segments.where((SonnetSegment s) => s.isWordLike).length;
    }
    if (kind == SonnetParagraphKind.breath &&
        shotIndex == 0 &&
        wordCount <= 2) {
      shotKind = SonnetShotKind.quietTableau;
    }
    if (kind == SonnetParagraphKind.chorus &&
        shotKind == SonnetShotKind.quietTableau) {
      shotKind = SonnetShotKind.typeImpact;
    }
    lastKind = shotKind;
    final int random = hashSonnetSeed(
      '$seed:$paragraphIndex:$shotIndex:camera',
    );
    final double zoomRandom = ((random >> 16) & 255) / 255;
    final double zoomBase = shotKind == SonnetShotKind.posterBlocks
        ? 1.02
        : shotKind == SonnetShotKind.quietTableau
        ? 1.12
        : 1.22;
    final double zoomSpan = shotKind == SonnetShotKind.posterBlocks
        ? 0.16
        : shotKind == SonnetShotKind.quietTableau
        ? 0.2
        : 0.26;
    final List<double> cues = <double>[
      for (final SonnetCompiledLine l in group)
        for (final SonnetSegment s in l.segments)
          if (s.text.isNotEmpty) s.start,
    ];
    out.add(
      SonnetShot(
        id: 'p$paragraphIndex-s$shotIndex',
        kind: shotKind,
        start: group.first.start,
        end: group.last.renderEnd,
        lineIndices: <int>[
          for (final SonnetCompiledLine l in group) l.sourceIndex,
        ],
        cueTimes: cues,
        camera: SonnetCamera(
          ((random & 255) / 255 - 0.5) * 0.18,
          (((random >> 8) & 255) / 255 - 0.5) * 0.14,
          zoomBase + zoomRandom * zoomSpan,
          (((random >> 24) & 255) / 255 - 0.5) * 0.08,
        ),
      ),
    );
  }
  return out;
}

/// 编译整首（folia `compileSonnetProgram`）。
SonnetProgram compileSonnetProgram(List<SonnetSourceLine> lines, String seed) {
  final List<SonnetCompiledLine> compiled = <SonnetCompiledLine>[
    for (int i = 0; i < lines.length; i++)
      SonnetCompiledLine(
        sourceIndex: i,
        text: lines[i].text,
        start: lines[i].start,
        end: lines[i].end,
        renderEnd: math.max(
          lines[i].start,
          math.min(
            sonnetLineRenderEnd(lines[i]),
            i + 1 < lines.length ? lines[i + 1].start : double.infinity,
          ),
        ),
        segments: buildSonnetSegments(lines[i]),
        isChorus: lines[i].isChorus,
        songPart: lines[i].songPart,
        blockIndex: lines[i].blockIndex,
      ),
  ];
  final double threshold = resolveSonnetParagraphGapThreshold(lines);
  final List<_Draft> drafts = <_Draft>[];
  _Draft current = _Draft(
    <SonnetCompiledLine>[],
    SonnetParagraphBoundary.songStart,
  );
  for (int i = 0; i < compiled.length; i++) {
    final SonnetCompiledLine line = compiled[i];
    final SonnetCompiledLine? previous = i > 0 ? compiled[i - 1] : null;
    final double gap = previous == null ? 0 : line.start - previous.renderEnd;
    final SonnetParagraphBoundary? boundary = previous == null
        ? null
        : _metadataChanged(previous, line)
        ? SonnetParagraphBoundary.metadata
        : gap >= threshold
        ? SonnetParagraphBoundary.timeGap
        : null;
    if (boundary != null && current.lines.isNotEmpty) {
      drafts.addAll(_splitOversized(current));
      current = _Draft(<SonnetCompiledLine>[], boundary);
    }
    current.lines.add(line);
  }
  if (current.lines.isNotEmpty) drafts.addAll(_splitOversized(current));

  SonnetShotKind? previousShot;
  SonnetTransitionKind? previousTransition;
  final List<SonnetParagraph> paragraphs = <SonnetParagraph>[];
  for (int index = 0; index < drafts.length; index++) {
    final _Draft draft = drafts[index];
    final SonnetParagraphKind kind = _classify(
      draft.lines,
      index,
      drafts.length,
    );
    final List<SonnetShot> shots = _buildShots(
      draft.lines,
      kind,
      index,
      seed,
      previousShot,
    );
    if (shots.isNotEmpty) previousShot = shots.last.kind;
    final _Draft? next = index + 1 < drafts.length ? drafts[index + 1] : null;
    final double endTime = draft.lines.last.renderEnd;
    final double gap = next == null ? 0 : next.lines.first.start - endTime;
    SonnetTransition? transition;
    if (next != null) {
      final SonnetTransitionKind tk =
          _chooseWithoutRepeat<SonnetTransitionKind>(
            SonnetTransitionKind.values,
            '$seed:$index:transition',
            previousTransition,
          );
      previousTransition = tk;
      final double duration = math.min(
        0.3,
        math.max(0.16, gap > 0 ? gap * 0.5 : 0.2),
      );
      final double tEnd = next.lines.first.start;
      transition = SonnetTransition(
        tk,
        math.max(draft.lines.first.start, tEnd - duration),
        tEnd,
      );
    }
    paragraphs.add(
      SonnetParagraph(
        id: 'sonnet-p$index',
        kind: kind,
        boundary: draft.boundary,
        start: draft.lines.first.start,
        end: endTime,
        lines: draft.lines,
        shots: shots,
        transitionOut: transition,
      ),
    );
  }
  return SonnetProgram(
    seed: seed,
    paragraphGapThreshold: threshold,
    paragraphs: paragraphs,
  );
}
