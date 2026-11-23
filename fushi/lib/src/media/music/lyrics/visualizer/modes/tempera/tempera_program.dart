/// 凝彩的编译期（folia `temperaProgram.ts`）：把整首歌词编成可随意拖动的确定性 PV 时间线——
/// 段落 → 半句切成的分镜（shot）→ 分镜里的词段（slice）、镜头关键帧、装饰。渲染层零随机。
///
/// 时间一律是秒（folia 同口径），由歌词显示毫秒换算。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_profiles.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_random.dart';

/// 一个字（grapheme）的时间。
class TemperaGrapheme {
  const TemperaGrapheme({
    required this.char,
    required this.startTime,
    required this.endTime,
  });

  final String char;
  final double startTime;
  final double endTime;
}

/// 一个词段：排版的最小单位（定字号层级用，不影响字距）。
class TemperaSegment {
  TemperaSegment({
    required this.text,
    required this.startOffset,
    required this.endOffset,
    required this.startTime,
    required this.endTime,
    required this.graphemes,
    required this.isWordLike,
  });

  String text;

  /// 行内字形下标区间（半开），用来判断两个词之间原文是否真有空白。
  final int startOffset;
  int endOffset;
  final double startTime;
  double endTime;
  final List<TemperaGrapheme> graphemes;
  final bool isWordLike;
}

/// 编译过的一行。
class TemperaCompiledLine {
  const TemperaCompiledLine({
    required this.sourceIndex,
    required this.startTime,
    required this.endTime,
    required this.text,
    required this.renderEndTime,
    required this.segments,
    this.isChorus = false,
    this.songPart,
    this.blockIndex,
  });

  /// 在 runtime.lines 里的下标。
  final int sourceIndex;
  final double startTime;
  final double endTime;
  final String text;
  final double renderEndTime;
  final List<TemperaSegment> segments;

  /// 副歌行（folia `line.isChorus`）。
  final bool isChorus;

  /// 来源段落标注原文（folia `line.songPart`）。
  final String? songPart;

  /// 来源段落编号；来源没有段落标注时 null（段落只按空隙切）。
  final int? blockIndex;
}

/// 段落标注变了（folia `metadataChanged`）。
bool _metadataChanged(TemperaCompiledLine previous, TemperaCompiledLine next) =>
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

/// 镜头关键帧（视口比例位移）。
class TemperaCameraKey {
  const TemperaCameraKey({
    required this.x,
    required this.y,
    required this.zoom,
    required this.rotation,
  });

  final double x;
  final double y;
  final double zoom;
  final double rotation;
}

/// 稀疏构图边角的碎字。
class TemperaDecorFragment {
  const TemperaDecorFragment({
    required this.char,
    required this.x,
    required this.y,
    required this.rotation,
    required this.scale,
  });

  final String char;
  final double x;
  final double y;
  final double rotation;
  final double scale;
}

/// 构图后面的超大装饰词（水印）。
class TemperaDecorWatermark {
  const TemperaDecorWatermark({
    required this.text,
    required this.x,
    required this.y,
    required this.rotation,
    required this.scale,
  });

  final String text;
  final double x;
  final double y;
  final double rotation;

  /// 分镜基础字号的倍数。
  final double scale;
}

/// 一个分镜的网点装饰，编译期定死。
class TemperaDecorSpec {
  const TemperaDecorSpec({
    required this.motif,
    required this.hatchAngle,
    required this.crossCount,
    required this.scribbleSeed,
    required this.fragments,
    required this.watermark,
  });

  final String motif;
  final double hatchAngle;
  final int crossCount;
  final int scribbleSeed;
  final List<TemperaDecorFragment> fragments;
  final TemperaDecorWatermark? watermark;
}

/// 分镜里的一段歌词：某一行的半开词段区间。
class TemperaShotSlice {
  const TemperaShotSlice({
    required this.lineIndex,
    required this.segmentStart,
    required this.segmentEnd,
  });

  final int lineIndex;
  final int segmentStart;
  final int segmentEnd;
}

