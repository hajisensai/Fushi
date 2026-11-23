/// 倾诉的纯布局 / 时间算法（folia `tilt/VisualizerTilt.tsx` 里的 `determineLineCount`、
/// `buildTiltLayout`、`buildCharTimings`、`getCharPulseIntensity` 与分段显现规则）。
/// 不碰 widget，可单测；量字宽由调用方注入（widget 里是 TextPainter）。
library;

import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_sentence_split.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_tuning.dart';

const double _remPx = 16;
const int _charRefLength = 20;
const int _logOffset = 4;
const List<double> _lineThresholds = <double>[0.45, 1.05, 1.7];
const double _resplitThreshold = 1.6;
const double _scaleFloorNormal = 0.55;
const double _scaleFloorTilt = 0.5;

/// 正体行字号的放大倍数（末行只剩一两个字时，folia `shortLastBoost`）。
const double kTiltShortLastBoost = 1.18;

/// 字距（em）：正体 0.08em、斜体 0.15em。
const double kTiltNormalLetterSpacingEm = 0.08;
const double kTiltTiltLetterSpacingEm = 0.15;

/// 行高倍数：正体 1.35、斜体 1.25。
const double kTiltNormalLineHeight = 1.35;
const double kTiltTiltLineHeight = 1.25;

/// 空格的最小宽度（em）：正体 0.25em、斜体 0.35em。
const double kTiltNormalSpaceEm = 0.25;
const double kTiltTiltSpaceEm = 0.35;

/// 段落显现提前量（folia：`latest >= start - 0.25`）。
const int kTiltSegmentLeadMs = 250;

/// 每个字的显现错峰：正体 40ms、斜体 50ms。
const int kTiltNormalCharStaggerMs = 40;
const int kTiltTiltCharStaggerMs = 50;

/// 段容器的显隐时长：正体 0.55s、斜体 0.6s；字 0.5s。
const int kTiltNormalSegmentMs = 550;
const int kTiltTiltSegmentMs = 600;
const int kTiltCharMs = 500;

/// 整句淡入（framer 默认 opacity 过渡）与换句淡出（0.45s easeInOut）。
const int kTiltGroupEnterMs = 300;
const int kTiltGroupExitMs = 450;

/// folia 的缓动 `cubic-bezier(0.25, 0.46, 0.45, 0.94)`。
const Cubic kTiltEase = Cubic(0.25, 0.46, 0.45, 0.94);

/// 量一段字的宽度：[px] 字号，[tilt] 为斜体（细、斜）还是正体。
typedef TiltMeasure = double Function(String text, double px, bool tilt);

/// folia `seededRandom`：`frac(sin(seed * 1000 + offset) * 10000)`。
double tiltSeededRandom(double seed, int offset) {
  final double x = math.sin(seed * 1000 + offset) * 10000;
  return x - x.floorToDouble();
}

/// 一句拆成几行（1–4）：字数取对数归一，再乘抖动与分行概率。
int tiltDetermineLineCount(
  int charCount,
  double seed,
  double splitProbability,
) {
  final double normalized =
      math.log(charCount + _logOffset) / math.log(_charRefLength + _logOffset);
  final double jitter = tiltSeededRandom(seed, 1) * 0.6 + 0.7;
  final double score = normalized * jitter * splitProbability;
  if (score < _lineThresholds[0]) return 1;
  if (score < _lineThresholds[1]) return 2;
  if (score < _lineThresholds[2]) return 3;
  return 4;
}

/// 量宽时用的字号（folia `measureMaxPx`）。
double tiltMeasureFontPx(double viewportWidth, double fontScale) =>
    math.max(viewportWidth * 0.06875, 5.625 * _remPx * fontScale);

/// 可用宽度（folia `getAvailableWidth`：视口的 85%，视口不小于 320）。
double tiltAvailableWidth(double viewportWidth) =>
    math.max(320, viewportWidth) * 0.85;

/// 实际字号：CSS `clamp(3.125rem·k, 6.875vw·k, 5.625rem·k)`。
double tiltRenderFontPx(double viewportWidth, double k) => math.max(
  3.125 * _remPx * k,
  math.min(0.06875 * viewportWidth * k, 5.625 * _remPx * k),
);

/// 斜体字上下错开的幅度（folia `yOffset = tiltFontPx / 6`）。
double tiltStaggerOffsetPx(double viewportWidth, double k) =>
    math.min(viewportWidth * 0.06875 * k, 5.625 * _remPx * k) / 6;

/// 拆出来的一行。
@immutable
class TiltSegment {
  const TiltSegment({
    required this.text,
    required this.isTilt,
    required this.isShortLastLine,
    required this.charOffset,
  });

  /// 去掉首尾空白的文字。
  final String text;

