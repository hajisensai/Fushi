/// 镜台的场景行、走廊段（folia `dioramaSequencer.ts`）与切歌镜头飞行（`dioramaTransition.ts`）。
///
/// 每首歌（与单曲循环的每一轮）是同一个世界里的一段走廊，行下标全局连续；切歌时新走廊生在
/// 当前走廊远处（雾外，看不见），相机沿弧线飞过去——一镜到底，不遮不黑。
library;

import 'dart:math' as math;

import 'package:fushi_music/fushi_music.dart' show LyricSyllable;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_path.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';

/// 当前行的一个渲染单元：CJK 每字一个，其它文字每词一个（folia `LyricUnit`）。
class DioramaUnit {
  const DioramaUnit({
    required this.text,
    required this.charStart,
    required this.charEnd,
    required this.start,
    required this.end,
  });

  final String text;

  /// 在 [DioramaSceneLine.layoutText] 里的 UTF-16 下标区间。
  final int charStart;
  final int charEnd;

  /// 秒。
  final double start;
  final double end;
}

/// 场景里的一行（来自运行时；纯音乐时是没有文字的「幻影行」）。
class DioramaSceneLine {
  const DioramaSceneLine({
    required this.layoutText,
    required this.start,
    required this.end,
    required this.glyphStarts,
    required this.glyphEnds,
    required this.units,
    required this.character,
  });

  /// 排版用的整行文字（字形拼接，下标与 [units] 对齐）；幻影行为空串。
  final String layoutText;
  final double start;
  final double end;

  /// 非空白字形的起止（秒），给读头进度用。
  final List<double> glyphStarts;
  final List<double> glyphEnds;
  final List<DioramaUnit> units;
  final DioramaLineCharacter character;

  bool get hasText => layoutText.trim().isNotEmpty && units.isNotEmpty;

  /// 字形揭示比例 0..1（在当前字形内插值，连续；folia CameraRig `resolveWordProgress`）。
  double wordProgress(double now) {
    final int n = glyphStarts.length;
    if (n == 0) return 0;
    if (now >= end) return 1;
    if (now <= start) return 0;
    double revealed = 0;
    for (int i = 0; i < n; i++) {
      if (now >= glyphEnds[i]) {
        revealed = i + 1.0;
      } else if (now >= glyphStarts[i]) {
        final double span = math.max(glyphEnds[i] - glyphStarts[i], 0.001);
        revealed = i + dioramaClamp01((now - glyphStarts[i]) / span);
        break;
      } else {
        break;
      }
    }
    return revealed / n;
  }
}

/// 纯音乐：96 个每段 5 秒的幻影行，每 4 行一个伪段落，每 3 段一次「副歌」。
const int dioramaInstrumentalFrames = 96;
const double dioramaInstrumentalSecondsPerFrame = 5;

List<DioramaSceneLine> buildDioramaPhantomLines() => <DioramaSceneLine>[
  for (int i = 0; i < dioramaInstrumentalFrames; i++)
    DioramaSceneLine(
      layoutText: '',
      start: i * dioramaInstrumentalSecondsPerFrame,
      end: (i + 1) * dioramaInstrumentalSecondsPerFrame,
      glyphStarts: const <double>[],
      glyphEnds: const <double>[],
      units: const <DioramaUnit>[],
      character: DioramaLineCharacter(
        noteSeconds: const <double>[],
        isChorus: (i ~/ 4) % 3 == 2,
        sectionStart: i > 0 && i % 4 == 0,
      ),
    ),
];

/// 运行时行 → 场景行。Fushi 歌词没有段落 / 副歌标注：段落开头取「与上一句隔了 ≥3 秒」
/// （folia 对 >3 秒的空档插间奏行，同一个阈值），副歌取「整首里出现不止一次的句子」。
List<DioramaSceneLine> buildDioramaSceneLines(LyricVisualizerRuntime runtime) {
  final Map<String, int> textCount = <String, int>{};
  for (final LyricVisualizerLine l in runtime.lines) {
    final String key = l.text.trim().toLowerCase();
    textCount[key] = (textCount[key] ?? 0) + 1;
  }
  final List<DioramaSceneLine> out = <DioramaSceneLine>[];
  for (int li = 0; li < runtime.lines.length; li++) {
    final LyricVisualizerLine l = runtime.lines[li];
    final StringBuffer text = StringBuffer();
    final List<int> offsets = <int>[];
    final List<double> gs = <double>[];
    final List<double> ge = <double>[];
    for (final LyricVisualizerGlyph g in l.glyphs) {
      offsets.add(text.length);
      text.write(g.text);
      if (!g.isSpace) {
        gs.add(g.startMs / 1000);
        ge.add(g.endMs / 1000);
      }
    }
    final String layoutText = text.toString();
    final List<DioramaUnit> units = <DioramaUnit>[];
    for (final LyricVisualizerWord w in l.words) {
      if (w.glyphCount <= 0 || w.firstGlyph >= offsets.length) continue;
      final int last = w.firstGlyph + w.glyphCount - 1;
      units.add(
        DioramaUnit(
          text: w.text,
          charStart: offsets[w.firstGlyph],
          charEnd: offsets[last] + l.glyphs[last].text.length,
          start: w.startMs / 1000,
          end: w.endMs / 1000,
        ),
      );
    }
    final double prevEnd = li > 0 ? runtime.lines[li - 1].endMs / 1000 : 0;
    out.add(
      DioramaSceneLine(
        layoutText: layoutText,
        start: l.startMs / 1000,
        end: l.endMs / 1000,
        glyphStarts: gs,
        glyphEnds: ge,
        units: units,
        character: DioramaLineCharacter(
          noteSeconds: <double>[
            for (final LyricSyllable s in l.source.syllables)
              if (s.text.trim().isNotEmpty) (s.endMs - s.startMs) / 1000,
          ],
          isChorus: (textCount[l.text.trim().toLowerCase()] ?? 0) > 1,
          sectionStart: li > 0 && l.startMs / 1000 - prevEnd >= 3,
        ),
      ),
    );
  }
  return out;
}