/// 一个分镜。
class TemperaShot {
  TemperaShot({
    required this.id,
    required this.kind,
    required this.startTime,
    required this.endTime,
    required this.lyricEndTime,
    required this.slices,
    required this.isBridge,
    required this.camera,
    required this.cameraEnd,
    required this.flowAngle,
    required this.decor,
  });

  final String id;
  final String kind;

  /// 段落首个分镜会被提前到上一段转场起点（预卷），所以可变。
  double startTime;

  /// 平铺到下一个分镜起点（收尾分镜顶到段落 render tail），不是歌词结束。
  final double endTime;

  /// 本分镜最后一个字唱完的时刻；色块 / 图片的入场节奏按它排。
  final double lyricEndTime;
  final List<TemperaShotSlice> slices;

  /// 间奏分镜：没有歌词，只有构图。
  final bool isBridge;
  final TemperaCameraKey camera;
  final TemperaCameraKey cameraEnd;

  /// 图形整体流动方向（弧度）；相邻分镜只小幅转向，交接读作一个连续运动。
  final double flowAngle;
  final TemperaDecorSpec decor;
}

/// 段落转场。
class TemperaTransition {
  const TemperaTransition({
    required this.kind,
    required this.startTime,
    required this.endTime,
  });

  final String kind;
  final double startTime;
  final double endTime;
}

/// 段落类型。
enum TemperaParagraphKind { breath, verse, lift, chorus, breakPart, outro }

/// 一个段落。
class TemperaParagraph {
  const TemperaParagraph({
    required this.id,
    required this.kind,
    required this.startTime,
    required this.endTime,
    required this.lines,
    required this.shots,
    required this.transitionOut,
  });

  final String id;
  final TemperaParagraphKind kind;
  final double startTime;
  final double endTime;
  final List<TemperaCompiledLine> lines;
  final List<TemperaShot> shots;
  final TemperaTransition? transitionOut;
}

/// 整首编译结果。
class TemperaProgram {
  const TemperaProgram({
    required this.seed,
    required this.paragraphGapThreshold,
    required this.paragraphs,
  });

  final String seed;
  final double paragraphGapThreshold;
  final List<TemperaParagraph> paragraphs;
}

// ---------------------------------------------------------------------------
// 分词（folia 走共享的 wordSegmentation：这里用框架的共享词组 `LyricVisualizerLine.segments`）
// ---------------------------------------------------------------------------

/// 行里的字形区间切成「词 / 非词」段：词组来自共享分词，词组之间的空白、孤立标点补成非词段。
List<(int, int, bool)> temperaSegmentRanges(LyricVisualizerLine line) {
  final List<LyricVisualizerGlyph> g = line.glyphs;
  final int n = g.length;
  final List<(int, int, bool)> out = <(int, int, bool)>[];
  int cursor = 0;
  void gapUntil(int to) {
    while (cursor < to) {
      final bool space = g[cursor].text.trim().isEmpty;
      int j = cursor;
      while (j < to && g[j].text.trim().isEmpty == space) {
        j++;
      }
      out.add((cursor, j, false));
      cursor = j;
    }
  }

  for (final LyricVisualizerSegment seg in line.segments) {
    final int start = seg.firstGlyph.clamp(0, n);
    final int end = (seg.firstGlyph + seg.glyphCount).clamp(start, n);
    if (end <= cursor) continue;
    gapUntil(math.max(cursor, start));
    out.add((math.max(cursor, start), end, true));
    cursor = end;
  }
  gapUntil(n);
  return out;
}

