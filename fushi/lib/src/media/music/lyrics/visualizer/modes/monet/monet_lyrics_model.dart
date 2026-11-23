/// 莫奈歌词栏的纯算法（移植 folia `monet/monetLyricsModel.ts`、`monetRailLayout.ts`、
/// `monetLyricMotion.ts`）：可见窗口与行状态、行色调、栈式排布、版面尺寸、扫字填充与发光包络。
/// 不碰 Canvas / TextPainter，单测直接调。
///
/// 时间一律是歌词显示时间（毫秒）；folia 用秒，常量已换算。
library;

import 'dart:math' as math;

import 'package:flutter/animation.dart' show Curves;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';

/// 行状态（folia `MonetLineStatus`）。
enum MonetLineStatus { waiting, active, passed }

/// 歌词栏里的一项：行下标、相对锚点的偏移、状态。
class MonetVisibleEntry {
  const MonetVisibleEntry({
    required this.index,
    required this.offset,
    required this.status,
  });

  /// 在 `runtime.lines` 里的下标。
  final int index;

  /// 相对锚点（当前行 / 下一句 / 刚唱完的一句）的偏移。
  final int offset;
  final MonetLineStatus status;
}

// ---------------------------------------------------------------------------
// 版面尺寸（folia 的 Tailwind clamp / 断点换成按舞台宽度算）
// ---------------------------------------------------------------------------

const double kMonetRootFontPx = 16;
const double _kLargeScreenMinPx = 1536;
const double _kLargeScreenFullPx = 2200;
const double _kLargeScreenMaxScale = 1.16;

/// 歌词栏基准最大宽度。
const double kMonetRailBaseMaxWidthPx = 780;

/// 歌词栏基准最大高度。
const double kMonetRailBaseMaxHeightPx = 520;

/// 整排（文字列 + 肖像列）基准最大宽度。
const double kMonetRowBaseMaxWidthPx = 1520;

/// 肖像列基准最大宽度。
const double kMonetPortraitBaseMaxPx = 430;

/// 肖像框基准最大宽度。
const double kMonetPortraitInnerBaseMaxPx = 380;

/// 高度上限至少容得下这么多行当前句。
const int kMonetRailMinRows = 7;

/// 正方形封面比列宽多出的比例（folia 135.135% / -35.135%）。
const double kMonetSquareBleed = 0.35135;

/// 超宽屏（> 2xl）整体放大，列宽与字号同倍，换行不变（folia `resolveMonetLargeScreenScale`）。
double monetLargeScreenScale(double widthPx) {
  if (widthPx <= _kLargeScreenMinPx) return 1;
  final double p = math.min(
    1,
    (widthPx - _kLargeScreenMinPx) / (_kLargeScreenFullPx - _kLargeScreenMinPx),
  );
  return 1 + (_kLargeScreenMaxScale - 1) * p;
}

/// CSS `clamp(minRem, preferredVw, maxRem)`，vw 按舞台宽度算。
double monetClampFontPx(
  double minRem,
  double preferredVw,
  double maxRem,
  double viewportWidthPx,
) => math.min(
  maxRem * kMonetRootFontPx,
  math.max(minRem * kMonetRootFontPx, viewportWidthPx * preferredVw / 100),
);

/// CSS `clamp(min, preferred, max)`。
double monetClamp(double min, double preferred, double max) =>
    math.min(max, math.max(min, preferred));

/// 当前句字号。
double monetLyricFontPx(double width, double fontScale) =>
    monetClampFontPx(1.34, 2.75, 2.28, width) *
    fontScale *
    monetLargeScreenScale(width);

/// 非当前句的参考字号（只用来定缩放比）。
double monetInactiveFontPx(double width, double fontScale) =>
    monetClampFontPx(1.08, 2, 1.48, width) *
    fontScale *
    monetLargeScreenScale(width);

/// 译文字号。
double monetTranslationFontPx(double width, double fontScale) =>
    monetClampFontPx(0.94, 1.28, 1.14, width) *
    fontScale *
    monetLargeScreenScale(width);

