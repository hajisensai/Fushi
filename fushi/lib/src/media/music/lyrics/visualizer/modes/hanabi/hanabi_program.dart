/// 花火的整首编译（移植 folia `paragraphStructure.ts` + `hanabi/program.ts` + `hanabiProgram.ts` +
/// `hanabiTransitions.ts` + `hanabiSceneFrames.ts` + `hanabiScreenBloom.ts` 的纯函数部分）：
/// 歌词 → 段落 → 每段切镜头、选预设 → 段落转场。同样的歌词与种子永远得到同样的程序。
///
/// 与 folia 的差别：文字偏移按字形（grapheme）而不是 UTF-16。分词用框架的共享分词
/// （`lyric_visualizer_segments.dart`，folia `segmentLyricWords`），副歌取运行时的 `isChorus`（来源
/// 带段落标注时用标注，否则 folia 的文本启发式）。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

// ─── 行与分词 ───────────────────────────────────────────────────────────

/// 行里的一段（词 / 空白 / 标点），[start, end) 是字形下标。
class HanabiSegment {
  const HanabiSegment(
    this.start,
    this.end, {
    required this.wordLike,
    required this.space,
  });
  final int start;
  final int end;
  final bool wordLike;
  final bool space;
}

/// 编译用的一行（秒）。
class HanabiLine {
  HanabiLine({
    required this.chars,
    required this.charStart,
    required this.charEnd,
    required this.startTime,
    required this.endTime,
    this.isChorus = false,
  }) : segments = segmentHanabiWords(chars);

  final List<String> chars;
  final List<double> charStart;
  final List<double> charEnd;
  final double startTime;
  final double endTime;
  bool isChorus;
  final List<HanabiSegment> segments;

  String get text => chars.join();

  /// [start, end) 这段字形组成的新行（时间取各字自己的）。
  HanabiLine slice(int start, int end) {
    final int a = start.clamp(0, chars.length);
    final int b = end.clamp(a, chars.length);
    if (a == 0 && b == chars.length) return this;
    final List<String> c = chars.sublist(a, b);
    final List<double> s = charStart.sublist(a, b);
    final List<double> e = charEnd.sublist(a, b);
    double first = double.infinity;
    double last = double.negativeInfinity;
    for (int i = 0; i < c.length; i++) {
      if (c[i].trim().isEmpty) continue;
      first = math.min(first, s[i]);
      last = math.max(last, e[i]);
    }
    return HanabiLine(
      chars: c,
      charStart: s,
      charEnd: e,
      startTime: first.isFinite ? first : startTime,
      endTime: last.isFinite ? last : endTime,
      isChorus: isChorus,
    );
  }
}

/// 从运行时的行造编译用的行：首尾空白字形去掉，毫秒换成秒。
HanabiLine? hanabiLineOf(LyricVisualizerLine line) {
  final List<LyricVisualizerGlyph> glyphs = line.glyphs;
  int a = 0;
  int b = glyphs.length;
  while (a < b && glyphs[a].text.trim().isEmpty) {
    a++;
  }
  while (b > a && glyphs[b - 1].text.trim().isEmpty) {
    b--;
  }
  if (a >= b) {
    if (line.text.trim().isEmpty) return null;
    // 没有字形时间：整行均分。
    final List<String> chars = line.text.trim().split('');
    final double s = line.startMs / 1000;
    final double e = math.max(line.endMs, line.startMs) / 1000;
    final double step = (e - s) / chars.length;
    return HanabiLine(
      chars: chars,
      charStart: <double>[for (int i = 0; i < chars.length; i++) s + step * i],
      charEnd: <double>[
        for (int i = 0; i < chars.length; i++) s + step * (i + 1),
      ],
      startTime: s,
      endTime: e,
      isChorus: line.isChorus,
    );
  }
  final List<LyricVisualizerGlyph> used = glyphs.sublist(a, b);
  return HanabiLine(
    chars: <String>[for (final LyricVisualizerGlyph g in used) g.text],
    charStart: <double>[
      for (final LyricVisualizerGlyph g in used) g.startMs / 1000,
    ],
    charEnd: <double>[
      for (final LyricVisualizerGlyph g in used)
        math.max(g.endMs, g.startMs) / 1000,
    ],
    startTime: line.startMs / 1000,
    endTime: math.max(line.endMs, line.startMs) / 1000,
    isChorus: line.isChorus,
  );
}