/// 一行 → 词段；标点粘到前一个词上（folia `buildTemperaSegments`）。
List<TemperaSegment> buildTemperaSegments(LyricVisualizerLine line) {
  final List<LyricVisualizerGlyph> glyphs = line.glyphs;
  if (glyphs.isEmpty) return <TemperaSegment>[];
  final List<String> chars = glyphs
      .map((LyricVisualizerGlyph g) => g.text)
      .toList();
  final List<TemperaSegment> segments = <TemperaSegment>[];
  for (final (int s, int e, bool word) in temperaSegmentRanges(line)) {
    final List<TemperaGrapheme> gs = <TemperaGrapheme>[
      for (int k = s; k < e; k++)
        TemperaGrapheme(
          char: glyphs[k].text,
          startTime: glyphs[k].startMs / 1000,
          endTime: glyphs[k].endMs / 1000,
        ),
    ];
    segments.add(
      TemperaSegment(
        text: chars.sublist(s, e).join(),
        startOffset: s,
        endOffset: e,
        startTime: gs.isEmpty ? line.startMs / 1000 : gs.first.startTime,
        endTime: gs.isEmpty ? line.endMs / 1000 : gs.last.endTime,
        graphemes: gs,
        isWordLike: word,
      ),
    );
  }
  final List<TemperaSegment> sticky = <TemperaSegment>[];
  for (final TemperaSegment segment in segments) {
    final TemperaSegment? previous = sticky.isEmpty ? null : sticky.last;
    if (previous != null &&
        !segment.isWordLike &&
        segment.text.trim().isNotEmpty) {
      previous.text += segment.text;
      previous.endOffset = segment.endOffset;
      // 没有自己时间的标点钉到前一个词的末尾，不然它会跟下一个词一起入场。
      final double tail = previous.endTime;
      for (final TemperaGrapheme g in segment.graphemes) {
        final TemperaGrapheme merged = g.endTime > g.startTime
            ? g
            : TemperaGrapheme(char: g.char, startTime: tail, endTime: tail);
        previous.graphemes.add(merged);
        previous.endTime = math.max(previous.endTime, merged.endTime);
      }
    } else {
      sticky.add(
        TemperaSegment(
          text: segment.text,
          startOffset: segment.startOffset,
          endOffset: segment.endOffset,
          startTime: segment.startTime,
          endTime: segment.endTime,
          graphemes: <TemperaGrapheme>[...segment.graphemes],
          isWordLike: segment.isWordLike,
        ),
      );
    }
  }
  return sticky;
}

double _clamp(double v, double lo, double hi) => math.min(hi, math.max(lo, v));

// ---------------------------------------------------------------------------
// 编译
// ---------------------------------------------------------------------------

double _median(List<double> values) {
  if (values.isEmpty) return 0.5;
  final List<double> sorted = <double>[...values]..sort();
  final int mid = sorted.length ~/ 2;
  return sorted.length.isEven
      ? (sorted[mid - 1] + sorted[mid]) / 2
      : sorted[mid];
}

/// 段落切分阈值：行间隙中位数的 2.5 倍，钳在 1.25–3.5 秒。
double temperaParagraphGapThreshold(List<TemperaCompiledLine> lines) {
  final List<double> gaps = <double>[];
  for (int i = 1; i < lines.length; i++) {
    final double gap =
        lines[i].startTime -
        math.min(lines[i - 1].renderEndTime, lines[i].startTime);
    if (gap > 0) gaps.add(gap);
  }
  return _clamp(_median(gaps) * 2.5, 1.25, 3.5);
}

List<List<TemperaCompiledLine>> _splitOversized(
  List<TemperaCompiledLine> draft,
) {
  final List<List<TemperaCompiledLine>> out = <List<TemperaCompiledLine>>[];
  List<TemperaCompiledLine> remaining = draft;
  int guard = 0;
  while (remaining.length > 6 ||
      (remaining.length > 1 &&
          remaining.last.renderEndTime - remaining.first.startTime > 18)) {
    if (guard++ > 1000) break;
    int splitIndex = math.min(4, remaining.length - 1);
    double best = double.negativeInfinity;
    for (int offset = 0; offset + 2 < remaining.length - 1; offset++) {
      final double gap =
          remaining[offset + 2].startTime - remaining[offset + 1].renderEndTime;
      if (gap > best) {
        best = gap;
        splitIndex = offset + 2;
      }
    }
    splitIndex = math.max(1, splitIndex);
    out.add(remaining.sublist(0, splitIndex));
    remaining = remaining.sublist(splitIndex);
  }
  out.add(remaining);
  return out;
}

final RegExp _exclaim = RegExp(r'[!?！？…]');

