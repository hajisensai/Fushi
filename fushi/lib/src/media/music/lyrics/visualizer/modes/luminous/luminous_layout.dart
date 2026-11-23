/// 流光的排版（纯函数，可单测）：显示词的切分（folia `buildPostLyricLayoutUnits`：共享词级分组 +
/// 粘连标点）、
/// 每个词的确定性随机姿态与右边距（folia classic `Visualizer.tsx` 的 `wordConfigs`）、
/// 「防止文字重叠」的伸出量（`glowWordOverlap.ts`），以及 flex-wrap 换行与 justify 摆放。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_timing.dart';

/// 一个要画的词：连续的字形区间（粘连标点并入前一个词）。
@immutable
class LuminousDisplayWord {
  const LuminousDisplayWord({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.glyphs,
  });

  final String text;
  final int startMs;
  final int endMs;

  /// 词内的字形（可能含并入时夹着的空白）。
  final List<LyricVisualizerGlyph> glyphs;

  /// 用来逐字发光的非空白字形数。
  int get voicedGlyphCount =>
      glyphs.where((LyricVisualizerGlyph g) => !g.isSpace).length;
}

final RegExp _stickyTrailing = RegExp(
  r'''^[,.;:!?，。！？、：；）】》」』〉〕］)}\]"'’”]+$''',
);
final RegExp _directContraction = RegExp(
  r'''^['’](s|t|m|d|ll|re|ve|em)$''',
  caseSensitive: false,
);
final RegExp _endsWordChar = RegExp(r'[\p{L}\p{N}]$', unicode: true);

bool _canAttachToPrevious(String previous) =>
    previous.isNotEmpty && !_stickyOnly(previous);

bool _stickyOnly(String s) => _stickyTrailing.hasMatch(s);

bool _isCjkScript(LyricVisualizerScript s) =>
    s == LyricVisualizerScript.han ||
    s == LyricVisualizerScript.hiragana ||
    s == LyricVisualizerScript.katakana ||
    s == LyricVisualizerScript.hangul;

/// 落在「语义词」里的字形下标：共享词级分组（[LyricVisualizerLine.segments]）里含两个以上
/// CJK 字的词组（folia `buildCjkSemanticLayoutUnits` 的 `isSemantic`）。
Set<int> luminousSemanticGlyphs(LyricVisualizerLine line) {
  final Set<int> out = <int>{};
  for (final LyricVisualizerSegment seg in line.segments) {
    int cjk = 0;
    for (int g = seg.firstGlyph; g < seg.firstGlyph + seg.glyphCount; g++) {
      if (_isCjkScript(lyricVisualizerScriptOf(line.glyphs[g].text))) cjk++;
    }
    if (cjk < 2) continue;
    for (int g = seg.firstGlyph; g < seg.firstGlyph + seg.glyphCount; g++) {
      out.add(g);
    }
  }
  return out;
}

/// 显示词。[adaptive] = folia 的自适应排版（先按词分组、再粘连标点 / 缩写）；旧版排版逐词原样。
///
/// folia classic 把多字的 CJK 语义词拆回逐字画（`buildDisplayWordsFromLayoutUnits`），粘在语义词
/// 后面的标点也随之拆开，单独成一个显示词；只有不属于语义词的单元才真正合并标点。
List<LuminousDisplayWord> luminousDisplayWords(
  LyricVisualizerLine line, {
  required bool adaptive,
}) {
  final List<LuminousDisplayWord> out = <LuminousDisplayWord>[];
  final Set<int> semantic = adaptive
      ? luminousSemanticGlyphs(line)
      : const <int>{};
  for (final LyricVisualizerWord w in line.words) {
    final List<LyricVisualizerGlyph> glyphs = line.glyphs.sublist(
      w.firstGlyph,
      w.firstGlyph + w.glyphCount,
    );
    if (adaptive && out.isNotEmpty) {
      final LuminousDisplayWord prev = out.last;
      final int prevGlyph = line.glyphs.indexOf(prev.glyphs.first);
      final bool attach =
          !semantic.contains(prevGlyph) &&
          ((_stickyOnly(w.text) && _canAttachToPrevious(prev.text)) ||
              (_directContraction.hasMatch(w.text) &&
                  _endsWordChar.hasMatch(prev.text)));
      if (attach) {
        // 合并时把两词之间的字形（空白）一并收进来，保持字形区间连续。
        final int from = line.glyphs.indexOf(prev.glyphs.first);
        final List<LyricVisualizerGlyph> merged = line.glyphs.sublist(
          from,
          w.firstGlyph + w.glyphCount,
        );
        out[out.length - 1] = LuminousDisplayWord(
          text: merged.map((LyricVisualizerGlyph g) => g.text).join(),
          startMs: prev.startMs,
          endMs: math.max(prev.endMs, w.endMs),
          glyphs: merged,
        );
        continue;
      }
    }
    out.add(
      LuminousDisplayWord(
        text: w.text,
        startMs: w.startMs,
        endMs: w.endMs,
        glyphs: glyphs,
      ),
    );
  }
  return out;
}

