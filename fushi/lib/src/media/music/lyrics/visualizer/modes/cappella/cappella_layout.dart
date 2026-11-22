/// 群唱的排版：视口尺寸推导、气泡测量（TextPainter）与逐字前缀尺寸表缓存、气泡配色。
/// 对应 folia `VisualizerCappella.tsx` 的尺寸计算、`cappellaBubbleMetrics.ts` 与
/// `cappellaMessageLayout.ts`（高度估算 / 配色）。
library;

import 'dart:collection';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_config.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_messages.dart';

/// 由视口宽高与字号倍数推出的排版尺寸。
@immutable
class CappellaViewport {
  const CappellaViewport({
    required this.size,
    required this.padX,
    required this.padTop,
    required this.panelLeft,
    required this.panelWidth,
    required this.groupMaxWidth,
    required this.maxTextWidth,
    required this.baseFontSize,
  });

  /// folia：`px-4 sm:px-8 lg:px-14`、`pt-12 sm:pt-16 lg:pt-20`、面板 `max-w-4xl`、
  /// 气泡组宽 78%（窄屏）/ 68%，文字宽 = 面板 × 比例 − 56。
  factory CappellaViewport.of(Size size, double fontScale) {
    final double w = size.width;
    final double padX = w >= 1024 ? 56 : (w >= 640 ? 32 : 16);
    final double padTop = w >= 1024 ? 80 : (w >= 640 ? 64 : 48);
    final double panelWidth = math.max(
      1,
      math.min(w - padX * 2, kCappellaPanelMaxWidth),
    );
    final double ratio = w >= 640 ? 0.68 : 0.78;
    final double maxPanel = math.min(
      math.max(w - 32, 1),
      kCappellaPanelMaxWidth,
    );
    return CappellaViewport(
      size: size,
      padX: padX,
      padTop: padTop,
      panelLeft: (w - panelWidth) / 2,
      panelWidth: panelWidth,
      groupMaxWidth: panelWidth * ratio,
      maxTextWidth: math.max(96, (maxPanel * ratio - 56).floorToDouble()),
      baseFontSize: (18 * fontScale).clamp(15, 26).toDouble(),
    );
  }

  final Size size;
  final double padX;
  final double padTop;
  final double panelLeft;
  final double panelWidth;
  final double groupMaxWidth;
  final double maxTextWidth;
  final double baseFontSize;

  double get panelRight => panelLeft + panelWidth;

  @override
  bool operator ==(Object other) =>
      other is CappellaViewport &&
      other.size == size &&
      other.baseFontSize == baseFontSize;

  @override
  int get hashCode => Object.hash(size, baseFontSize);
}

/// 一种气泡排版（字号 + 内边距）。
@immutable
class CappellaBubbleStyle {
  const CappellaBubbleStyle({
    required this.fontSize,
    required this.padX,
    required this.padY,
    required this.minHeight,
    required this.minWidth,
  });

  /// folia `CappellaMessageRow`：当前行放大字号与内边距、最小高 / 宽；标题用基准字号。
  factory CappellaBubbleStyle.of({
    required CappellaMessage message,
    required bool active,
    required double baseFontSize,
    required CappellaMotion motion,
  }) {
    final double fontSize = active
        ? baseFontSize * motion.activeFontMultiplier
        : message.kind == CappellaMessageKind.title
        ? baseFontSize
        : baseFontSize * motion.inactiveFontMultiplier;
    final double padX = active
        ? motion.activePaddingX
        : motion.inactivePaddingX;
    final double padY = active
        ? motion.activePaddingY
        : motion.inactivePaddingY;
    return CappellaBubbleStyle(
      fontSize: fontSize,
      padX: padX,
      padY: padY,
      minHeight: math.max(
        active ? motion.activeMinHeight : motion.inactiveMinHeight,
        fontSize * kCappellaLineHeight + padY * 2,
      ),
      minWidth: active ? kCappellaActiveMinWidth : 0,
    );
  }

  final double fontSize;
  final double padX;
  final double padY;
  final double minHeight;
  final double minWidth;

  double get lineHeightPx => fontSize * kCappellaLineHeight;