TemperaParagraphKind _classifyParagraph(
  List<TemperaCompiledLine> lines,
  int index,
  int total,
) {
  if (lines.any(
    (TemperaCompiledLine l) =>
        l.isChorus || _chorusPartRe.hasMatch(l.songPart ?? ''),
  )) {
    return TemperaParagraphKind.chorus;
  }
  if (lines.any(
    (TemperaCompiledLine l) => _breakPartRe.hasMatch(l.songPart ?? ''),
  )) {
    return TemperaParagraphKind.breakPart;
  }
  if (index == total - 1) return TemperaParagraphKind.outro;
  final double duration = lines.last.renderEndTime - lines.first.startTime;
  int segmentCount = 0;
  int punctuationCount = 0;
  for (final TemperaCompiledLine l in lines) {
    segmentCount += l.segments.where((TemperaSegment s) => s.isWordLike).length;
    punctuationCount += _exclaim.allMatches(l.text).length;
  }
  if (duration <= 3.5 || segmentCount <= 3) return TemperaParagraphKind.breath;
  if (punctuationCount >= 2 || segmentCount / math.max(duration, 1) > 2.5) {
    return TemperaParagraphKind.lift;
  }
  return TemperaParagraphKind.verse;
}

class _Chunk {
  _Chunk(
    this.lineIndex,
    this.segmentStart,
    this.segmentEnd,
    this.startTime,
    this.endTime,
    this.lyricEndTime,
  );

  final int lineIndex;
  final int segmentStart;
  final int segmentEnd;
  final double startTime;
  double endTime;
  final double lyricEndTime;
}

final RegExp _punctuationOnly = RegExp(r'^[\s\p{P}\p{S}]+$', unicode: true);
final RegExp _han = RegExp(r'^\p{Script=Han}$', unicode: true);

bool _renderable(TemperaSegment s) =>
    s.text.trim().isNotEmpty && s.graphemes.isNotEmpty;

bool _singleHan(TemperaSegment s) => s.isWordLike && _han.hasMatch(s.text);

const double _singleHanGlueMax = 3.2;

/// 默认按 2–4 词或约 2.2 秒切成半句；整句模式每行一个 chunk。
List<_Chunk> _buildChunks(
  List<TemperaCompiledLine> lines,
  String seed,
  int paragraphIndex,
  bool wholeLine,
) {
  final List<_Chunk> chunks = <_Chunk>[];
  for (final TemperaCompiledLine line in lines) {
    final List<(TemperaSegment, int)> usable = <(TemperaSegment, int)>[
      for (int i = 0; i < line.segments.length; i++)
        if (_renderable(line.segments[i])) (line.segments[i], i),
    ];
    if (usable.isEmpty) continue;
    if (wholeLine) {
      final (TemperaSegment first, int fi) = usable.first;
      final (TemperaSegment last, int li) = usable.last;
      final double end = math.max(last.endTime, first.startTime + 0.2);
      chunks.add(
        _Chunk(line.sourceIndex, fi, li + 1, first.startTime, end, end),
      );
      continue;
    }
    int segmentStart = usable.first.$2;
    double startTime = usable.first.$1.startTime;
    int words = 0;
    for (int order = 0; order < usable.length; order++) {
      final (TemperaSegment seg, int index) = usable[order];
      words += 1;
      final int chunkSeed = temperaHashSeed(
        '$seed:$paragraphIndex:${line.sourceIndex}:${chunks.length}',
      );
      final int target = 2 + (temperaHash01(chunkSeed, 1, 179) * 3).floor();
      final double spent = seg.endTime - startTime;
      final bool isLast = order == usable.length - 1;
      if (!isLast && words < target && spent < 2.2) continue;
      final (TemperaSegment, int)? next = isLast ? null : usable[order + 1];
      if (!isLast &&
          spent < _singleHanGlueMax &&
          next != null &&
          _singleHan(seg) &&
          _singleHan(next.$1) &&
          next.$1.startOffset == seg.endOffset) {
        continue;
      }
      final double end = math.max(seg.endTime, startTime + 0.2);
      chunks.add(
        _Chunk(line.sourceIndex, segmentStart, index + 1, startTime, end, end),
      );
      if (next != null) {
        segmentStart = next.$2;
        startTime = next.$1.startTime;
        words = 0;
      }
    }
  }
  for (int i = 0; i < chunks.length; i++) {
    final _Chunk c = chunks[i];
    c.endTime = math.max(
      c.startTime + 0.2,
      i + 1 < chunks.length ? chunks[i + 1].startTime : c.endTime,
    );
  }
  return chunks;
}