/// 间奏行（folia 判 `fullText === "......"`）：只有点 / 省略号。
bool luminousIsInterlude(String text) {
  final String t = text.trim();
  return t.isNotEmpty && RegExp(r'^[.。…·・]+$').hasMatch(t) && t.length >= 3;
}

/// 右到左文字（阿拉伯 / 希伯来 / 维吾尔…）：第一个强方向字符决定。
bool luminousIsRtl(String text) {
  for (final int c in text.runes) {
    if ((c >= 0x0590 && c <= 0x08FF) ||
        (c >= 0xFB1D && c <= 0xFDFF) ||
        (c >= 0xFE70 && c <= 0xFEFF)) {
      return true;
    }
    if ((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c >= 0x3040) {
      return false;
    }
  }
  return false;
}

/// 主行字号（px）：CSS `clamp(2.25rem·s, 6vw·s, 4.5rem·s)`。
double luminousFontSize(double viewportWidth, double scale) =>
    math.max(36 * scale, math.min(6 * scale * viewportWidth / 100, 72 * scale));

/// 词框行高（em，folia `GLOW_WORD_LINE_HEIGHT`）。
const double luminousLineHeight = 1.22;

/// 行容器最大宽度（Tailwind `max-w-6xl` = 72rem）。
const double luminousMaxLineWidth = 1152;

/// 歌词区内边距（`p-8`）。
const double luminousAreaPadding = 32;

/// 行内 justify（folia 从五种里按行起点挑一种）。
enum LuminousJustify { start, center, end, around, between }

/// folia 的 `Math.sin(seed + i + offset) * 10000` 取小数部分：同一句永远同一布局。
double luminousHashRandom(double seed, int index, int offset) {
  final double x = math.sin(seed + index + offset) * 10000;
  return x - x.floorToDouble();
}

/// 布局参数（tuning + 强度）。
@immutable
class LuminousLayoutParams {
  const LuminousLayoutParams({
    required this.intensity,
    required this.rotation,
    required this.legacy,
    required this.wordSpacing,
    required this.avoidOverlap,
  });

  final LyricVisualizerIntensity intensity;
  final bool rotation;
  final bool legacy;
  final double wordSpacing;
  final bool avoidOverlap;

  bool get effectiveAvoidOverlap => avoidOverlap && !legacy;

  @override
  bool operator ==(Object other) =>
      other is LuminousLayoutParams &&
      other.intensity == intensity &&
      other.rotation == rotation &&
      other.legacy == legacy &&
      other.wordSpacing == wordSpacing &&
      other.avoidOverlap == avoidOverlap;

  @override
  int get hashCode =>
      Object.hash(intensity, rotation, legacy, wordSpacing, avoidOverlap);
}

/// 一句的整行配置与每个词的姿态 / 右边距。
@immutable
class LuminousLinePlan {
  const LuminousLinePlan({
    required this.justify,
    required this.configs,
    required this.margins,
    this.rowGap,
    this.reachTop = 0,
    this.reachBottom = 0,
  });

  final LuminousJustify justify;
  final List<LuminousWordConfig> configs;

  /// 每个词的右（行内末端）边距，px。
  final List<double> margins;

  /// 防重叠时行与行之间的间距；null = 不防重叠（行容器 min-height 300）。
  final double? rowGap;
  final double reachTop;
  final double reachBottom;
}

const List<LuminousJustify> _justifyOptions = <LuminousJustify>[
  LuminousJustify.start,
  LuminousJustify.center,
  LuminousJustify.end,
  LuminousJustify.around,
  LuminousJustify.between,
];

// --- glowWordOverlap.ts -------------------------------------------------------

/// 字形大约占一个 em 高。
const double _glyphHeightEm = 1;
const int _passedTurnSamples = 8;

({double halfWidth, double halfHeight}) _reachAt(
  double width,
  double glyphHeight,
  double scale,
  double rotateDeg,
) {
  final double r = rotateDeg * math.pi / 180;
  final double c = math.cos(r).abs();
  final double s = math.sin(r).abs();
  return (
    halfWidth: scale * (width * c + glyphHeight * s) / 2,
    halfHeight: scale * (glyphHeight * c + width * s) / 2,
  );
}

/// 词画出来最宽的时候（active 放大 / passed 旋转过程中）的半宽半高。
({double halfWidth, double halfHeight}) luminousWordReach(
  double width,
  double fontSize,
  LuminousWordConfig pose,
) {
  final double gh = fontSize * _glyphHeightEm;
  final ({double halfWidth, double halfHeight}) active = _reachAt(
    width,
    gh,
    pose.scale * luminousActiveScale,
    pose.rotate,
  );
  double hw = active.halfWidth;
  double hh = active.halfHeight;
  for (int step = 0; step <= _passedTurnSamples; step++) {
    final ({double halfWidth, double halfHeight}) p = _reachAt(
      width,
      gh,
      pose.scale,
      pose.rotate + pose.passedRotate * step / _passedTurnSamples,
    );
    hw = math.max(hw, p.halfWidth);
    hh = math.max(hh, p.halfHeight);
  }
  return (halfWidth: hw, halfHeight: hh);
}

/// 相邻两词刚好不相碰需要的间距（folia `getGlowWordPairGap`）。
double luminousPairGap(
  double firstWidth,
  LuminousWordConfig first,
  double secondWidth,
  LuminousWordConfig second,
  double fontSize, {
  bool rtl = false,
}) {
  final double a = luminousWordReach(firstWidth, fontSize, first).halfWidth;
  final double b = luminousWordReach(secondWidth, fontSize, second).halfWidth;
  final double toward = rtl ? second.x - first.x : first.x - second.x;
  return (a - firstWidth / 2) + (b - secondWidth / 2) + toward;
}

/// 词伸出排版框的上下量（folia `getGlowWordOverflow` 的 top / bottom）。
({double top, double bottom}) luminousWordOverflowY(
  double width,
  double fontSize,
  LuminousWordConfig pose,
) {
  final double hh = luminousWordReach(width, fontSize, pose).halfHeight;
  final double over = hh - fontSize * luminousLineHeight / 2;
  return (top: math.max(0, over - pose.y), bottom: math.max(0, over + pose.y));
}

/// 一句的姿态与边距（folia `wordConfigs` / `lineConfig`）。[seed] 是行起点（秒）。
LuminousLinePlan luminousPlanLine({
  required double seed,
  required List<double> wordWidths,
  required double fontSize,
  required LuminousLayoutParams params,
  required bool interlude,
  required bool rtl,
}) {
  final bool chaotic = params.intensity == LyricVisualizerIntensity.chaotic;
  final bool calm = params.intensity == LyricVisualizerIntensity.calm;
  final LuminousJustify justify = interlude || calm
      ? LuminousJustify.center
      : _justifyOptions[(seed % _justifyOptions.length).floor()];
  final double baseSpread = chaotic
      ? 60
      : calm
      ? 0
      : 20;
  final double baseRotate = chaotic
      ? 30
      : calm
      ? 0
      : 5;
  final bool avoid = params.effectiveAvoidOverlap;
  final int n = wordWidths.length;

  LuminousWordConfig placementOf(int i) {
    double r(int o) => luminousHashRandom(seed, i, o);
    return LuminousWordConfig(
      scale: chaotic ? 0.8 + r(4) * 0.6 : 1.1 + r(4) * 0.2,
      rotate: params.rotation ? (r(3) - 0.5) * baseRotate * 2 : 0,
      passedRotate: params.rotation ? (r(8) - 0.5) * 45 : 0,
      x: (r(1) - 0.5) * baseSpread * 2,
      y: (r(2) - 0.5) * baseSpread * 2,
    );
  }

  final List<LuminousWordConfig> configs = <LuminousWordConfig>[];
  final List<double> margins = <double>[];
  double reachTop = 0;
  double reachBottom = 0;
  for (int i = 0; i < n; i++) {
    double r(int o) => luminousHashRandom(seed, i, o);
    if (interlude) {
      configs.add(
        LuminousWordConfig(
          x: 0,
          y: (r(2) - 0.5) * 15,
          rotate: 0,
          scale: 1.5,
          passedRotate: 0,
        ),
      );
      margins.add(48); // 3rem
      continue;
    }
    final LuminousWordConfig p = placementOf(i);
    configs.add(p);
    double margin = chaotic ? r(5) * 1.5 * 16 : 0.8 * 16;
    if (!params.legacy) {
      // 按放大与偏移算出刚好不压字的边距，再乘词距倍数。
      final double wi = wordWidths[i];
      final double si = p.scale * luminousActiveScale;
      double wNext = 0;
      double sNext = 1;
      double xNext = 0;
      LuminousWordConfig? next;
      if (i + 1 < n) {
        next = placementOf(i + 1);
        sNext = next.scale * luminousActiveScale;
        xNext = next.x;
        wNext = wordWidths[i + 1];
      }
      final double spacing = params.wordSpacing;
      final double gap = 0.05 * fontSize;
      final double halfI = wi * (si - 1) / 2;
      final double halfNext = wNext * (sNext - 1) / 2;
      final double xDiff = rtl ? xNext - p.x : p.x - xNext;
      final double calculated = (halfI + halfNext + xDiff + gap) * spacing;
      final double minMargin = (chaotic ? 0.08 : 0.12) * fontSize * spacing;
      margin = math.max(minMargin, calculated);
      if (avoid) {
        if (next != null) {
          final double pair = luminousPairGap(
            wi,
            p,
            wNext,
            next,
            fontSize,
            rtl: rtl,
          );
          margin = math.max(margin, pair + gap);
        }
        final ({double top, double bottom}) o = luminousWordOverflowY(
          wi,
          fontSize,
          p,
        );
        reachTop = math.max(reachTop, o.top);
        reachBottom = math.max(reachBottom, o.bottom);
      }
      margin = (margin * 10).roundToDouble() / 10;
    }
    margins.add(margin);
  }
  return LuminousLinePlan(
    justify: justify,
    configs: configs,
    margins: margins,
    rowGap: avoid ? (reachTop + reachBottom).ceilToDouble() : null,
    reachTop: avoid ? reachTop.ceilToDouble() : 0,
    reachBottom: avoid ? reachBottom.ceilToDouble() : 0,
  );
}

/// flex-wrap 排出来的一个词框（行容器坐标，左上为原点）。
@immutable
class LuminousSlot {
  const LuminousSlot({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  final double left;
  final double top;
  final double width;
  final double height;

  double get centerX => left + width / 2;
  double get centerY => top + height / 2;
}

/// flex-wrap 排版结果。
@immutable
class LuminousFlow {
  const LuminousFlow({
    required this.slots,
    required this.width,
    required this.height,
    required this.rows,
  });

  final List<LuminousSlot> slots;

  /// 行容器宽高（含防重叠的上下伸出量 / min-height）。
  final double width;
  final double height;
  final int rows;
}

/// CSS `flex flex-wrap content-center justify-*`：词按 宽 + 右边距 依次排，放不下换行；
/// 每行按 [justify] 分配剩余空间；所有行整体在容器里垂直居中。RTL 行从右往左排。
LuminousFlow luminousFlow({
  required List<double> widths,
  required List<double> margins,
  required double containerWidth,
  required double rowHeight,
  required LuminousJustify justify,
  required bool rtl,
  double? rowGap,
  double reachTop = 0,
  double reachBottom = 0,
  double minHeight = 300,
}) {
  final List<List<int>> rows = <List<int>>[];
  List<int> current = <int>[];
  double used = 0;
  for (int i = 0; i < widths.length; i++) {
    final double outer = widths[i] + margins[i];
    if (current.isNotEmpty && used + outer > containerWidth + 0.01) {
      rows.add(current);
      current = <int>[];
      used = 0;
    }
    current.add(i);
    used += outer;
  }
  if (current.isNotEmpty) rows.add(current);

  final double gap = rowGap ?? 0;
  final double contentHeight =
      rows.length * rowHeight + math.max(0, rows.length - 1) * gap;
  final double boxHeight = rowGap == null
      ? math.max(minHeight, contentHeight)
      : contentHeight + reachTop + reachBottom;
  final double firstTop = rowGap == null
      ? (boxHeight - contentHeight) / 2
      : reachTop;

  final List<LuminousSlot?> slots = List<LuminousSlot?>.filled(
    widths.length,
    null,
  );
  for (int r = 0; r < rows.length; r++) {
    final List<int> row = rows[r];
    final double total = row.fold<double>(
      0,
      (double s, int i) => s + widths[i] + margins[i],
    );
    final double free = containerWidth - total;
    double lead;
    double between = 0;
    switch (justify) {
      case LuminousJustify.start:
        lead = 0;
      case LuminousJustify.center:
        lead = free / 2;
      case LuminousJustify.end:
        lead = free;
      case LuminousJustify.around:
        if (free <= 0) {
          lead = free / 2;
        } else {
          between = free / row.length;
          lead = between / 2;
        }
      case LuminousJustify.between:
        if (free <= 0 || row.length < 2) {
          lead = 0;
        } else {
          lead = 0;
          between = free / (row.length - 1);
        }
    }
    double x = lead;
    final double top = firstTop + r * (rowHeight + gap);
    for (final int i in row) {
      final double left = rtl ? containerWidth - x - widths[i] : x;
      slots[i] = LuminousSlot(
        left: left,
        top: top,
        width: widths[i],
        height: rowHeight,
      );
      x += widths[i] + margins[i] + between;
    }
  }
  return LuminousFlow(
    slots: slots.cast<LuminousSlot>(),
    width: containerWidth,
    height: boxHeight,
    rows: rows.length,
  );
}

/// 「防止文字重叠」放不下时的缩小倍数（folia `useOverlapFit`：最少 0.5，留 2% 余量）。
double luminousOverlapFit(double availableHeight, double contentHeight) {
  if (contentHeight <= 0 || availableHeight >= contentHeight) return 1;
  return math.max(0.5, availableHeight / contentHeight * 0.98);
}
