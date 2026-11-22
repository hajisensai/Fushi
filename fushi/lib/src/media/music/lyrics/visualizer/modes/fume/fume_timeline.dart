/// 浮名的歌词时序（folia `fumeReveal.ts` / `fumeTextStyle.ts` / `utils/lyrics/renderHints.ts`）：
/// 词区间、已打印字数、行的「唱过」截止点、唱过文字的停留与淡出。
///
/// 时间一律用**秒**（与 folia 常量一致，入口处把毫秒换成秒）。
library;

import 'dart:math' as math;

import 'package:characters/characters.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_math.dart';

/// 一个字形的起止（秒）。
class FumeGlyphTiming {
  const FumeGlyphTiming(this.start, this.end);

  final double start;
  final double end;
}

/// 一个词在整行字形里的区间（folia `WordRange`）：[start, end) 含其后紧跟的空白。
class FumeWordRange {
  const FumeWordRange({
    required this.text,
    required this.start,
    required this.end,
    required this.wordStart,
    required this.wordEnd,
    required this.timings,
  });

  final String text;
  final int start;
  final int end;
  final double wordStart;
  final double wordEnd;

  /// 词内逐字时间（来自运行时的字形时间线；为空则按词时长均分）。
  final List<FumeGlyphTiming> timings;
}

/// 浮名用的一行（folia `Line` 的子集）。
class FumeLine {
  const FumeLine({
    required this.index,
    required this.text,
    required this.graphemes,
    required this.start,
    required this.end,
    required this.lastWordEnd,
    required this.ranges,
  });

  /// 在 `runtime.lines` 里的下标（与 `activeLineAt` 同一套编号）。
  final int index;
  final String text;
  final List<String> graphemes;
  final double start;
  final double end;
  final double lastWordEnd;
  final List<FumeWordRange> ranges;

  /// 文字可以留在台上的最后时刻（folia `getLineRenderEndTime`）。
  double get renderEnd => fumeLineRenderEndTime(start, end, lastWordEnd);
}

bool _isSpace(String s) => s.trim().isEmpty;

/// 运行时的一行 → 浮名的一行：字形去掉首尾空白，词区间吞掉其后空白（folia
/// `buildWordRangesFromWords` 的「词里没空格、整行有空格」兜底）。
FumeLine fumeLineFrom(LyricVisualizerLine line, int index) {
  final List<LyricVisualizerGlyph> glyphs = line.glyphs;
  int lo = 0;
  int hi = glyphs.length;
  while (lo < hi && glyphs[lo].isSpace) {
    lo++;
  }
  while (hi > lo && glyphs[hi - 1].isSpace) {
    hi--;
  }
  final double start = line.startMs / 1000;
  final double end = line.endMs / 1000;
  if (hi <= lo) {
    // 没有音节：整行文字，按行时长均分（folia 无词区间分支）。
    final List<String> g = _splitGraphemes(line.text);
    return FumeLine(
      index: index,
      text: line.text,
      graphemes: g,
      start: start,
      end: end,
      lastWordEnd: end,
      ranges: const <FumeWordRange>[],
    );
  }
  final List<LyricVisualizerGlyph> kept = glyphs.sublist(lo, hi);
  final List<String> graphemes = <String>[
    for (final LyricVisualizerGlyph g in kept) g.text,
  ];
  final List<FumeWordRange> ranges = <FumeWordRange>[];
  for (final LyricVisualizerWord w in line.words) {
    final int s = w.firstGlyph - lo;
    if (s < 0 || s >= graphemes.length) continue;
    int e = math.min(s + w.glyphCount, graphemes.length);
    final List<FumeGlyphTiming> timings = <FumeGlyphTiming>[
      for (int i = s; i < e; i++)
        FumeGlyphTiming(kept[i].startMs / 1000, kept[i].endMs / 1000),
    ];
    while (e < graphemes.length && _isSpace(graphemes[e])) {
      e++;
    }
    ranges.add(
      FumeWordRange(
        text: w.text,
        start: s,
        end: e,
        wordStart: w.startMs / 1000,
        wordEnd: w.endMs / 1000,
        timings: timings,
      ),
    );
  }
  final double lastWordEnd = line.words.isEmpty
      ? end
      : line.words.last.endMs / 1000;
  return FumeLine(
    index: index,
    text: graphemes.join(),
    graphemes: graphemes,
    start: start,
    end: math.max(end, start),
    lastWordEnd: lastWordEnd,
    ranges: ranges,
  );
}