  /// 这一行用斜体强调（一句至多一行）。
  final bool isTilt;

  /// 末行只剩一两个字：字号放大 [kTiltShortLastBoost]。
  final bool isShortLastLine;

  /// 在整句里的 UTF-16 起点（已跳过行首空白）。
  final int charOffset;

  TiltSegment copyWith({bool? isTilt, bool? isShortLastLine}) => TiltSegment(
    text: text,
    isTilt: isTilt ?? this.isTilt,
    isShortLastLine: isShortLastLine ?? this.isShortLastLine,
    charOffset: charOffset,
  );

  @override
  String toString() =>
      'TiltSegment($text, tilt: $isTilt, short: $isShortLastLine, @$charOffset)';
}

/// 一句的排法。
@immutable
class TiltLayout {
  const TiltLayout({required this.segments, required this.scaleMultiplier});

  final List<TiltSegment> segments;

  /// 整句字号倍数（最宽的一行超出可用宽度时缩小，有下限）。
  final double scaleMultiplier;
}

final RegExp _ellipsisOnly = RegExp(r'^[\s.…·。]+$');

List<TiltSegment> _toSegments(List<String> parts) {
  int offset = 0;
  final List<TiltSegment> out = <TiltSegment>[];
  for (final String text in parts) {
    final String trimmedStart = text.trimLeft();
    final int leading = text.length - trimmedStart.length;
    out.add(
      TiltSegment(
        text: trimmedStart.trimRight(),
        isTilt: false,
        isShortLastLine: false,
        charOffset: offset + leading,
      ),
    );
    offset += text.length;
  }
  return out;
}

List<TiltSegment> _markShortLastLine(List<TiltSegment> segs) {
  if (segs.length < 2) return segs;
  final TiltSegment last = segs.last;
  if (last.isTilt || last.text.trim().length > 2) return segs;
  final TiltSegment prev = segs[segs.length - 2];
  if (last.text.trim().length * 2 <= prev.text.length) {
    return <TiltSegment>[
      ...segs.sublist(0, segs.length - 1),
      last.copyWith(isShortLastLine: true),
    ];
  }
  return segs;
}

/// folia `buildTiltLayout`：拆行 → 按概率挑一行斜体 → 太宽就重拆或整体缩小。
TiltLayout buildTiltLayout({
  required String fullText,
  required double lineSeed,
  required TiltTuning tuning,
  required double viewportWidth,
  required double fontScale,
  required TiltMeasure measure,
  List<(int, int)>? wordSpans,
}) {
  final double basePx = tiltMeasureFontPx(viewportWidth, fontScale);
  final double availableWidth = tiltAvailableWidth(viewportWidth);
  final String trimmed = fullText.trim();

  final List<String> parts;
  if (_ellipsisOnly.hasMatch(trimmed)) {
    parts = <String>[fullText];
  } else {
    final int numLines = tiltDetermineLineCount(
      trimmed.length,
      lineSeed,
      tuning.splitProbability,
    );
    parts = tiltSplitIntoSentences(
      fullText,
      numLines,
      timeSeed: lineSeed,
      wordSpans: wordSpans,
    );
  }

  final List<int> candidates = <int>[
    for (int i = 0; i < parts.length; i++)
      if (tiltSeededRandom(lineSeed, 100 + i) < tuning.tiltStyleProbability) i,
  ];
  final int tiltIndex = candidates.isEmpty
      ? -1
      : candidates[(tiltSeededRandom(lineSeed, 200) * candidates.length)
            .floor()];

  final List<TiltSegment> segments = <TiltSegment>[
    for (final (int i, TiltSegment s) in _toSegments(parts).indexed)
      s.copyWith(isTilt: i == tiltIndex),
  ];

  double widest(Iterable<TiltSegment> segs, bool tilt) {
    double w = 0;
    for (final TiltSegment s in segs) {
      w = math.max(w, measure(s.text, basePx, tilt));
    }
    return w;
  }

  final double tiltWidth = widest(
    segments.where((TiltSegment s) => s.isTilt),
    true,
  );
  final double normalWidth = widest(
    segments.where((TiltSegment s) => !s.isTilt),
    false,
  );
  final double tiltOverflow = tiltWidth > 0 ? tiltWidth / availableWidth : 0;
  final double normalOverflow = normalWidth > 0
      ? normalWidth / availableWidth
      : 0;
  final double maxOverflow = math.max(tiltOverflow, normalOverflow);

  double scale = 1;
  if (maxOverflow > 1) {
    if (maxOverflow >= _resplitThreshold) {
      final double targetWidth = availableWidth * (_resplitThreshold - 0.15);
      final double totalWidth = measure(fullText, basePx, false);
      final int needed = math.min(
        4,
        math.max(segments.length + 1, (totalWidth / targetWidth).ceil()),
      );
      if (needed > segments.length) {
        List<TiltSegment> resplit = _toSegments(
          tiltSplitIntoSentences(
            fullText,
            needed,
            timeSeed: lineSeed,
            wordSpans: wordSpans,
          ),
        );
        if (resplit.isNotEmpty &&
            tiltSeededRandom(lineSeed, 300) < tuning.tiltStyleProbability) {
          final int picked = (tiltSeededRandom(lineSeed, 301) * resplit.length)
              .floor();
          resplit = <TiltSegment>[
            for (final (int i, TiltSegment s) in resplit.indexed)
              i == picked ? s.copyWith(isTilt: true) : s,
          ];
        }
        double postScale = 1;
        final TiltSegment? tiltSeg = resplit
            .where((TiltSegment s) => s.isTilt)
            .firstOrNull;
        if (tiltSeg != null) {
          final double w = measure(tiltSeg.text, basePx, true);
          if (w > availableWidth) {
            postScale = math.max(_scaleFloorTilt, availableWidth / w);
          }
        } else {
          final double w = widest(resplit, false);
          if (w > availableWidth) {
            postScale = math.max(_scaleFloorNormal, availableWidth / w);
          }
        }
        return TiltLayout(
          segments: _markShortLastLine(resplit),
          scaleMultiplier: postScale,
        );
      }
    }
    if (tiltOverflow >= normalOverflow && tiltWidth > 0) {
      scale = math.max(_scaleFloorTilt, availableWidth / tiltWidth);
    } else if (normalWidth > 0) {
      scale = math.max(_scaleFloorNormal, availableWidth / normalWidth);
    }
  }
  return TiltLayout(
    segments: _markShortLastLine(segments),
    scaleMultiplier: scale,
  );
}