(TemperaCameraKey, TemperaCameraKey) _cameraKeys(
  String kind,
  int seed,
  double flowAngle,
) {
  final double jx = (temperaHash01(seed, 1, 11) - 0.5) * 0.02;
  final double jy = (temperaHash01(seed, 2, 23) - 0.5) * 0.02;
  final double jz = temperaHash01(seed, 3, 37) * 0.025;
  final double jr = (temperaHash01(seed, 4, 51) - 0.5) * 0.012;
  final TemperaShotProfile p = temperaShotProfile(kind);
  final double tx = math.cos(flowAngle) * p.travel;
  final double ty = math.sin(flowAngle) * p.travel;
  return (
    TemperaCameraKey(
      x: -tx / 2 + jx,
      y: -ty / 2 + jy,
      zoom: p.zoomStart + jz,
      rotation: jr,
    ),
    TemperaCameraKey(
      x: tx / 2 + jx,
      y: ty / 2 + jy,
      zoom: p.zoomEnd + jz,
      rotation: -jr,
    ),
  );
}

List<String> _graphemesOf(String s) =>
    s.runes.map(String.fromCharCode).toList(); // 碎字只取单个码点，合字场景无所谓

List<TemperaDecorFragment> _fragments(String pool, int count, int seed) {
  final List<String> chars = _graphemesOf(pool)
      .where((String c) => c.trim().isNotEmpty && !_punctuationOnly.hasMatch(c))
      .toList();
  if (chars.isEmpty || count <= 0) return const <TemperaDecorFragment>[];
  return List<TemperaDecorFragment>.generate(count, (int i) {
    final String char =
        chars[(temperaHash01(seed, i, 13) * chars.length).floor() %
            chars.length];
    final bool onLeft = temperaHash01(seed, i, 29) > 0.5;
    final double edge = 0.03 + temperaHash01(seed, i, 41) * 0.13;
    return TemperaDecorFragment(
      char: char,
      x: onLeft ? edge : 1 - edge,
      y: 0.08 + temperaHash01(seed, i, 53) * 0.84,
      rotation: (temperaHash01(seed, i, 67) - 0.5) * 0.5,
      scale: 0.26 + temperaHash01(seed, i, 71) * 0.2,
    );
  });
}

TemperaDecorWatermark? _watermark(List<String> pool, int seed, bool allowed) {
  final List<String> words = pool
      .map((String w) => w.trim())
      .where((String w) => w.isNotEmpty && w.length <= 12)
      .toList();
  if (!allowed || words.isEmpty || temperaHash01(seed, 4, 107) > 0.62) {
    return null;
  }
  return TemperaDecorWatermark(
    text:
        words[(temperaHash01(seed, 5, 109) * words.length).floor() %
            words.length],
    x: 0.28 + temperaHash01(seed, 6, 113) * 0.44,
    y: 0.26 + temperaHash01(seed, 7, 127) * 0.48,
    rotation: (temperaHash01(seed, 8, 131) - 0.5) * 0.5,
    scale: 2.6 + temperaHash01(seed, 9, 137) * 1.9,
  );
}

TemperaDecorSpec _decorSpec(
  TemperaParagraphKind paragraphKind,
  String shotKind,
  String seedKey,
  String fragmentPool,
  List<String> watermarkPool,
  String? previousMotif,
) {
  final int seed = temperaHashSeed(seedKey);
  final String motif = temperaChooseWithoutRepeat<String>(
    temperaDecorMotifs,
    seedKey,
    previousMotif,
  );
  final TemperaMood mood = temperaShotProfile(shotKind).mood;
  final bool sparse =
      mood == TemperaMood.quiet ||
      paragraphKind == TemperaParagraphKind.breakPart ||
      paragraphKind == TemperaParagraphKind.outro;
  return TemperaDecorSpec(
    motif: motif,
    hatchAngle: (temperaHash01(seed, 1, 83) - 0.5) * (math.pi / 2),
    crossCount: 1 + (temperaHash01(seed, 2, 89) * 3).floor(),
    scribbleSeed: temperaMixSeed(seed, 97),
    fragments: sparse
        ? _fragments(
            fragmentPool,
            3 + (temperaHash01(seed, 3, 101) * 3).floor(),
            seed,
          )
        : const <TemperaDecorFragment>[],
    watermark: _watermark(watermarkPool, seed, mood != TemperaMood.loud),
  );
}