/// 非当前句相对当前句的缩放基数（folia `buildPositionedEntries`）。
double monetInactiveScale(double lyricFontPx, double inactiveFontPx) =>
    (inactiveFontPx / math.max(lyricFontPx, 1)).clamp(0.72, 0.92);

/// 光晕留白（行左右 / 上下各让出这么多，发光不被裁掉）。
double monetGlowBufferPx(double lyricFontPx) =>
    (lyricFontPx * 1.2).roundToDouble();

/// 歌词栏高度：`clamp(280px, 52vh, max(520·s, 字号·1.18·7))`。
double monetRailHeightPx(double stageHeight, double lyricFontPx, double ls) {
  final double maxH = math.max(
    kMonetRailBaseMaxHeightPx * ls,
    lyricFontPx * 1.18 * kMonetRailMinRows,
  );
  return monetClamp(280, stageHeight * 0.52, maxH.roundToDouble());
}

/// 文字列左右内边距（px-5 / sm:px-8 / lg:px-14 / 2xl:px-20）。
double monetTextPadX(double width) => width >= 1536
    ? 80
    : width >= 1024
    ? 56
    : width >= 640
    ? 32
    : 20;

/// 文字列上下内边距（py-5 / sm:py-6 / lg:py-8）。
double monetTextPadY(double width) => width >= 1024
    ? 32
    : width >= 640
    ? 24
    : 20;

/// 底部频谱的左右内边距（px-5 / sm:px-8 / lg:px-14）。
double monetAudioPadX(double width) => width >= 1024
    ? 56
    : width >= 640
    ? 32
    : 20;

/// 肖像列靠屏幕边一侧的内边距（pr-5 / sm:pr-8 / lg:pr-10 / xl:pr-12）。
double monetPortraitEdgePad(double width) => width >= 1280
    ? 48
    : width >= 1024
    ? 40
    : width >= 640
    ? 32
    : 20;

/// 肖像只在 md（≥768）以上显示。
bool monetShowsPortrait(double width) => width >= 768;

// ---------------------------------------------------------------------------
// 可见窗口与行状态
// ---------------------------------------------------------------------------

/// folia `resolveMonetLineStatus`。
MonetLineStatus monetLineStatus(
  LyricVisualizerLine line,
  int index,
  int activeIndex,
  int timeMs,
) {
  if (index == activeIndex ||
      (activeIndex < 0 && timeMs >= line.startMs && timeMs <= line.endMs)) {
    return MonetLineStatus.active;
  }
  if (timeMs > line.endMs || (activeIndex >= 0 && index < activeIndex)) {
    return MonetLineStatus.passed;
  }
  return MonetLineStatus.waiting;
}

/// 取锚点前后各几行，标好状态（folia `buildMonetVisibleLineEntries`）。锚点：当前行；
/// 间奏里是下一句；唱完了是最后唱完的一句。
List<MonetVisibleEntry> buildMonetVisibleEntries(
  LyricVisualizerRuntime runtime,
  int timeMs, {
  int before = 2,
  int after = 2,
}) {
  final List<LyricVisualizerLine> lines = runtime.lines;
  if (lines.isEmpty) return const <MonetVisibleEntry>[];
  final int activeIndex = runtime.activeLineAt(timeMs);
  final int last = runtime.lastStartedLineAt(timeMs);
  final int upcomingIndex = last + 1 < lines.length ? last + 1 : -1;
  final int recentIndex = activeIndex < 0 ? last : -1;
  final int anchor = activeIndex >= 0
      ? activeIndex
      : upcomingIndex >= 0
      ? upcomingIndex
      : recentIndex;
  if (anchor < 0) return const <MonetVisibleEntry>[];
  final int start = math.max(0, anchor - before);
  final int end = math.min(lines.length - 1, anchor + after);
  return <MonetVisibleEntry>[
    for (int i = start; i <= end; i++)
      MonetVisibleEntry(
        index: i,
        offset: i - anchor,
        status: monetLineStatus(lines[i], i, activeIndex, timeMs),
      ),
  ];
}

// ---------------------------------------------------------------------------
// 手动滚动（folia `monetRailLayout.ts`：滚轮 / 触摸翻行，停手 1.8 秒回到当前句）
// ---------------------------------------------------------------------------