/// 分词（folia `segmentLyricWords` 的 Intl.Segmenter 词粒度）：走框架的共享分词，再按 Intl.Segmenter 的
/// 习惯把粘在词上的标点拆回来单独成段（不算词），词与词之间的空白各成一段。
List<HanabiSegment> segmentHanabiWords(List<String> chars) {
  final List<LyricVisualizerGlyph> glyphs = <LyricVisualizerGlyph>[
    for (final String c in chars)
      LyricVisualizerGlyph(
        text: c,
        startMs: 0,
        endMs: 0,
        syllableIndex: 0,
        isSpace: c.trim().isEmpty,
      ),
  ];
  final List<LyricVisualizerScript> sc = <LyricVisualizerScript>[
    for (final String c in chars) lyricVisualizerScriptOf(c),
  ];
  final List<HanabiSegment> out = <HanabiSegment>[];

  /// 词外的一段：空白连成一段，标点 / 符号连成一段。
  void gap(int from, int to) {
    int i = from;
    while (i < to) {
      final int start = i;
      final bool space = sc[i] == LyricVisualizerScript.space;
      while (i < to && (sc[i] == LyricVisualizerScript.space) == space) {
        i++;
      }
      out.add(HanabiSegment(start, i, wordLike: false, space: space));
    }
  }

  bool punct(int i) => sc[i] == LyricVisualizerScript.punctuation;
  int cursor = 0;
  for (final LyricVisualizerSegment seg in buildLyricVisualizerSegments(
    glyphs,
  )) {
    final int a = seg.firstGlyph.clamp(cursor, chars.length);
    final int b = (seg.firstGlyph + seg.glyphCount).clamp(a, chars.length);
    gap(cursor, a);
    int coreA = a;
    while (coreA < b && punct(coreA)) {
      coreA++;
    }
    int coreB = b;
    while (coreB > coreA && punct(coreB - 1)) {
      coreB--;
    }
    if (coreA >= coreB) {
      gap(a, b);
    } else {
      gap(a, coreA);
      out.add(HanabiSegment(coreA, coreB, wordLike: true, space: false));
      gap(coreB, b);
    }
    cursor = b;
  }
  gap(cursor, chars.length);
  return out;
}

// ─── 段落结构（paragraphStructure.ts）──────────────────────────────────

enum ParagraphKind { breath, verse, lift, chorus, breakKind, outro }

class StructureLine {
  const StructureLine(this.sourceIndex, this.line, this.renderEndTime);
  final int sourceIndex;
  final HanabiLine line;
  final double renderEndTime;
}

List<StructureLine> buildStructureLines(List<HanabiLine> lines) =>
    <StructureLine>[
      for (int i = 0; i < lines.length; i++)
        StructureLine(
          i,
          lines[i],
          math.max(
            lines[i].startTime,
            math.min(
              lines[i].endTime,
              i + 1 < lines.length ? lines[i + 1].startTime : double.infinity,
            ),
          ),
        ),
    ];

double _median(List<double> values) {
  if (values.isEmpty) return 0.5;
  final List<double> sorted = List<double>.of(values)..sort();
  final int middle = sorted.length ~/ 2;
  return sorted.length.isEven
      ? (sorted[middle - 1] + sorted[middle]) / 2
      : sorted[middle];
}

double resolveParagraphGapThreshold(List<HanabiLine> lines) {
  final List<double> gaps = <double>[];
  for (int i = 1; i < lines.length; i++) {
    final double gap =
        lines[i].startTime - math.min(lines[i - 1].endTime, lines[i].startTime);
    if (gap > 0) gaps.add(gap);
  }
  return clampD(_median(gaps) * 2.5, 1.25, 3.5);
}

const int _maxParagraphLines = 6;
const double _maxParagraphDuration = 18;

List<List<StructureLine>> splitOversizedDraft(List<StructureLine> draft) {
  final List<List<StructureLine>> output = <List<StructureLine>>[];
  List<StructureLine> remaining = draft;
  int guard = 0;
  while (remaining.length > _maxParagraphLines ||
      (remaining.length > 1 &&
          remaining.last.renderEndTime - remaining.first.line.startTime >
              _maxParagraphDuration)) {
    if (guard++ > 1000) break;
    int? best;
    double bestGap = double.negativeInfinity;
    for (int offset = 0; offset + 2 < remaining.length - 1; offset++) {
      final int splitIndex = offset + 2;
      final double gap =
          remaining[splitIndex].line.startTime -
          remaining[offset + 1].renderEndTime;
      if (gap.isNaN) continue;
      if (best == null || gap > bestGap) {
        best = splitIndex;
        bestGap = gap;
      }
    }
    final int splitIndex = math.max(
      1,
      best ?? math.min(4, remaining.length - 1),
    );
    output.addAll(splitOversizedDraft(remaining.sublist(0, splitIndex)));
    remaining = remaining.sublist(splitIndex);
  }
  output.add(remaining);
  return output;
}

List<List<StructureLine>> draftParagraphs(
  List<StructureLine> lines,
  double threshold,
) {
  final List<List<StructureLine>> drafts = <List<StructureLine>>[];
  List<StructureLine> current = <StructureLine>[];
  for (int i = 0; i < lines.length; i++) {
    if (i > 0 && current.isNotEmpty) {
      final double gap = lines[i].line.startTime - lines[i - 1].renderEndTime;
      if (gap >= threshold) {
        drafts.addAll(splitOversizedDraft(current));
        current = <StructureLine>[];
      }
    }
    current.add(lines[i]);
  }
  if (current.isNotEmpty) drafts.addAll(splitOversizedDraft(current));
  return drafts;
}