/// 纵向为主轴：每个分镜小幅转向，并往主轴回拉。
double _flowAngle(double? previous, int seed) {
  if (previous == null) {
    final double sign = temperaHash01(seed, 6, 71) > 0.5 ? 1 : -1;
    return sign * math.pi / 2 + (temperaHash01(seed, 8, 79) - 0.5) * 0.4;
  }
  final double axis = (math.sin(previous) >= 0 ? 1 : -1) * math.pi / 2;
  return previous +
      (axis - previous) * 0.3 +
      (temperaHash01(seed, 7, 73) - 0.5) * 0.5;
}

class _Thread {
  String? kind;
  String? motif;
  double? flow;
}

List<TemperaShot> _buildShots(
  List<TemperaCompiledLine> lines,
  List<TemperaCompiledLine> songLines,
  TemperaParagraphKind kind,
  int paragraphIndex,
  String seed,
  _Thread thread,
  bool wholeLine,
) {
  final double paragraphEnd = lines.isEmpty ? 0 : lines.last.renderEndTime;
  final List<_Chunk> chunks = _buildChunks(
    lines,
    seed,
    paragraphIndex,
    wholeLine,
  );
  final Map<int, TemperaCompiledLine> byIndex = <int, TemperaCompiledLine>{
    for (final TemperaCompiledLine l in lines) l.sourceIndex: l,
  };
  final List<TemperaShot> shots = <TemperaShot>[];
  for (int shotIndex = 0; shotIndex < chunks.length; shotIndex++) {
    final _Chunk chunk = chunks[shotIndex];
    final TemperaCompiledLine? line = byIndex[chunk.lineIndex];
    final List<TemperaSegment> slice =
        line?.segments.sublist(chunk.segmentStart, chunk.segmentEnd) ??
        const <TemperaSegment>[];
    final String sliceText = slice.map((TemperaSegment s) => s.text).join();
    final int wordCount = slice
        .where((TemperaSegment s) => s.isWordLike)
        .length;
    final bool sparse =
        kind == TemperaParagraphKind.breath ||
        (kind != TemperaParagraphKind.chorus && wordCount <= 2);
    final List<TemperaMood> moods = sparse
        ? const <TemperaMood>[TemperaMood.quiet]
        : kind == TemperaParagraphKind.chorus
        ? const <TemperaMood>[TemperaMood.neutral, TemperaMood.loud]
        : const <TemperaMood>[
            TemperaMood.quiet,
            TemperaMood.neutral,
            TemperaMood.loud,
          ];
    final String shotKind = temperaChooseWithoutRepeat<String>(
      temperaShotCandidates(moods),
      '$seed:$paragraphIndex:$shotIndex:$sliceText',
      thread.kind,
    );
    thread.kind = shotKind;
    final int cameraSeed = temperaHashSeed(
      '$seed:$paragraphIndex:$shotIndex:camera',
    );
    final double flow = _flowAngle(thread.flow, cameraSeed);
    thread.flow = flow;
    final (TemperaCameraKey start, TemperaCameraKey end) = _cameraKeys(
      shotKind,
      cameraSeed,
      flow,
    );
    // 碎字与水印取本段其他词，绝不重复画面上已有的字；整句一段时向全曲借。
    final List<TemperaSegment> outside = <TemperaSegment>[
      for (final TemperaCompiledLine item in lines)
        if (item.sourceIndex == chunk.lineIndex)
          for (int i = 0; i < item.segments.length; i++)
            if (i < chunk.segmentStart || i >= chunk.segmentEnd)
              item.segments[i]
            else
              ...<TemperaSegment>[]
        else
          ...item.segments,
    ];
    final List<TemperaSegment> pool = outside.isNotEmpty
        ? outside
        : <TemperaSegment>[
            for (final TemperaCompiledLine item in songLines)
              if (item.sourceIndex != chunk.lineIndex) ...item.segments,
          ];
    final TemperaDecorSpec decor = _decorSpec(
      kind,
      shotKind,
      '$seed:$paragraphIndex:$shotIndex:decor',
      pool.map((TemperaSegment s) => s.text).join(),
      pool
          .where((TemperaSegment s) => s.isWordLike)
          .map((TemperaSegment s) => s.text)
          .toList(),
      thread.motif,
    );
    thread.motif = decor.motif;
    shots.add(
      TemperaShot(
        id: 'p$paragraphIndex-s$shotIndex',
        kind: shotKind,
        startTime: chunk.startTime,
        endTime: shotIndex == chunks.length - 1
            ? math.max(chunk.endTime, paragraphEnd)
            : chunk.endTime,
        lyricEndTime: chunk.lyricEndTime,
        slices: <TemperaShotSlice>[
          TemperaShotSlice(
            lineIndex: chunk.lineIndex,
            segmentStart: chunk.segmentStart,
            segmentEnd: chunk.segmentEnd,
          ),
        ],
        isBridge: false,
        camera: start,
        cameraEnd: end,
        flowAngle: flow,
        decor: decor,
      ),
    );
  }
  return shots;
}