/// 停手多久回到自动跟随（folia `MONET_SCROLL_IDLE_RESET_MS`），秒。
const double kMonetScrollIdleResetSeconds = 1.8;

/// 滚轮累计多少 px 翻一行（folia `MONET_SCROLL_STEP_PX`）。
const double kMonetScrollStepPx = 72;

/// 触摸拖多少 px 翻一行（folia `MONET_TOUCH_STEP_PX`）。
const double kMonetTouchStepPx = 52;

/// 手动滚动时锚点前后各显示几行（folia `MONET_SCROLL_BEFORE` / `AFTER`）。
const int kMonetScrollBefore = 4;
const int kMonetScrollAfter = 4;

/// folia `clampScrollSteps`：一次最多翻一行。
int monetClampScrollSteps(int steps) => steps.clamp(-1, 1);

/// folia `getScrollDirection`。
int monetScrollDirection(double delta) => delta == 0
    ? 0
    : delta > 0
    ? 1
    : -1;

/// 手动滚动时的窗口（folia `buildScrollableRailEntries`）：以 [anchor] 为中心前后各四行，
/// 状态只按当前行下标 [activeIndex] 定。
List<MonetVisibleEntry> buildMonetScrollableEntries(
  int lineCount,
  int anchor,
  int activeIndex,
) {
  if (lineCount <= 0) return const <MonetVisibleEntry>[];
  final int a = anchor.clamp(0, lineCount - 1);
  final int start = math.max(0, a - kMonetScrollBefore);
  final int end = math.min(lineCount - 1, a + kMonetScrollAfter);
  return <MonetVisibleEntry>[
    for (int i = start; i <= end; i++)
      MonetVisibleEntry(
        index: i,
        offset: i - a,
        status: i == activeIndex
            ? MonetLineStatus.active
            : activeIndex >= 0 && i < activeIndex
            ? MonetLineStatus.passed
            : MonetLineStatus.waiting,
      ),
  ];
}

// ---------------------------------------------------------------------------
// 书写方向与换行
// ---------------------------------------------------------------------------

/// 词内字形之间插的零宽禁断符（U+2060 WORD JOINER）：让计时词像 folia 的 inline-block 一样
/// 整词换行。
const String kMonetWordJoiner = '\u2060';

final RegExp _letter = RegExp(r'\p{L}', unicode: true);
final RegExp _rtlLetter = RegExp(
  r'[\p{Script=Arabic}\p{Script=Hebrew}\p{Script=Syriac}\p{Script=Thaana}'
  r'\p{Script=Nko}\p{Script=Samaritan}\p{Script=Mandaic}\p{Script=Adlam}'
  r'\p{Script=Hanifi_Rohingya}\p{Script=Yezidi}]',
  unicode: true,
);

/// folia `resolveLyricTextDirection`：按第一个字母定整行方向（数字 / 标点 / 空格跳过）。
bool monetIsRtlText(String text) {
  for (final int rune in text.runes) {
    final String ch = String.fromCharCode(rune);
    if (!_letter.hasMatch(ch)) continue;
    return _rtlLetter.hasMatch(ch);
  }
  return false;
}

/// 一行的色调（folia `resolveLineTone`）。[baseAlpha] 是未唱字的主色透明度。
class MonetLineTone {
  const MonetLineTone({
    required this.opacity,
    required this.scale,
    required this.blurPx,
    required this.baseAlpha,
    required this.zIndex,
  });

  final double opacity;
  final double scale;
  final double blurPx;
  final double baseAlpha;
  final int zIndex;
}

/// folia `resolveLineTone`：离当前句越远越小、越淡、越糊；未唱的比已唱的亮一点。
MonetLineTone monetLineTone(
  MonetLineStatus status,
  int offset,
  double inactiveScale,
) {
  if (status == MonetLineStatus.active) {
    return const MonetLineTone(
      opacity: 1,
      scale: 1,
      blurPx: 0,
      baseAlpha: 0.34,
      zIndex: 4,
    );
  }
  final int distance = math.max(offset.abs(), 1);
  final bool waiting = status == MonetLineStatus.waiting;
  return MonetLineTone(
    opacity: waiting
        ? (0.72 - (distance - 1) * 0.18).clamp(0.36, 0.72)
        : (0.52 - (distance - 1) * 0.12).clamp(0.28, 0.52),
    scale: (inactiveScale * math.pow(0.9, distance - 1)).clamp(0.68, 0.92),
    blurPx: waiting
        ? (distance == 1 ? 0.7 : 1.8 + (distance - 2) * 0.8)
        : 1.1 + (distance - 1) * 0.7,
    baseAlpha: waiting ? 0.46 : 0.36,
    zIndex: waiting ? 3 - distance : 2 - distance,
  );
}