final RegExp _liftPunct = RegExp('[!?！？…]');

ParagraphKind classifyParagraph(
  List<StructureLine> lines,
  int index,
  int total,
) {
  if (lines.any((StructureLine l) => l.line.isChorus)) {
    return ParagraphKind.chorus;
  }
  if (index == total - 1) return ParagraphKind.outro;
  final double duration = lines.last.renderEndTime - lines.first.line.startTime;
  int segments = 0;
  int punct = 0;
  for (final StructureLine l in lines) {
    segments += l.line.segments.where((HanabiSegment s) => s.wordLike).length;
    punct += _liftPunct.allMatches(l.line.text).length;
  }
  if (duration <= 3.5 || segments <= 3) return ParagraphKind.breath;
  if (punct >= 2 || segments / math.max(duration, 1) > 2.5) {
    return ParagraphKind.lift;
  }
  return ParagraphKind.verse;
}

// ─── 切片与镜头（program.ts）────────────────────────────────────────────

class HanabiSlice {
  const HanabiSlice(this.lineIndex, this.start, this.end);
  final int lineIndex;
  final int start;
  final int end;
}

class HanabiParams {
  const HanabiParams({
    this.bridgeGap = 3,
    this.maxChars = 18,
    this.maxLineSeconds = 6,
  });
  final double bridgeGap;
  final int maxChars;
  final double maxLineSeconds;
}

class _TimedSeg {
  const _TimedSeg(this.start, this.end, this.startTime, this.endTime);
  final int start;
  final int end;
  final double startTime;
  final double endTime;
}

/// 一行切成词（切长行的边界）：空白与标点并进前一个词，时间取各字自己的。
List<_TimedSeg> _segmentLine(HanabiLine line) {
  final List<(int, int)> merged = <(int, int)>[];
  for (final HanabiSegment s in line.segments) {
    if (merged.isNotEmpty && !s.wordLike) {
      merged[merged.length - 1] = (merged.last.$1, s.end);
    } else {
      merged.add((s.start, s.end));
    }
  }
  return <_TimedSeg>[
    for (final (int a, int b) in merged)
      _TimedSeg(a, b, line.charStart[a], line.charEnd[math.max(a, b - 1)]),
  ];
}

class LinePiece {
  const LinePiece(this.slice, this.startTime, this.lyricEndTime);
  final HanabiSlice slice;
  final double startTime;
  final double lyricEndTime;
}

const int _maxPieces = 3;
const double _bridgeTail = 0.6;

/// 一行 → 1–3 段：超过 maxChars 个字或 maxLineSeconds 秒时，在最接近等分处的词边界切开。
List<LinePiece> splitLine(StructureLine unified, HanabiParams params) {
  final HanabiLine line = unified.line;
  final int length = line.chars.length;
  final List<LinePiece> whole = <LinePiece>[
    LinePiece(
      HanabiSlice(unified.sourceIndex, 0, length),
      line.startTime,
      unified.renderEndTime,
    ),
  ];
  final int count = line.chars.where((String c) => c.trim().isNotEmpty).length;
  final double duration = line.endTime - line.startTime;
  final int maxChars = math.max(4, params.maxChars);
  final double maxSeconds = math.max(1, params.maxLineSeconds);
  if (count <= maxChars && duration <= maxSeconds) return whole;
  final List<_TimedSeg> segments = _segmentLine(line);
  final int pieces = math.min(
    _maxPieces,
    math.min(
      segments.length,
      math.max(2, math.max(count / maxChars, duration / maxSeconds).ceil()),
    ),
  );
  if (pieces < 2) return whole;
  final List<int> cuts = <int>[];
  int after = -1;
  for (int k = 1; k < pieces; k++) {
    final double target = length * k / pieces;
    int best = -1;
    for (int j = after + 1; j <= segments.length - 1 - (pieces - k); j++) {
      final int offset = segments[j + 1].start;
      if (best < 0 ||
          (offset - target).abs() < (segments[best + 1].start - target).abs()) {
        best = j;
      }
    }
    if (best < 0) break;
    cuts.add(best);
    after = best;
  }
  if (cuts.isEmpty) return whole;
  final List<int> bounds = <int>[-1, ...cuts, segments.length - 1];
  final List<LinePiece> result = <LinePiece>[];
  for (int k = 0; k < bounds.length - 1; k++) {
    final _TimedSeg first = segments[bounds[k] + 1];
    final _TimedSeg last = segments[bounds[k + 1]];
    final bool isFirst = k == 0;
    final bool isLast = k == bounds.length - 2;
    result.add(
      LinePiece(
        HanabiSlice(
          unified.sourceIndex,
          isFirst ? 0 : first.start,
          isLast ? length : segments[bounds[k + 1] + 1].start,
        ),
        isFirst ? line.startTime : first.startTime,
        isLast ? unified.renderEndTime : last.endTime,
      ),
    );
  }
  return result;
}