List<String> _splitGraphemes(String text) => text.characters.toList();

// ---------------------------------------------------------------------------
// renderHints（folia utils/lyrics/renderHints.ts）
// ---------------------------------------------------------------------------

enum FumeLineTransitionMode { normal, fast, none }

/// 一行的过渡节奏（入场 / 离场 / 唱完停留）。
class FumeLineTransitionTiming {
  const FumeLineTransitionTiming(
    this.enterDuration,
    this.exitDuration,
    this.linePassHold,
  );

  final double enterDuration;
  final double exitDuration;
  final double linePassHold;
}

FumeLineTransitionMode fumeLineTransitionModeOf(double rawDuration) {
  if (rawDuration < 0.10) return FumeLineTransitionMode.none;
  if (rawDuration < 0.18) return FumeLineTransitionMode.fast;
  return FumeLineTransitionMode.normal;
}

FumeLineTransitionTiming fumeLineTransitionTiming(
  double rawDuration,
  FumeLineTransitionMode mode,
) {
  switch (mode) {
    case FumeLineTransitionMode.none:
      return const FumeLineTransitionTiming(0, 0, 0);
    case FumeLineTransitionMode.fast:
      return FumeLineTransitionTiming(
        fumeClamp(rawDuration * 0.45, 0.045, 0.06),
        fumeClamp(rawDuration * 0.22, 0.03, 0.04),
        0.03,
      );
    case FumeLineTransitionMode.normal:
      final double d = math.max(rawDuration, 0.12);
      return FumeLineTransitionTiming(
        math.min(0.42, math.max(0.22, d * 0.34)),
        math.min(0.32, math.max(0.18, d * 0.18)),
        0.06,
      );
  }
}

/// folia `buildLineRenderEndTime`。
double fumeLineRenderEndTime(double start, double end, double lastWordEnd) {
  final double raw = math.max(end - start, 0);
  final FumeLineTransitionMode mode = fumeLineTransitionModeOf(raw);
  if (mode == FumeLineTransitionMode.none) {
    return math.max(end, start + 0.067);
  }
  final FumeLineTransitionTiming tt = fumeLineTransitionTiming(raw, mode);
  final double passStart = math.max(lastWordEnd, start) + tt.linePassHold;
  final double exitStart = mode == FumeLineTransitionMode.fast
      ? <double>[
          start + tt.enterDuration + 0.01,
          passStart,
          end - tt.exitDuration,
        ].reduce(math.max)
      : math.max(passStart, end - tt.exitDuration);
  return math.max(end, exitStart + tt.exitDuration);
}

// ---------------------------------------------------------------------------
// reveal（folia fumeReveal.ts）
// ---------------------------------------------------------------------------

double _wordRevealProgress(FumeWordRange r, double t) {
  if (r.wordEnd <= r.wordStart) return t >= r.wordEnd ? 1 : 0;
  final double d = math.max(r.wordEnd - r.wordStart, 0.08);
  return fumeClamp((t - r.wordStart) / d, 0, 1);
}

int _printedGlyphsInRange(FumeWordRange r, double t) {
  final int length = math.max(r.end - r.start, 0);
  if (length == 0) return 0;
  if (t < r.wordStart) return 0;
  final int timed = math.min(r.timings.length, length);
  if (timed > 0) {
    if (t >= r.wordEnd) return length;
    int printed = 0;
    for (int i = 0; i < timed; i++) {
      if (t >= r.timings[i].start) printed = i + 1;
    }
    return printed.clamp(0, length);
  }
  final double p = _wordRevealProgress(r, t);
  if (p >= 1) return length;
  return (p * length + 0.2).floor().clamp(p > 0 ? 1 : 0, length);
}

/// 此刻已经「打印」出来的字数（整数，定格追焦与打印前沿用）。
int fumePrintedGraphemeCount(FumeLine line, double t) {
  final int count = line.graphemes.length;
  if (count == 0 || t < line.start) return 0;
  if (t >= line.end) return count;
  if (line.ranges.isEmpty) {
    final double d = math.max(line.end - line.start, 0.12);
    final double p = fumeClamp((t - line.start) / d, 0, 1);
    return (p * count + (p > 0 ? 1 : 0)).floor().clamp(0, count);
  }
  int printed = 0;
  for (final FumeWordRange r in line.ranges) {
    final int partial = _printedGlyphsInRange(r, t);
    printed = r.start + partial;
    if (partial < r.end - r.start) return printed.clamp(0, count);
  }
  return printed.clamp(0, count);
}