/// 两行之间的空隙：挨着当前句的大一点（folia `resolveLineGap`）。
double monetLineGap(MonetLineStatus a, MonetLineStatus b, double lyricFontPx) =>
    a == MonetLineStatus.active || b == MonetLineStatus.active
    ? math.max(18, lyricFontPx * 0.49)
    : math.max(14, lyricFontPx * 0.38);

/// 按固定轨道排出每项的 y（folia `buildPositionedEntries`）：锚点的中心在栏高 46% 处，
/// 其余上下依次堆，间距按 [monetLineGap]。[scaledHeights] 与 [entries] 一一对应。
List<double> monetStackPositions(
  List<MonetVisibleEntry> entries,
  List<double> scaledHeights,
  double railHeight,
  double lyricFontPx,
) {
  if (entries.isEmpty) return const <double>[];
  final List<double> y = List<double>.filled(entries.length, 0);
  int anchor = entries.indexWhere((MonetVisibleEntry e) => e.offset == 0);
  if (anchor < 0) anchor = 0;
  y[anchor] = railHeight * 0.46 - scaledHeights[anchor] / 2;
  for (int i = anchor + 1; i < entries.length; i++) {
    y[i] =
        y[i - 1] +
        scaledHeights[i - 1] +
        monetLineGap(entries[i - 1].status, entries[i].status, lyricFontPx);
  }
  for (int i = anchor - 1; i >= 0; i--) {
    y[i] =
        y[i + 1] -
        scaledHeights[i] -
        monetLineGap(entries[i].status, entries[i + 1].status, lyricFontPx);
  }
  return y;
}

// ---------------------------------------------------------------------------
// 一行的盒子尺寸（folia `measureMonetLineLayout`）
// ---------------------------------------------------------------------------

/// 当前句最多为这么多行留位置（真正画时不截断）。
const int kMonetActiveTextLineLimit = 14;

/// 非当前句最多两行，多的渐隐截掉。
const int kMonetInactiveTextLineLimit = 2;

/// 译文最多两行。
const int kMonetTranslationLineLimit = 2;

/// 行高倍数。
const double kMonetLineHeightFactor = 1.18;

/// 译文行高倍数。
const double kMonetTranslationLineHeightFactor = 1.28;

double monetTextPaddingTop(double fontPx) => math.max(fontPx * 0.16, 8);
double monetTextPaddingBottom(double fontPx) => math.max(fontPx * 0.34, 14);
double monetTranslationPaddingTop(double fontPx) => math.max(fontPx * 0.45, 7);
double monetTranslationPaddingBottom(double fontPx) =>
    math.max(fontPx * 0.18, 5);

/// 一行歌词正文的保留高度（不含译文）。
double monetTextBoxHeight({
  required double fontPx,
  required int lineCount,
  required bool active,
}) {
  final int visible = math.min(
    math.max(lineCount, 1),
    active ? kMonetActiveTextLineLimit : kMonetInactiveTextLineLimit,
  );
  return visible * fontPx * kMonetLineHeightFactor +
      monetTextPaddingTop(fontPx) +
      monetTextPaddingBottom(fontPx);
}

/// 译文盒子的保留高度（0 行即无译文）。
/// 描述胶囊的文字（folia `capsuleLabel`）：用户自定义 → 主题描述 → 主题名 → 样式名。
String monetCapsuleLabel({
  required String custom,
  required LyricVisualizerTheme? theme,
  required String fallback,
}) {
  for (final String? s in <String?>[custom, theme?.description, theme?.name]) {
    final String v = s?.trim() ?? '';
    if (v.isNotEmpty) return v;
  }
  return fallback;
}