  /// 应用 min-height / min-width 之后的可见尺寸。
  Size clamp(Size measured) => Size(
    math.max(measured.width, minWidth),
    math.max(measured.height, minHeight),
  );

  @override
  bool operator ==(Object other) =>
      other is CappellaBubbleStyle &&
      other.fontSize == fontSize &&
      other.padX == padX &&
      other.padY == padY;

  @override
  int get hashCode => Object.hash(fontSize, padX, padY);
}

/// 气泡文字的 TextStyle（字重 400、行高 1.45，行距上下均分同 CSS）。
TextStyle cappellaBubbleTextStyle(double fontSize, Color color) => TextStyle(
  fontSize: fontSize,
  fontWeight: FontWeight.w400,
  height: kCappellaLineHeight,
  leadingDistribution: TextLeadingDistribution.even,
  color: color,
);

/// 排一段气泡文字（最长行定宽，最大宽 [maxTextWidth]）。调用方负责 dispose。
TextPainter cappellaLayoutText(
  String text,
  double fontSize,
  double maxTextWidth,
  Color color,
) => TextPainter(
  text: TextSpan(text: text, style: cappellaBubbleTextStyle(fontSize, color)),
  textDirection: TextDirection.ltr,
  textWidthBasis: TextWidthBasis.longestLine,
)..layout(maxWidth: math.max(1, maxTextWidth));

/// folia `measureBubbleText`：文字宽（至少一个字号宽，最多 [maxTextWidth]）+ 内边距 + 描边。
Size cappellaMeasureBubble(
  String text,
  CappellaBubbleStyle style,
  double maxTextWidth,
) {
  final TextPainter tp = cappellaLayoutText(
    text.isEmpty ? ' ' : text,
    style.fontSize,
    maxTextWidth,
    const Color(0xFF000000),
  );
  final int lines = math.max(1, tp.computeLineMetrics().length);
  final double textWidth = math.max(tp.width, style.fontSize);
  tp.dispose();
  return Size(
    (math.min(textWidth, maxTextWidth) +
            style.padX * 2 +
            kCappellaBubbleBorder * 2)
        .ceilToDouble(),
    (lines * style.lineHeightPx + style.padY * 2 + kCappellaBubbleBorder * 2)
        .ceilToDouble(),
  );
}

/// 一行在当前行排版下的逐字前缀尺寸表（folia `PreparedBubbleMetrics`）。
class CappellaBubbleMetrics {
  CappellaBubbleMetrics({required this.plan, required this.sizes});

  final CappellaRevealPlan plan;

  /// `sizes[n]` = 显示前 n 个字时气泡应有的尺寸。
  final List<Size> sizes;

  Size get full => sizes.last;

  /// 此刻气泡目标尺寸（用提前时间轴）。
  Size targetAt(int timeMs) {
    final int n = cappellaCharCountAt(plan.bubbleTargetMs, timeMs);
    return sizes[n.clamp(0, sizes.length - 1)];
  }
}

/// 有界的测量缓存（LRU）。
class CappellaMeasureCache {
  final LinkedHashMap<Object, CappellaBubbleMetrics> _metrics =
      LinkedHashMap<Object, CappellaBubbleMetrics>();
  final LinkedHashMap<Object, Size> _sizes = LinkedHashMap<Object, Size>();

  /// 前缀尺寸表：每个前缀量一次（预热下一句时提前做）。
  CappellaBubbleMetrics metricsFor(
    CappellaLine line,
    CappellaBubbleStyle style,
    double maxTextWidth,
  ) {
    final Object key = (line.index, line.startMs, style, maxTextWidth);
    final CappellaBubbleMetrics? hit = _metrics.remove(key);
    if (hit != null) {
      _metrics[key] = hit;
      return hit;
    }
    final CappellaRevealPlan plan = cappellaRevealPlan(line);
    final List<Size> sizes = <Size>[];
    final StringBuffer prefix = StringBuffer();
    sizes.add(cappellaMeasureBubble('', style, maxTextWidth));
    for (final String c in plan.characters) {
      prefix.write(c);
      sizes.add(cappellaMeasureBubble(prefix.toString(), style, maxTextWidth));
    }
    final CappellaBubbleMetrics m = CappellaBubbleMetrics(
      plan: plan,
      sizes: sizes,
    );
    _metrics[key] = m;
    while (_metrics.length > kCappellaLayoutCacheLimit) {
      _metrics.remove(_metrics.keys.first);
    }
    return m;
  }

