/// 静止（folia `still/VisualizerStill.tsx`）的纯排版规则：取哪三行、各行字号 / 不透明度。
library;

import 'dart:ui' show Color, FontWeight;

import 'package:flutter/foundation.dart' show immutable;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// folia 的 `effectiveIndex`：当前句（folia `currentLineIndex`：起点已到、还没过句尾离场，
/// [LyricVisualizerRuntime.displayedLineAt]）取它；间奏里停在上一句；一句都没到时取第 0 句。
/// folia 用 state 记住上一句，这里按时间直接算，拖进度到间奏也落在正确的上一句。
int resolveStillEffectiveIndex(LyricVisualizerRuntime runtime, int timeMs) {
  if (runtime.lines.isEmpty) return -1;
  final int active = runtime.displayedLineAt(timeMs);
  if (active >= 0) return active;
  final int last = runtime.lastStartedLineAt(timeMs);
  return last >= 0 ? last : 0;
}

/// 译文色（folia `subtitleTheme.secondaryColor`）：主题给了次色就直接用；只有封面取色时，
/// 封面配色的 secondary 是 M3 色调（暗底上常常太暗），往正文色靠 35% 保证可读。
Color stillTranslationColor(
  LyricVisualizerPalette palette,
  LyricVisualizerTheme? theme,
) => theme?.palette?.secondary != null
    ? palette.secondary
    : Color.lerp(palette.text, palette.secondary, 0.35)!;

/// 上一句 / 当前句 / 下一句三个槽位（folia `[-1, 0, 1]`），越界为 null（画一个空位）。
List<int?> stillSlotIndices(int effectiveIndex, int lineCount) {
  if (effectiveIndex < 0 || lineCount <= 0) {
    return const <int?>[null, null, null];
  }
  return <int?>[
    for (final int offset in const <int>[-1, 0, 1])
      if (effectiveIndex + offset >= 0 && effectiveIndex + offset < lineCount)
        effectiveIndex + offset
      else
        null,
  ];
}

/// 一个槽位的样式参数（folia 的 Tailwind 类换成逻辑像素）。
@immutable
class StillSlotStyle {
  const StillSlotStyle({
    required this.fontSize,
    required this.lineHeight,
    required this.opacity,
    required this.weight,
    required this.translationFontSize,
    required this.translationOpacity,
    required this.translationWeight,
    required this.translationGap,
  });

  /// 当前句：`text-[2.5rem] leading-tight` 700；译文 `text-2xl opacity-80 mt-3` 500。
  static const StillSlotStyle current = StillSlotStyle(
    fontSize: 40,
    lineHeight: 1.25,
    opacity: 1,
    weight: FontWeight.w700,
    translationFontSize: 24,
    translationOpacity: 0.8,
    translationWeight: FontWeight.w500,
    translationGap: 12,
  );

  /// 上下两句：`text-3xl opacity-30` 600；译文 `text-xl opacity-30 mt-2` 400。
  static const StillSlotStyle side = StillSlotStyle(
    fontSize: 30,
    lineHeight: 1.2,
    opacity: 0.3,
    weight: FontWeight.w600,
    translationFontSize: 20,
    translationOpacity: 0.3,
    translationWeight: FontWeight.w400,
    translationGap: 8,
  );

  final double fontSize;
  final double lineHeight;
  final double opacity;
  final FontWeight weight;
  final double translationFontSize;
  final double translationOpacity;
  final FontWeight translationWeight;
  final double translationGap;

  static StillSlotStyle of({required bool isCurrent}) =>
      isCurrent ? current : side;
}

/// folia 的版心常量（`px-12 pb-16 gap-8 max-w-4xl`，空槽 `h-20`）。
abstract final class StillMetrics {
  static const double horizontalPadding = 48;
  static const double bottomPadding = 64;
  static const double slotGap = 32;
  static const double maxWidth = 896;
  static const double emptySlotHeight = 80;

  /// 歌词字距 `tracking-[0.02em]`、译文 `tracking-wide`（0.025em）。
  static const double lyricTrackingEm = 0.02;
  static const double translationTrackingEm = 0.025;

  /// 暗角：`radial-gradient(ellipse at center, transparent 0%, #000 100%)`，
  /// 暗色 0.65、亮色 0.3 + multiply。
  static const double vignetteDarkOpacity = 0.65;
  static const double vignetteLightOpacity = 0.3;
}