// ---------------------------------------------------------------------------
// 扫字与发光（folia `monetLyricMotion.ts` / `MonetRailTokens.tsx`）
// ---------------------------------------------------------------------------

double _clamp01(double v) => v.clamp(0.0, 1.0);

double _smoothstep(double p) => p * p * (3 - 2 * p);

/// 词的发光包络：起唱后用 1.18 倍时长平滑升到峰值，驻留到行尾（至少词尾后 1.05 秒），
/// 再平滑消失（folia `resolveMonetGlow`）。
double monetGlow(int timeMs, int startMs, int endMs, int lineEndMs) {
  if (timeMs <= startMs) return 0;
  final double rise = math.max(1, endMs - startMs) * 1.18;
  final double peak = startMs + rise;
  final double tail = math.max(lineEndMs.toDouble(), endMs + 1050.0);
  if (timeMs <= peak) {
    return _smoothstep(_clamp01((timeMs - startMs) / rise));
  }
  final double remaining =
      1 - _clamp01((timeMs - peak) / math.max(180, tail - peak));
  return _smoothstep(remaining);
}

/// 扫字前沿的位置（px）：按字形各自的起止时间在量好的字形偏移之间插值；没有字形时间时
/// 按整词均分（folia `resolveMonetFillWidth`）。[offsets] 是累计宽度（首项 0，长度 = 字形数 + 1）。
double monetFillWidth(
  int timeMs,
  int startMs,
  int endMs,
  List<double> offsets,
  List<(int, int)> timings,
) {
  final double width = offsets.isEmpty ? 0 : offsets.last;
  if (timeMs <= startMs) return 0;
  if (timeMs >= endMs) return width;
  final int count = math.min(timings.length, offsets.length - 1);
  if (count > 0) {
    for (int i = 0; i < count; i++) {
      final int ts = math.max(startMs, timings[i].$1);
      final int te = math.max(ts, timings[i].$2);
      if (timeMs < ts) return offsets[i];
      if (timeMs <= te) {
        final double p = (timeMs - ts) / math.max(1, te - ts);
        return offsets[i] + (offsets[i + 1] - offsets[i]) * p;
      }
    }
    return offsets[count];
  }
  if (offsets.length < 2) return width;
  final double index =
      _clamp01((timeMs - startMs) / math.max(1, endMs - startMs)) *
      (offsets.length - 1);
  final int whole = index.floor();
  final double a = offsets[math.min(whole, offsets.length - 1)];
  final double b = offsets[math.min(whole + 1, offsets.length - 1)];
  return a + (b - a) * (index - whole);
}

/// 扫字前沿的羽化宽度：短 CJK 词也能连续交接（folia `resolveMonetSweepEdgeSoftness`）。
double monetSweepEdgeSoftness(double fontPx) =>
    math.max(math.min(fontPx * 0.45, 16), 6);

/// 前沿再推出去一段，词尾时羽化尾巴正好扫完（folia `resolveMonetSweepEnd`）。
double monetSweepEnd(double filledPx, double fullPx, double edgePx) {
  if (fullPx <= 0) return 0;
  final double p = _clamp01(filledPx / fullPx);
  return filledPx + edgePx * p;
}

/// 扫字遮罩在词内位置 [x]（从词首量起的累计 px）处的不透明度：实心段 1，羽化段
/// 1 → 0.92 → 0，再乘上填充色自身沿词的渐变（1 → 0.92@68% → 0.72@100%）。
double monetSweepMaskAlpha(
  double x,
  double sweepEnd,
  double edge,
  double full,
) {
  final double solidEnd = math.max(sweepEnd - edge, 0);
  final double featherStart = math.max(sweepEnd - edge * 0.55, 0);
  final double featherEnd = math.max(sweepEnd, 0);
  double a;
  if (x <= solidEnd) {
    a = 1;
  } else if (x <= featherStart) {
    final double d = featherStart - solidEnd;
    a = d <= 0 ? 0.92 : 1 - 0.08 * (x - solidEnd) / d;
  } else if (x < featherEnd) {
    final double d = featherEnd - featherStart;
    a = d <= 0 ? 0 : 0.92 * (1 - (x - featherStart) / d);
  } else {
    a = 0;
  }
  if (full <= 0) return a;
  final double p = _clamp01(x / full);
  final double fill = p <= 0.68
      ? 1 - 0.08 * p / 0.68
      : 0.92 - 0.2 * (p - 0.68) / 0.32;
  return a * fill;
}