class PlannedShot {
  const PlannedShot({
    required this.slices,
    required this.startTime,
    required this.endTime,
    required this.lyricEndTime,
    required this.isBridge,
  });
  final List<HanabiSlice> slices;
  final double startTime;
  final double endTime;
  final double lyricEndTime;
  final bool isBridge;

  PlannedShot withEnd(double end) => PlannedShot(
    slices: slices,
    startTime: startTime,
    endTime: end,
    lyricEndTime: lyricEndTime,
    isBridge: isBridge,
  );
}

PlannedShot _bridge(double start, double end) => PlannedShot(
  slices: const <HanabiSlice>[],
  startTime: start,
  endTime: end,
  lyricEndTime: end,
  isBridge: true,
);

/// 镜头的时间：一段一个镜头，首尾相接；行后的长空隙交给间奏镜头。
List<PlannedShot> planShots(
  List<StructureLine> lines,
  double paragraphStart,
  double paragraphEnd,
  HanabiParams params,
) {
  final List<LinePiece> pieces = <LinePiece>[
    for (final StructureLine line in lines) ...splitLine(line, params),
  ];
  final List<PlannedShot> shots = <PlannedShot>[];
  double cursor = pieces.isNotEmpty
      ? math.min(paragraphStart, pieces.first.startTime)
      : paragraphStart;
  for (int index = 0; index < pieces.length; index++) {
    final LinePiece piece = pieces[index];
    final double start = cursor;
    final double nextStart = math.max(
      index + 1 < pieces.length ? pieces[index + 1].startTime : paragraphEnd,
      start + 0.05,
    );
    final double lyricEnd = piece.lyricEndTime;
    if (index < pieces.length - 1 && nextStart - lyricEnd >= params.bridgeGap) {
      final double end = math.max(start + 0.05, lyricEnd + _bridgeTail);
      shots.add(
        PlannedShot(
          slices: <HanabiSlice>[piece.slice],
          startTime: start,
          endTime: end,
          lyricEndTime: lyricEnd,
          isBridge: false,
        ),
      );
      shots.add(_bridge(end, nextStart));
    } else {
      final double end = index < pieces.length - 1
          ? nextStart
          : math.max(nextStart, lyricEnd);
      shots.add(
        PlannedShot(
          slices: <HanabiSlice>[piece.slice],
          startTime: start,
          endTime: end,
          lyricEndTime: math.min(lyricEnd, end),
          isBridge: false,
        ),
      );
    }
    cursor = shots.last.endTime;
  }
  if (pieces.isEmpty && paragraphEnd > paragraphStart) {
    shots.add(_bridge(paragraphStart, paragraphEnd));
  }
  return shots;
}

List<PlannedShot> _closeTail(
  List<PlannedShot> shots,
  double endTime,
  HanabiParams params,
) {
  if (shots.isEmpty) return shots;
  final PlannedShot last = shots.last;
  if (last.isBridge || endTime - last.lyricEndTime < params.bridgeGap) {
    return shots;
  }
  final double end = math.max(
    last.startTime + 0.05,
    last.lyricEndTime + _bridgeTail,
  );
  return <PlannedShot>[
    ...shots.sublist(0, shots.length - 1),
    last.withEnd(end),
    _bridge(end, endTime),
  ];
}

const double _bridgeShot = 7;
const double _bridgeSplit = 10;

List<PlannedShot> _splitLongBridges(List<PlannedShot> shots) => <PlannedShot>[
  for (final PlannedShot shot in shots)
    if (!shot.isBridge || shot.endTime - shot.startTime <= _bridgeSplit)
      shot
    else
      for (
        int index = 0,
            count = math.max(
              2,
              ((shot.endTime - shot.startTime) / _bridgeShot).round(),
            );
        index < count;
        index++
      )
        _bridge(
          shot.startTime + (shot.endTime - shot.startTime) * index / count,
          index == count - 1
              ? shot.endTime
              : shot.startTime +
                    (shot.endTime - shot.startTime) * (index + 1) / count,
        ),
];

class HanabiChain {
  List<String> recent = <String>[];
  String? family;
}

const int _recent = 6;
const List<String> _bridgeFamilies = <String>[
  'senrin',
  'uchiage',
  'kiku',
  'shakudama',
];

List<HanabiMood>? _moodsOf(ParagraphKind kind) => switch (kind) {
  ParagraphKind.chorus ||
  ParagraphKind.lift => const <HanabiMood>[HanabiMood.loud, HanabiMood.neutral],
  ParagraphKind.verse => const <HanabiMood>[
    HanabiMood.neutral,
    HanabiMood.quiet,
  ],
  ParagraphKind.breath || ParagraphKind.outro => const <HanabiMood>[
    HanabiMood.quiet,
    HanabiMood.neutral,
  ],
  ParagraphKind.breakKind => null,
};