const double _bridgeMinGap = 1.2;
const double _bridgeMaxLength = 5;

List<TemperaShot> _bridgeShots(
  TemperaParagraphKind paragraphKind,
  int paragraphIndex,
  String seed,
  String fragmentPool,
  double gapStart,
  double gapEnd,
  _Thread thread,
) {
  final double gap = gapEnd - gapStart;
  if (gap < _bridgeMinGap) return const <TemperaShot>[];
  final int count = math.min(3, math.max(1, (gap / _bridgeMaxLength).ceil()));
  final double step = gap / count;
  return List<TemperaShot>.generate(count, (int index) {
    final String shotKind = temperaChooseWithoutRepeat<String>(
      temperaShotCandidates(const <TemperaMood>[
        TemperaMood.quiet,
        TemperaMood.neutral,
      ]),
      '$seed:$paragraphIndex:bridge$index',
      thread.kind,
    );
    thread.kind = shotKind;
    final int cameraSeed = temperaHashSeed(
      '$seed:$paragraphIndex:bridge$index:camera',
    );
    final double flow = _flowAngle(thread.flow, cameraSeed);
    thread.flow = flow;
    final (TemperaCameraKey start, TemperaCameraKey end) = _cameraKeys(
      shotKind,
      cameraSeed,
      flow,
    );
    final TemperaDecorSpec decor = _decorSpec(
      paragraphKind,
      shotKind,
      '$seed:$paragraphIndex:bridge$index:decor',
      fragmentPool,
      const <String>[],
      thread.motif,
    );
    thread.motif = decor.motif;
    return TemperaShot(
      id: 'p$paragraphIndex-b$index',
      kind: shotKind,
      startTime: gapStart + step * index,
      endTime: gapStart + step * (index + 1),
      lyricEndTime: gapStart + step * (index + 1),
      slices: const <TemperaShotSlice>[],
      isBridge: true,
      camera: start,
      cameraEnd: end,
      flowAngle: flow,
      decor: decor,
    );
  });
}