/// 把遮罩在 [c0, c1]（一段同一行内的字形，累计坐标）上离散成渐变色标：返回
/// （0–1 位置，不透明度）。在所有拐点处取样，段内线性插值。
List<(double, double)> monetSweepMaskStops(
  double c0,
  double c1,
  double sweepEnd,
  double edge,
  double full,
) {
  final double span = c1 - c0;
  if (span <= 0) {
    return <(double, double)>[
      (0, monetSweepMaskAlpha(c0, sweepEnd, edge, full)),
      (1, monetSweepMaskAlpha(c0, sweepEnd, edge, full)),
    ];
  }
  final List<double> xs = <double>[
    c0,
    c1,
    math.max(sweepEnd - edge, 0),
    math.max(sweepEnd - edge * 0.55, 0),
    math.max(sweepEnd, 0),
    full * 0.68,
  ].where((double x) => x >= c0 && x <= c1).toList()..sort();
  final List<(double, double)> out = <(double, double)>[];
  double? last;
  for (final double x in xs) {
    if (last != null && (x - last).abs() < 1e-6) continue;
    last = x;
    out.add(((x - c0) / span, monetSweepMaskAlpha(x, sweepEnd, edge, full)));
  }
  return out;
}

// ---------------------------------------------------------------------------
// 肖像
// ---------------------------------------------------------------------------

/// folia `portraitUrl`：自定义时用素材图（没有就回落封面）；封面时用封面（没有就回落素材图）。
String? monetPortraitPath({
  required String source,
  required String? cover,
  required String? custom,
}) {
  final String? c = (cover?.isEmpty ?? true) ? null : cover;
  return source == 'custom' ? (custom ?? c) : (c ?? custom);
}

const List<double> _shakeY = <double>[0, -18, 0, 18, 0];
const List<double> _shakeX = <double>[0, -9, 0, 9, 0];
const List<double> _shakeRot = <double>[0, 1.2, 0, -1.2, 0];

/// folia chaotic 强度下封面的晃动：9 秒一圈的关键帧（y ±18、x ±9、转 ±1.2°），每段 easeInOut，
/// 首圈延后 0.2 秒。[seconds] 是挂载以来的墙钟秒数。返回 (dx, dy, 转角度数)。
(double, double, double) monetChaoticShake(double seconds) {
  final double t = seconds - 0.2;
  if (t <= 0) return (0, 0, 0);
  final double phase = (t % 9) / 9 * 4;
  final int seg = phase.floor().clamp(0, 3);
  final double k = Curves.easeInOut.transform(phase - seg);
  double at(List<double> v) => v[seg] + (v[seg + 1] - v[seg]) * k;
  return (at(_shakeX), at(_shakeY), at(_shakeRot));
}

/// 离开 chaotic 后的回正：从 [from]（离开时的姿态）用 0.8 秒 easeOut 缓回 0（framer
/// `animate={{ x: 0, y: 0, rotate: 0 }}` + `{ duration: 0.8, ease: 'easeOut' }`）。[seconds] 是离开后的秒数。
(double, double, double) monetCalmShake(
  (double, double, double) from,
  double seconds,
) {
  final double p = (seconds / kMonetCalmSeconds).clamp(0.0, 1.0);
  if (p >= 1) return (0, 0, 0);
  final double k = 1 - Curves.easeOut.transform(p);
  return (from.$1 * k, from.$2 * k, from.$3 * k);
}

/// folia 回正时长。
const double kMonetCalmSeconds = 0.8;

/// 封面交叉淡入时长（folia `MONET_PORTRAIT_FADE_MS`）。
const double kMonetPortraitFadeSeconds = 0.9;

/// 肖像叠层上限（folia `MONET_PORTRAIT_MAX_LAYERS`）。
const int kMonetPortraitMaxLayers = 4;