// ---------------------------------------------------------------------------
// 时间
// ---------------------------------------------------------------------------

/// 段里的一个字形。
@immutable
class TiltChar {
  const TiltChar({
    required this.text,
    required this.isSpace,
    required this.visualIndex,
    required this.startMs,
    required this.endMs,
  });

  final String text;
  final bool isSpace;

  /// 段内非空白字的序号（空白取它前面已数过的个数；folia `visualIndex`）：
  /// 决定显现错峰，斜体行还决定上下错开的方向（偶数往上）。
  final int visualIndex;
  final int startMs;
  final int endMs;
}

/// 一行（段）的字与起止时间。
@immutable
class TiltSegmentPlan {
  const TiltSegmentPlan({
    required this.segment,
    required this.chars,
    required this.startMs,
    required this.endMs,
  });

  final TiltSegment segment;
  final List<TiltChar> chars;

  /// 段里第一个字起唱 / 最后一个字唱完（没有字时取整句起止）。
  final int startMs;
  final int endMs;
}

/// 排版用的整句文字：有字形时间线就用字形拼起来（与时间线逐字对齐），否则用行文字。
String tiltLineFullText(LyricVisualizerLine line) => line.glyphs.isEmpty
    ? line.text
    : line.glyphs.map((LyricVisualizerGlyph g) => g.text).join();

/// [tiltLineFullText] 的词边界：取运行时的共享词级分组（没有字形时间线时按行文字现分）。
List<(int, int)> tiltLineWordSpans(LyricVisualizerLine line) =>
    line.glyphs.isEmpty
    ? tiltWordSpansOfText(line.text)
    : tiltWordSpans(<String>[
        for (final LyricVisualizerGlyph g in line.glyphs) g.text,
      ], line.segments);