/// 已打印的连续进度（平滑追焦用）。
double fumePrintedGraphemeProgress(FumeLine line, double t) {
  final int count = line.graphemes.length;
  if (count == 0 || t < line.start) return 0;
  if (t >= line.end) return count.toDouble();
  if (line.ranges.isEmpty) {
    final double d = math.max(line.end - line.start, 0.12);
    return fumeClamp((t - line.start) / d, 0, 1) * count;
  }
  double printed = 0;
  for (final FumeWordRange r in line.ranges) {
    if (t < r.wordStart) return fumeClamp(printed, 0, count.toDouble());
    final double p = _wordRevealProgress(r, t);
    printed = r.start + p * math.max(r.end - r.start, 0);
    if (p < 1) return fumeClamp(printed, 0, count.toDouble());
  }
  return fumeClamp(printed, 0, count.toDouble());
}

/// 行算「唱过」的时刻：渲染结束与下一句开始取早者。
double fumeLinePassCutoffTime(FumeLine line, double? nextLineStart) {
  final double renderEnd = line.renderEnd;
  if (nextLineStart == null || !nextLineStart.isFinite) return renderEnd;
  return math.min(renderEnd, nextLineStart);
}

/// 进度在 [cutoffTime] 前必须走完（下一句抢拍时压缩动画）。
double fumeVisualProgressWithCutoff(
  double startedAt,
  double duration,
  double t,
  double cutoffTime,
) {
  final double nominalEnd = startedAt + math.max(duration, 0.001);
  final double effectiveEnd = math.max(
    startedAt + 0.001,
    math.min(nominalEnd, cutoffTime),
  );
  return fumeClamp(
    (t - startedAt) / math.max(effectiveEnd - startedAt, 0.001),
    0,
    1,
  );
}

// ---------------------------------------------------------------------------
// 唱过文字的样式（folia fumeTextStyle.ts）
// ---------------------------------------------------------------------------

enum FumeVariant { body, hero }

enum FumeHoldStyle { standard, dimmed }

/// 唱过文字的不透明度与残留辉光。
class FumePassedStyle {
  const FumePassedStyle(
    this.opacity,
    this.glowMultiplier,
    this.shadowAlphaBase,
    this.shadowAlphaTrail,
  );

  final double opacity;
  final double glowMultiplier;
  final double shadowAlphaBase;
  final double shadowAlphaTrail;
}

FumePassedStyle fumePassedTextStyle(FumeVariant variant, FumeHoldStyle style) {
  final bool hero = variant == FumeVariant.hero;
  return style == FumeHoldStyle.dimmed
      ? FumePassedStyle(hero ? 0.11 : 0.075, 0, 0, 0)
      : FumePassedStyle(hero ? 0.74 : 0.58, 1, 0.1, 0.16);
}

/// 唱过之后变暗的程度 0–1。
double fumePassedDimAmount(double t, double passedAt, double fadeDuration) {
  if (!t.isFinite ||
      !passedAt.isFinite ||
      !fadeDuration.isFinite ||
      fadeDuration <= 0) {
    return 1;
  }
  final double age = math.max(t - passedAt, 0);
  return fumeEaseInCubic(fumeClamp(age / fadeDuration, 0, 1));
}

/// 唱过文字淡下去要多久：整首时长 × 停留比例，夹在 2.4–130 秒；比例为 1 时永不淡。
double fumePassedFadeDuration(List<FumeLine> lines, double textHoldRatio) {
  if (textHoldRatio >= 1) return double.infinity;
  final List<FumeLine> timed =
      lines
          .where(
            (FumeLine l) =>
                l.start.isFinite &&
                l.renderEnd.isFinite &&
                l.renderEnd >= l.start,
          )
          .toList()
        ..sort((FumeLine a, FumeLine b) => a.start.compareTo(b.start));
  if (timed.length <= 1) return fumeClamp(8 * textHoldRatio, 2.4, 130);
  final double total = math.max(timed.last.renderEnd - timed.first.start, 0);
  return fumeClamp(total * textHoldRatio, 2.4, 130);
}