/// 选预设：全部 → 间奏偏向的族 → 段落性质的 mood → 避开最近用过的与上一个的族；筛空了就不收。
String castShot({
  required String seed,
  required int paragraphIndex,
  required int shotIndex,
  required ParagraphKind kind,
  required bool isBridge,
  required HanabiChain chain,
}) {
  List<String> candidates = hanabiKinds;
  void narrow(bool Function(String kind) keep) {
    final List<String> next = candidates.where(keep).toList();
    if (next.isNotEmpty) candidates = next;
  }

  final List<HanabiMood>? moods = _moodsOf(kind);
  if (isBridge) {
    narrow((String k) => _bridgeFamilies.contains(hanabiProfileOf(k).family));
  }
  if (moods != null) {
    narrow((String k) => moods.contains(hanabiProfileOf(k).mood));
  }
  narrow((String k) => !chain.recent.contains(k));
  final String? family = chain.family;
  if (family != null) narrow((String k) => hanabiProfileOf(k).family != family);
  final HanabiRng random = hanabiRng(
    '$seed:$paragraphIndex:$shotIndex:hanabi-cast',
  );
  return candidates[(random() * candidates.length).floor()];
}

void advanceChain(HanabiChain chain, String kind) {
  final List<String> next = <String>[...chain.recent, kind];
  chain.recent = next.length > _recent
      ? next.sublist(next.length - _recent)
      : next;
  chain.family = hanabiProfileOf(kind).family;
}

// ─── 转场（hanabiTransitions.ts）──────────────────────────────────────

enum HanabiTransitionKind { ascend, flash, bloom }

class HanabiTransitionFrame {
  const HanabiTransitionFrame({
    this.alpha = 1,
    this.scale = 1,
    this.blur = 0,
    this.y = 0,
    this.rotation = 0,
  });
  final double alpha;
  final double scale;

  /// 模糊强度（逻辑像素）。
  final double blur;

  /// 纵向位移（画面高度的比例，向下为正）。
  final double y;
  final double rotation;

  static const HanabiTransitionFrame idle = HanabiTransitionFrame();
}

double _launch(double p) =>
    p <= 0 ? 0 : (p >= 1 ? 1 + 2 * (p - 1) : p * p * p * (2 - p));

/// exit 的 progress 可以超过 1（边界之后还在淡出的旧段落）。
HanabiTransitionFrame resolveTransitionFrame(
  HanabiTransitionKind kind,
  bool exit,
  double progress,
) {
  final double p = math.max(0, exit ? progress : math.min(1, progress));
  switch (kind) {
    case HanabiTransitionKind.ascend:
      if (exit) {
        final double e = _launch(p);
        return HanabiTransitionFrame(
          y: 0.32 * e,
          blur: 10 * math.min(e, 1),
          alpha: 1 - 0.7 * easeSeptic((p - 0.5) / 0.5),
          rotation: 0.55 * e,
        );
      }
      final double k = _launch(1 - p);
      return HanabiTransitionFrame(
        y: -0.26 * k,
        blur: 10 * k,
        alpha: 1 - 0.7 * k,
        rotation: -0.5 * k,
      );
    case HanabiTransitionKind.flash:
      final double near = exit ? easeSeptic(p) : 1 - easeSeptic(p);
      return HanabiTransitionFrame(
        scale: 1 + 0.05 * near,
        blur: 9 * near * near,
        alpha: 1 - 0.55 * near * near,
        rotation: (exit ? 0.12 : -0.12) * near,
      );
    case HanabiTransitionKind.bloom:
      if (exit) {
        final double e = easeSeptic(p);
        return HanabiTransitionFrame(
          scale: 1 + 0.18 * e,
          blur: 5 * e,
          alpha: 1 - e,
          rotation: 0.3 * e,
        );
      }
      final double k = 1 - easeSeptic(p);
      return HanabiTransitionFrame(
        scale: 1 - 0.08 * k,
        blur: 4 * k,
        alpha: 1 - k,
        rotation: -0.25 * k,
      );
  }
}

double hanabiTransitionDuration(HanabiTransitionKind kind, double gap) =>
    kind == HanabiTransitionKind.flash
    ? math.min(0.5, math.max(0.28, gap > 0 ? gap * 0.4 : 0.35))
    : math.min(1.1, math.max(0.5, gap > 0 ? gap * 0.6 : 0.8));

double resolveHanabiEnterDuration(
  HanabiTransitionKind kind,
  double startTime,
  double endTime,
) {
  final (double min, double max) = kind == HanabiTransitionKind.flash
      ? (0.2, 0.45)
      : (0.4, 0.9);
  return math.max(min, math.min(max, endTime - startTime));
}