/// 给每一段配上字与时间（folia `findSegmentWordRange` + `buildCharTimings`）。逐字歌词直接
/// 取运行时的字形时间；没有字形时间线时段时长取整句起点到句尾离场（folia `getLineRenderEndTime`），
/// 在其中（至少 0.3s）均分。
List<TiltSegmentPlan> buildTiltSegmentPlans(
  TiltLayout layout,
  LyricVisualizerLine line,
) {
  final List<LyricVisualizerGlyph> glyphs = line.glyphs;
  final List<int> glyphOffsets = <int>[];
  int acc = 0;
  for (final LyricVisualizerGlyph g in glyphs) {
    glyphOffsets.add(acc);
    acc += g.text.length;
  }
  final List<TiltSegmentPlan> out = <TiltSegmentPlan>[];
  for (final TiltSegment seg in layout.segments) {
    final int from = seg.charOffset;
    final int to = seg.charOffset + seg.text.length;
    final List<TiltChar> chars = <TiltChar>[];
    int startMs = line.startMs;
    int endMs = line.renderEndMs;
    if (glyphs.isNotEmpty) {
      int visual = 0;
      int? first;
      int? last;
      for (int gi = 0; gi < glyphs.length; gi++) {
        final int o = glyphOffsets[gi];
        if (o < from || o >= to) continue;
        final LyricVisualizerGlyph g = glyphs[gi];
        chars.add(
          TiltChar(
            text: g.text,
            isSpace: g.isSpace,
            visualIndex: visual,
            startMs: g.startMs,
            endMs: g.endMs,
          ),
        );
        if (!g.isSpace) {
          visual++;
          first ??= g.startMs;
          last = g.endMs;
        }
      }
      if (first != null && last != null) {
        startMs = first;
        endMs = last;
      }
    } else {
      final List<String> graphemes = seg.text.characters.toList();
      final int voiced = graphemes
          .where((String c) => c.trim().isNotEmpty)
          .length;
      final double total = math.max(endMs - startMs, 300).toDouble();
      final double step = voiced == 0 ? 0 : total / voiced;
      int visual = 0;
      for (final String c in graphemes) {
        final bool space = c.trim().isEmpty;
        chars.add(
          TiltChar(
            text: c,
            isSpace: space,
            visualIndex: visual,
            startMs: (startMs + step * visual).round(),
            endMs: (startMs + step * (visual + (space ? 0 : 1))).round(),
          ),
        );
        if (!space) visual++;
      }
    }
    out.add(
      TiltSegmentPlan(
        segment: seg,
        chars: chars,
        startMs: startMs,
        endMs: endMs,
      ),
    );
  }
  return out;
}

/// folia `getCharPulseIntensity`：字起唱后按 sin 鼓起又落下（时长夹在 0.2–0.9s），之后
/// 在 1.2 倍时长里爬到 0.25 的余辉并停住。
double tiltCharPulse(int timeMs, int startMs, int endMs) {
  final double raw = math.max(endMs - startMs, 50).toDouble();
  final double duration = raw.clamp(200, 900);
  final double elapsed = (timeMs - startMs).toDouble();
  if (elapsed < 0) return 0;
  if (elapsed <= duration) return math.sin(elapsed / duration * math.pi);
  final double after = elapsed - duration;
  final double ramp = duration * 1.2;
  if (after >= ramp) return 0.25;
  return 0.25 * (after / ramp);
}

/// 字的脉动放大量：斜体 0.18、正体 0.15。
double tiltCharPulseScale(double intensity, bool tilt) =>
    1 + intensity * (tilt ? 0.18 : 0.15);

/// 此刻显到第几段（folia `visibleSegmentIndex`；-1 = 都不显）。段 i 显 = 下标 ≤ 它。过了句尾
/// 离场（[LyricVisualizerLine.renderEndMs]，folia `getLineRenderEndTime`）全部隐去。
int tiltVisibleSegmentIndex(
  List<TiltSegmentPlan> plans,
  LyricVisualizerLine line,
  int timeMs,
) {
  if (timeMs < line.startMs - 100 || timeMs > line.renderEndMs) return -1;
  int target = -1;
  for (int i = 0; i < plans.length; i++) {
    if (timeMs >= plans[i].startMs - kTiltSegmentLeadMs) target = i;
  }
  return target;
}

/// 段 [index] 变成可见的时刻：后面任一段到了提前量、它就跟着显（folia 的 `si <= visibleIndex`），
/// 且不早于这一句成为当前句的时刻 [activeFromMs]。
int tiltSegmentRevealAt(
  List<TiltSegmentPlan> plans,
  int index,
  int activeFromMs,
) {
  int earliest = 1 << 30;
  for (int j = index; j < plans.length; j++) {
    earliest = math.min(earliest, plans[j].startMs - kTiltSegmentLeadMs);
  }
  return math.max(earliest, activeFromMs);
}

/// 一个显隐过渡此刻的进度（0 = 隐，1 = 显）：[revealAtMs] + [delayMs] 起在 [durationMs] 里
/// 按 [kTiltEase] 显出来；[hideAtMs] 之后从当时的值在 [durationMs] 里落回 0（无延迟），
/// 与 framer 从当前值接着过渡一致。
double tiltTransition({
  required int timeMs,
  required int revealAtMs,
  required int hideAtMs,
  required int durationMs,
  int delayMs = 0,
}) {
  if (revealAtMs >= hideAtMs || timeMs < revealAtMs + delayMs) return 0;
  double revealAt(int t) {
    final double p = ((t - revealAtMs - delayMs) / durationMs).clamp(0.0, 1.0);
    return kTiltEase.transform(p);
  }

  if (timeMs <= hideAtMs) return revealAt(timeMs);
  final double from = revealAt(hideAtMs);
  final double q = ((timeMs - hideAtMs) / durationMs).clamp(0.0, 1.0);
  return from * (1 - kTiltEase.transform(q));
}