/// 一段走廊（一首歌的一轮）。
class DioramaSegment {
  DioramaSegment({
    required this.seed,
    required this.round,
    required this.lines,
    required this.frames,
    required this.globalStart,
    required this.span,
    required this.placementOrigin,
  }) : characters = <DioramaLineCharacter>[
         for (final DioramaSceneLine l in lines) l.character,
       ];

  final int seed;
  final int round;
  List<DioramaSceneLine> lines;
  List<DioramaLineCharacter> characters;
  List<DioramaFrame> frames;
  final int globalStart;
  int span;
  final DioramaVec placementOrigin;

  /// 歌词原地换掉时 +1（缓存的栅格要跟着失效）。
  int linesEpoch = 0;

  String get key => '$seed#$round@$globalStart';
}

class DioramaResolvedLine {
  const DioramaResolvedLine({
    required this.segment,
    required this.localIndex,
    required this.frame,
    required this.line,
  });

  final DioramaSegment segment;
  final int localIndex;
  final DioramaFrame frame;
  final DioramaSceneLine? line;
}

class DioramaSequencer {
  final List<DioramaSegment> segments = <DioramaSegment>[];
  int nextGlobalStart = 0;

  DioramaSegment? get active => segments.isEmpty ? null : segments.last;

  int get totalLines => nextGlobalStart;

  DioramaSegment append({
    required int seed,
    required List<DioramaSceneLine> lines,
    required int round,
    required DioramaVec placementOrigin,
  }) {
    final List<DioramaFrame> frames = <DioramaFrame>[
      for (final DioramaFrame f in buildDioramaPath(lines.length, seed))
        f.translated(placementOrigin),
    ];
    final int span = math.max(lines.length, 1);
    final DioramaSegment seg = DioramaSegment(
      seed: seed,
      round: round,
      lines: lines,
      frames: frames,
      globalStart: nextGlobalStart,
      span: span,
      placementOrigin: placementOrigin,
    );
    segments.add(seg);
    nextGlobalStart += span;
    return seg;
  }

  /// 歌词晚到 / 重排：原地重建当前走廊，位置与全局起点不变，不飞也不切。
  void updateActiveLines(List<DioramaSceneLine> lines) {
    final DioramaSegment? seg = active;
    if (seg == null) return;
    final int span = math.max(lines.length, 1);
    nextGlobalStart += span - seg.span;
    seg.lines = lines;
    seg.characters = <DioramaLineCharacter>[
      for (final DioramaSceneLine l in lines) l.character,
    ];
    seg.frames = <DioramaFrame>[
      for (final DioramaFrame f in buildDioramaPath(lines.length, seg.seed))
        f.translated(seg.placementOrigin),
    ];
    seg.span = span;
    seg.linesEpoch++;
  }

  DioramaResolvedLine? resolve(int globalIndex) {
    for (final DioramaSegment s in segments) {
      final int local = globalIndex - s.globalStart;
      if (local >= 0 && local < s.span) {
        return DioramaResolvedLine(
          segment: s,
          localIndex: local,
          frame: dioramaFrameAt(s.frames, local),
          line: local < s.lines.length ? s.lines[local] : null,
        );
      }
    }
    return null;
  }

  /// 丢掉相机早已飞过的走廊（当前段永远保留）。
  void prune(int keepFromGlobal) {
    if (segments.length <= 1) return;
    segments.removeWhere(
      (DioramaSegment s) =>
          s.globalStart + s.span - 1 < keepFromGlobal && s != active,
    );
  }
}

// ─── 切歌飞行 ──────────────────────────────────────────────────────────────

/// 飞行时长（秒）。
const double dioramaTransitionDuration = 3.2;

/// 新走廊离旧走廊的距离：在雾的远端（30）之外，新场景从看不见开始。
const double dioramaTransitionDistance = 46;
const double dioramaTransitionBank = 0.14;
const double dioramaTransitionAimSweep = 0.14;

/// 飞行方向在水平面上的垂线（弧线鼓出、视线横扫、相机侧倾共用）。
DioramaVec dioramaFlightPerp(DioramaVec from, DioramaVec to) {
  final DioramaVec perp = DioramaVec(to.z - from.z, 0, -(to.x - from.x));
  final double l = perp.length;
  return l < 1e-3 ? const DioramaVec(1, 0, 0) : perp * (1 / l);
}

int dioramaFlightSide(int seed, int epoch) =>
    dioramaSeededUnit(dioramaHashSeed(seed) + epoch * 17.0) < 0.5 ? -1 : 1;

/// 下一首走廊的偏移：方位转满一圈、仰角偏上，z 永远向前（相机推进而不是倒车）。
DioramaVec dioramaPickTransitionOffset(int seed, int epoch) {
  final double base = dioramaHashSeed(seed) + epoch * 131.0;
  final double azimuth = dioramaSeededUnit(base + 1) * math.pi * 2;
  final double elevation = (dioramaSeededUnit(base + 2) - 0.35) * 1.3;
  final double ce = math.cos(elevation);
  final DioramaVec dir = DioramaVec(
    math.sin(azimuth) * ce,
    math.sin(elevation),
    -(math.cos(azimuth) * ce).abs() - 0.35,
  );
  return dir.normalized * dioramaTransitionDistance;
}

/// smootherstep：起落速度都为 0。
double dioramaTransitionEase(double t) {
  final double c = dioramaClamp01(t);
  return c * c * c * (c * (c * 6 - 15) + 10);
}