/// 上升占一半，另一半在闪白 / 开花里挑；不与上一次相同。
HanabiTransitionKind chooseHanabiTransition(
  String seed,
  int paragraphIndex,
  HanabiTransitionKind? previous,
) {
  int hash = 0;
  for (final int c in '$seed:$paragraphIndex:hanabi-transition'.codeUnits) {
    hash = ((hash * 31 + c) & 0xFFFFFFFF).toSigned(32);
  }
  final int roll = hash.abs();
  if (previous != HanabiTransitionKind.ascend && roll.isEven) {
    return HanabiTransitionKind.ascend;
  }
  final List<HanabiTransitionKind> choices = <HanabiTransitionKind>[
    for (final HanabiTransitionKind k in HanabiTransitionKind.values)
      if (k != previous && k != HanabiTransitionKind.ascend) k,
  ];
  return choices[(roll >> 1) % choices.length];
}

// ─── 程序 ───────────────────────────────────────────────────────────────

class HanabiShot {
  const HanabiShot({
    required this.id,
    required this.kind,
    required this.slices,
    required this.startTime,
    required this.endTime,
    required this.lyricEndTime,
    required this.isBridge,
  });
  final String id;
  final String kind;
  final List<HanabiSlice> slices;
  final double startTime;
  final double endTime;
  final double lyricEndTime;
  final bool isBridge;
}

class HanabiTransitionOut {
  const HanabiTransitionOut(this.kind, this.startTime, this.endTime);
  final HanabiTransitionKind kind;
  final double startTime;
  final double endTime;
}

class HanabiParagraph {
  const HanabiParagraph({
    required this.index,
    required this.id,
    required this.kind,
    required this.startTime,
    required this.endTime,
    required this.lyricEndTime,
    required this.shots,
    required this.transitionOut,
  });
  final int index;
  final String id;
  final ParagraphKind kind;
  final double startTime;
  final double endTime;
  final double lyricEndTime;
  final List<HanabiShot> shots;
  final HanabiTransitionOut? transitionOut;
}

class HanabiChorusSpan {
  HanabiChorusSpan(this.startTime, this.endTime);
  final double startTime;
  double endTime;
}

class HanabiProgram {
  const HanabiProgram({
    required this.seed,
    required this.instrumental,
    required this.duration,
    required this.lyricEndTime,
    required this.paragraphs,
    required this.chorus,
    required this.lines,
  });
  final String seed;
  final bool instrumental;
  final double duration;
  final double? lyricEndTime;
  final List<HanabiParagraph> paragraphs;
  final List<HanabiChorusSpan> chorus;

  /// 编译用的行（镜头的切片按下标指向这里）。
  final List<HanabiLine> lines;

  /// 镜头的文字（切片拼成的一行）；间奏为 null。
  HanabiLine? shotLine(HanabiShot shot) {
    if (shot.isBridge || shot.slices.isEmpty) return null;
    final HanabiSlice s = shot.slices.first;
    if (s.lineIndex < 0 || s.lineIndex >= lines.length) return null;
    final HanabiLine line = lines[s.lineIndex].slice(s.start, s.end);
    return line.text.trim().isEmpty ? null : line;
  }
}

const double _instrumentalDuration = 480;
const double _instrumentalParagraph = 28;

class _ParagraphPlan {
  const _ParagraphPlan(
    this.lines,
    this.kind,
    this.startTime,
    this.endTime,
    this.lyricEndTime,
  );
  final List<StructureLine> lines;
  final ParagraphKind kind;
  final double startTime;
  final double endTime;
  final double lyricEndTime;
}