  /// 整句气泡尺寸（未套 min-height）。
  Size sizeFor(String text, CappellaBubbleStyle style, double maxTextWidth) {
    final Object key = (text, style, maxTextWidth);
    final Size? hit = _sizes[key];
    if (hit != null) return hit;
    final Size s = cappellaMeasureBubble(text, style, maxTextWidth);
    _sizes[key] = s;
    while (_sizes.length > 256) {
      _sizes.remove(_sizes.keys.first);
    }
    return s;
  }

  void clear() {
    _metrics.clear();
    _sizes.clear();
  }
}

/// folia `getEstimatedMessageHeight`：一条消息在排版上占的高度（含缩放上溢与行间距）。
double cappellaEstimatedHeight({
  required CappellaMessage message,
  required bool active,
  required CappellaMotion motion,
  required CappellaViewport viewport,
  required CappellaMeasureCache cache,
}) {
  if (message.kind == CappellaMessageKind.emo) {
    final double s = active ? motion.emoActiveSize : motion.emoInactiveSize;
    final double over = active && motion.activeScale > 1
        ? (s * (motion.activeScale - 1)).ceilToDouble()
        : 0;
    return s + over + kCappellaEmoTopPadding + kCappellaGap;
  }
  final CappellaBubbleStyle style = CappellaBubbleStyle.of(
    message: message,
    active: active,
    baseFontSize: viewport.baseFontSize,
    motion: motion,
  );
  final double h = style
      .clamp(cache.sizeFor(message.displayText, style, viewport.maxTextWidth))
      .height;
  final double over = active && motion.activeScale > 1
      ? (h * (motion.activeScale - 1)).ceilToDouble()
      : 0;
  return h + over + kCappellaGap;
}

/// 气泡配色。
@immutable
class CappellaBubbleColors {
  const CappellaBubbleColors({
    required this.background,
    required this.border,
    required this.text,
  });

  final Color background;
  final Color border;
  final Color text;
}

Color _mix(Color a, Color b, double t, double alpha) =>
    Color.lerp(a, b, t.clamp(0.0, 1.0))!.withValues(alpha: alpha);

double _contrast(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// folia `getBubbleColors`。folia 主题色对应：primaryColor（前景字色）→ [LyricVisualizerPalette.text]，
/// accentColor → [LyricVisualizerPalette.primary]，secondaryColor → [LyricVisualizerPalette.secondary]。
/// 右侧（「我」）气泡偏主色、字用背景色；左侧按头像下标在 secondary→accent 之间取色。
/// 字色对比度不足 3:1 时换成另一端（folia 依赖 AI 主题保证对比度，封面取色不保证）。
CappellaBubbleColors cappellaBubbleColors(
  CappellaSender sender,
  LyricVisualizerPalette p,
) {
  final Color accent = p.primary;
  final Color fg = p.text;
  if (sender.right) {
    final Color bg = _mix(accent, fg, 0.18, 0.94);
    final Color opaque = bg.withValues(alpha: 1);
    Color text = p.background;
    if (_contrast(text, opaque) < 3) text = fg;
    return CappellaBubbleColors(
      background: bg,
      border: _mix(accent, fg, 0.34, 0.3),
      text: text,
    );
  }
  const int cells = kCappellaAvatarGridSize * kCappellaAvatarGridSize;
  final double tone = (sender.avatarIndex % cells) / (cells - 1);
  final double accentMix = 0.18 + tone * 0.62;
  final Color bg = _mix(p.secondary, accent, accentMix, 1);
  Color text = fg;
  if (_contrast(text, bg) < 3) text = p.background;
  return CappellaBubbleColors(
    background: bg,
    border: _mix(p.secondary, accent, math.min(accentMix + 0.18, 1), 0.26),
    text: text,
  );
}