/// 把整首歌词编成凝彩程序。
TemperaProgram compileTemperaProgram(
  List<LyricVisualizerLine> lines, {
  required String seed,
  bool wholeLineLyrics = false,
}) {
  final List<TemperaCompiledLine> compiled = <TemperaCompiledLine>[];
  final bool sourced = lines.any(
    (LyricVisualizerLine l) => l.source.songPart != null,
  );
  for (int i = 0; i < lines.length; i++) {
    final LyricVisualizerLine l = lines[i];
    final double start = l.startMs / 1000;
    final double end = l.endMs / 1000;
    final double nextStart = i + 1 < lines.length
        ? lines[i + 1].startMs / 1000
        : double.infinity;
    compiled.add(
      TemperaCompiledLine(
        sourceIndex: i,
        startTime: start,
        endTime: end,
        text: l.text,
        // 句尾离场窗口（共享 render hints），不越过下一行起点。
        renderEndTime: math.max(
          start,
          math.min(l.renderEndMs / 1000, nextStart),
        ),
        segments: buildTemperaSegments(l),
        isChorus: l.isChorus,
        songPart: l.songPartLabel,
        blockIndex: sourced ? l.blockIndex : null,
      ),
    );
  }
  final double threshold = temperaParagraphGapThreshold(compiled);
  final List<List<TemperaCompiledLine>> drafts = <List<TemperaCompiledLine>>[];
  List<TemperaCompiledLine> current = <TemperaCompiledLine>[];
  for (int i = 0; i < compiled.length; i++) {
    final TemperaCompiledLine line = compiled[i];
    if (i > 0 && current.isNotEmpty) {
      final double gap = line.startTime - compiled[i - 1].renderEndTime;
      if (_metadataChanged(compiled[i - 1], line) || gap >= threshold) {
        drafts.addAll(_splitOversized(current));
        current = <TemperaCompiledLine>[];
      }
    }
    current.add(line);
  }
  if (current.isNotEmpty) drafts.addAll(_splitOversized(current));

  final _Thread thread = _Thread();
  String? previousTransition;
  final List<TemperaParagraph> paragraphs = <TemperaParagraph>[];
  for (int index = 0; index < drafts.length; index++) {
    final List<TemperaCompiledLine> draft = drafts[index];
    final TemperaParagraphKind kind = _classifyParagraph(
      draft,
      index,
      drafts.length,
    );
    final List<TemperaShot> lyricShots = _buildShots(
      draft,
      compiled,
      kind,
      index,
      seed,
      thread,
      wholeLineLyrics,
    );
    final List<TemperaCompiledLine>? next = index + 1 < drafts.length
        ? drafts[index + 1]
        : null;
    final double endTime = draft.last.renderEndTime;
    final double gap = next == null ? 0 : next.first.startTime - endTime;
    final List<TemperaShot> bridge = next == null
        ? const <TemperaShot>[]
        : _bridgeShots(
            kind,
            index,
            seed,
            draft.map((TemperaCompiledLine l) => l.text).join(),
            endTime,
            next.first.startTime,
            thread,
          );
    String? transitionKind;
    if (next != null) {
      transitionKind = temperaChooseWithoutRepeat<String>(
        temperaTransitionKinds,
        '$seed:$index:transition',
        previousTransition,
      );
      previousTransition = transitionKind;
    }
    final double transitionDuration = next == null
        ? 0
        : math.min(1, math.max(0.35, math.max(gap, 0) + 0.3));
    final double transitionEnd = next?.first.startTime ?? endTime;
    paragraphs.add(
      TemperaParagraph(
        id: 'tempera-p$index',
        kind: kind,
        startTime: draft.first.startTime,
        endTime: endTime,
        lines: draft,
        shots: <TemperaShot>[...lyricShots, ...bridge],
        transitionOut: transitionKind == null
            ? null
            : TemperaTransition(
                kind: transitionKind,
                startTime: math.max(
                  draft.first.startTime,
                  transitionEnd - transitionDuration,
                ),
                endTime: transitionEnd,
              ),
      ),
    );
  }
  // 段落首个构图在上一段转场时就开始搭（block-wipe 除外），逐字时间不动。
  for (int i = 1; i < paragraphs.length; i++) {
    final TemperaParagraph p = paragraphs[i];
    final TemperaTransition? tr = paragraphs[i - 1].transitionOut;
    if (p.shots.isEmpty || tr == null || tr.kind == 'block-wipe') continue;
    p.shots.first.startTime = math.min(
      p.shots.first.startTime,
      math.max(tr.startTime, paragraphs[i - 1].endTime),
    );
  }
  return TemperaProgram(
    seed: seed,
    paragraphGapThreshold: threshold,
    paragraphs: paragraphs,
  );
}

/// 时间所在的段落下标（还没开始时为 0）。
int temperaParagraphIndexAt(TemperaProgram program, double time) {
  for (int i = program.paragraphs.length - 1; i >= 0; i--) {
    if (time >= program.paragraphs[i].startTime) return i;
  }
  return 0;
}