/// 编译整首歌。duration 是歌曲总时长（秒，可为 0）。
HanabiProgram compileHanabiProgram(
  List<HanabiLine> lines,
  String seed, {
  double duration = 0,
  HanabiParams params = const HanabiParams(),
}) {
  final bool instrumental = lines.isEmpty;
  final List<_ParagraphPlan> plans = <_ParagraphPlan>[];
  double programEnd;
  double? lyricEndTime;
  if (!instrumental) {
    final List<StructureLine> structure = buildStructureLines(lines);
    final List<List<StructureLine>> drafts = draftParagraphs(
      structure,
      resolveParagraphGapThreshold(lines),
    );
    lyricEndTime = structure
        .map((StructureLine l) => l.renderEndTime)
        .reduce(math.max);
    programEnd = math.max(lyricEndTime, duration);
    final double firstStart = structure.first.line.startTime;
    final bool intro = firstStart >= params.bridgeGap;
    if (intro) {
      plans.add(
        _ParagraphPlan(
          const <StructureLine>[],
          ParagraphKind.breakKind,
          0,
          firstStart,
          firstStart,
        ),
      );
    }
    for (int index = 0; index < drafts.length; index++) {
      final List<StructureLine> draft = drafts[index];
      plans.add(
        _ParagraphPlan(
          draft,
          classifyParagraph(draft, index, drafts.length),
          index == 0 && !intro
              ? math.min(0, firstStart)
              : draft.first.line.startTime,
          index + 1 < drafts.length
              ? drafts[index + 1].first.line.startTime
              : programEnd,
          draft.last.renderEndTime,
        ),
      );
    }
  } else {
    programEnd = math.max(1, duration > 0 ? duration : _instrumentalDuration);
    final int count = math.max(
      1,
      (programEnd / _instrumentalParagraph).round(),
    );
    for (int index = 0; index < count; index++) {
      final double start = programEnd * index / count;
      final double end = index == count - 1
          ? programEnd
          : programEnd * (index + 1) / count;
      plans.add(
        _ParagraphPlan(
          const <StructureLine>[],
          ParagraphKind.breakKind,
          start,
          end,
          end,
        ),
      );
    }
  }

  final HanabiChain chain = HanabiChain();
  HanabiTransitionKind? previousTransition;
  final List<HanabiParagraph> paragraphs = <HanabiParagraph>[];
  for (int index = 0; index < plans.length; index++) {
    final _ParagraphPlan plan = plans[index];
    final List<PlannedShot> planned = _splitLongBridges(
      _closeTail(
        planShots(plan.lines, plan.startTime, plan.endTime, params),
        plan.endTime,
        params,
      ),
    );
    final List<HanabiShot> shots = <HanabiShot>[];
    for (int shotIndex = 0; shotIndex < planned.length; shotIndex++) {
      final PlannedShot shot = planned[shotIndex];
      final String kind = castShot(
        seed: seed,
        paragraphIndex: index,
        shotIndex: shotIndex,
        kind: plan.kind,
        isBridge: shot.isBridge,
        chain: chain,
      );
      advanceChain(chain, kind);
      shots.add(
        HanabiShot(
          id: 'p$index-hb$shotIndex',
          kind: kind,
          slices: shot.slices,
          startTime: shot.startTime,
          endTime: shot.endTime,
          lyricEndTime: shot.lyricEndTime,
          isBridge: shot.isBridge,
        ),
      );
    }
    HanabiTransitionOut? out;
    if (index + 1 < plans.length) {
      final HanabiTransitionKind kind = chooseHanabiTransition(
        seed,
        index,
        previousTransition,
      );
      previousTransition = kind;
      final double gap = plans[index + 1].startTime - plan.lyricEndTime;
      out = HanabiTransitionOut(
        kind,
        math.max(
          plan.startTime,
          plan.endTime - hanabiTransitionDuration(kind, gap),
        ),
        plan.endTime,
      );
    }
    paragraphs.add(
      HanabiParagraph(
        index: index,
        id: 'hanabi-p$index',
        kind: plan.kind,
        startTime: plan.startTime,
        endTime: plan.endTime,
        lyricEndTime: plan.lyricEndTime,
        shots: shots,
        transitionOut: out,
      ),
    );
  }
  return HanabiProgram(
    seed: seed,
    instrumental: instrumental,
    duration: programEnd,
    lyricEndTime: lyricEndTime,
    paragraphs: paragraphs,
    chorus: resolveHanabiChorusSpans(lines),
    lines: lines,
  );
}

int findHanabiParagraphIndexAtTime(HanabiProgram program, double time) {
  for (int index = program.paragraphs.length - 1; index >= 0; index--) {
    if (time >= program.paragraphs[index].startTime) return index;
  }
  return 0;
}

/// 世界旋转起转的方向（整首歌一个）。
int hanabiSpinDirection(String programSeed) =>
    lyricVisualizerSeedOf('$programSeed:spin-direction').isEven ? 1 : -1;

// ─── 场景帧（hanabiSceneFrames.ts）────────────────────────────────────

class HanabiLayerFrame {
  const HanabiLayerFrame(this.index, this.frame);
  final int index;
  final HanabiTransitionFrame frame;
}

class HanabiSceneFrames {
  const HanabiSceneFrames(this.activeIndex, this.layers);
  final int activeIndex;
  final List<HanabiLayerFrame> layers;
}

HanabiTransitionFrame _exitFrameOf(
  HanabiProgram program,
  int index,
  double time, {
  bool beyond = false,
}) {
  if (index < 0 || index >= program.paragraphs.length) {
    return HanabiTransitionFrame.idle;
  }
  final HanabiTransitionOut? out = program.paragraphs[index].transitionOut;
  if (out == null || time < out.startTime) return HanabiTransitionFrame.idle;
  final double progress =
      (time - out.startTime) / math.max(out.endTime - out.startTime, 1e-3);
  return resolveTransitionFrame(
    out.kind,
    true,
    beyond ? progress : math.min(progress, 1),
  );
}

/// 某一时刻哪些段落场景在画、各自套什么帧；transitionsEnabled 为 false 时段落之间硬切。
HanabiSceneFrames resolveHanabiSceneFrames(
  HanabiProgram program,
  double time,
  bool transitionsEnabled,
) {
  if (program.paragraphs.isEmpty) {
    return const HanabiSceneFrames(-1, <HanabiLayerFrame>[]);
  }
  final int activeIndex = findHanabiParagraphIndexAtTime(program, time);
  if (!transitionsEnabled) {
    return HanabiSceneFrames(activeIndex, <HanabiLayerFrame>[
      HanabiLayerFrame(activeIndex, HanabiTransitionFrame.idle),
    ]);
  }
  final HanabiParagraph paragraph = program.paragraphs[activeIndex];
  final HanabiTransitionFrame current = _exitFrameOf(
    program,
    activeIndex,
    time,
  );
  final HanabiTransitionOut? previousOut = activeIndex > 0
      ? program.paragraphs[activeIndex - 1].transitionOut
      : null;
  if (previousOut != null) {
    final double enterDuration = resolveHanabiEnterDuration(
      previousOut.kind,
      previousOut.startTime,
      previousOut.endTime,
    );
    final double progress = (time - paragraph.startTime) / enterDuration;
    if (progress >= 0 && progress < 1) {
      final HanabiTransitionFrame enter = resolveTransitionFrame(
        previousOut.kind,
        false,
        progress,
      );
      final double weight = smoothstep01(progress);
      final HanabiTransitionFrame leaving = _exitFrameOf(
        program,
        activeIndex - 1,
        time,
        beyond: true,
      );
      final List<HanabiLayerFrame> layers = <HanabiLayerFrame>[];
      if (leaving.alpha * (1 - weight) > 0.002) {
        layers.add(
          HanabiLayerFrame(
            activeIndex - 1,
            HanabiTransitionFrame(
              alpha: leaving.alpha * (1 - weight),
              scale: leaving.scale,
              blur: leaving.blur,
              y: leaving.y,
              rotation: leaving.rotation,
            ),
          ),
        );
      }
      layers.add(
        HanabiLayerFrame(
          activeIndex,
          HanabiTransitionFrame(
            alpha: math.min(enter.alpha, weight) * current.alpha,
            scale: enter.scale * current.scale,
            blur: math.max(enter.blur, current.blur),
            y: enter.y + current.y,
            rotation: enter.rotation + current.rotation,
          ),
        ),
      );
      return HanabiSceneFrames(activeIndex, layers);
    }
  }
  return HanabiSceneFrames(activeIndex, <HanabiLayerFrame>[
    HanabiLayerFrame(activeIndex, current),
  ]);
}

// ─── 副歌辉光（hanabiScreenBloom.ts）──────────────────────────────────

List<HanabiChorusSpan> resolveHanabiChorusSpans(List<HanabiLine> lines) {
  final List<HanabiChorusSpan> spans = <HanabiChorusSpan>[];
  for (int i = 0; i < lines.length; i++) {
    final HanabiLine line = lines[i];
    if (!line.isChorus) continue;
    final double endTime = i + 1 < lines.length
        ? math.max(line.startTime, lines[i + 1].startTime)
        : line.endTime;
    if (spans.isNotEmpty && line.startTime - spans.last.endTime < 1.5) {
      spans.last.endTime = math.max(spans.last.endTime, endTime);
    } else {
      spans.add(HanabiChorusSpan(line.startTime, endTime));
    }
  }
  return spans;
}

double resolveHanabiChorusWeight(List<HanabiChorusSpan> spans, double time) {
  double weight = 0;
  for (final HanabiChorusSpan span in spans) {
    if (time < span.startTime - 0.5) break;
    if (time > span.endTime + 0.9) continue;
    final double rampIn = smoothstep01((time - (span.startTime - 0.5)) / 0.8);
    final double rampOut =
        1 - smoothstep01((time - (span.endTime - 0.2)) / 1.1);
    weight = math.max(weight, math.min(rampIn, rampOut));
  }
  return weight;
}

double resolveHanabiScreenBloomStrength(
  double bloom,
  double chorusBloom,
  double chorusWeight,
) => math.max(0, bloom) * 0.45 + math.max(0, chorusBloom) * 0.9 * chorusWeight;

// ─── 片尾卡（credits.ts）───────────────────────────────────────────────

class HanabiCreditsFrame {
  const HanabiCreditsFrame({
    required this.active,
    required this.elapsed,
    required this.lyricAlpha,
    required this.lyricBlur,
    required this.posterAlpha,
  });
  final bool active;
  final double elapsed;
  final double lyricAlpha;
  final double lyricBlur;
  final double posterAlpha;
}

/// 歌词 1.2 秒内淡出；片尾卡 0.3 秒起 0.8 秒淡入。
HanabiCreditsFrame resolveHanabiCreditsFrame(double time, double finalEndTime) {
  final double elapsed = time - finalEndTime;
  if (elapsed <= 0) {
    return const HanabiCreditsFrame(
      active: false,
      elapsed: 0,
      lyricAlpha: 1,
      lyricBlur: 0,
      posterAlpha: 0,
    );
  }
  final double exit = smoothstep01(elapsed / 1.2);
  return HanabiCreditsFrame(
    active: true,
    elapsed: elapsed,
    lyricAlpha: 1 - exit,
    lyricBlur: exit * 6,
    posterAlpha: smoothstep01((elapsed - 0.3) / 0.8),
  );
}
