/// 全屏歌词动画样式「静止」（移植自 folia-major `src/components/visualizer/still/`）。
///
/// 三行静态歌词（上一句 / 当前句 / 下一句，各带译文）居中，外加一层径向暗角；不画共享背景、
/// 不做任何动画，只在当前句换行时重建一次，是最省资源的样式。
library;

import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/still/still_layout.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

export 'package:fushi/src/media/music/lyrics/visualizer/modes/still/still_layout.dart';

/// 注册项。folia 的 Still 没有 tuning；译文由样式自己排（folia 同样直接读 `line.translation`）。
final LyricVisualizerEntry stillVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.still,
  label: () => t.music_visualizer_mode_still,
  description: () => t.music_visualizer_still_description,
  icon: FushiIcons.textFields,
  // folia `background: false`：不要共享背景，宿主只铺配色底色。
  background: (LyricVisualizerTuning _) =>
      LyricVisualizerBackgroundRequest.none,
  sharedSubtitle: false,
  builder: (LyricVisualizerContext c) => StillVisualizer(context: c),
);

/// 静止样式本体。
class StillVisualizer extends StatelessWidget {
  const StillVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  Widget build(BuildContext buildContext) => Stack(
    fit: StackFit.expand,
    children: <Widget>[
      _StillVignette(palette: context.palette),
      LyricVisualizerFrame(
        context: context,
        builder: (BuildContext bc, LyricVisualizerTicks ticks) =>
            _StillLyrics(visualizer: context, ticks: ticks),
      ),
    ],
  );
}

/// 径向暗角（folia 外壳上那层 `bg-[radial-gradient(...)]`）。
class _StillVignette extends StatelessWidget {
  const _StillVignette({required this.palette});

  final LyricVisualizerPalette palette;

  @override
  Widget build(BuildContext context) {
    final bool daylight = palette.brightness == Brightness.light;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(painter: _StillVignettePainter(daylight: daylight)),
      ),
    );
  }
}

class _StillVignettePainter extends CustomPainter {
  const _StillVignettePainter({required this.daylight});

  final bool daylight;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Rect rect = Offset.zero & size;
    final double opacity = daylight
        ? StillMetrics.vignetteLightOpacity
        : StillMetrics.vignetteDarkOpacity;
    // CSS `ellipse at center` 默认 farthest-corner：椭圆过四角，半轴为半宽 / 半高的 √2 倍。
    final double rx = size.width / 2 * 1.41421356;
    final double ry = size.height / 2 * 1.41421356;
    final Color edge = const Color(0xFF000000).withValues(alpha: opacity);
    final Paint paint = Paint()
      ..blendMode = daylight ? BlendMode.multiply : BlendMode.srcOver
      ..shader = ui.Gradient.radial(
        Offset.zero,
        1,
        <Color>[const Color(0x00000000), edge],
        null,
        TileMode.clamp,
        (Matrix4.identity()
              ..translateByDouble(size.width / 2, size.height / 2, 0, 1)
              ..scaleByDouble(rx, ry, 1, 1))
            .storage,
      );
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_StillVignettePainter oldDelegate) =>
      oldDelegate.daylight != daylight;
}

/// 监听逐帧时钟，但只在当前句换了的那一帧 setState；其余帧只做一次二分查找。
class _StillLyrics extends StatefulWidget {
  const _StillLyrics({required this.visualizer, required this.ticks});

  final LyricVisualizerContext visualizer;
  final LyricVisualizerTicks ticks;

  @override
  State<_StillLyrics> createState() => _StillLyricsState();
}

class _StillLyricsState extends State<_StillLyrics> {
  late int _index;

  int _resolve() => resolveStillEffectiveIndex(
    widget.visualizer.runtime,
    widget.ticks.value.timeMs,
  );

  void _onTick() {
    final int next = _resolve();
    if (next != _index) setState(() => _index = next);
  }

  @override
  void initState() {
    super.initState();
    _index = _resolve();
    widget.ticks.addListener(_onTick);
  }

  @override
  void didUpdateWidget(covariant _StillLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.ticks, widget.ticks)) {
      oldWidget.ticks.removeListener(_onTick);
      widget.ticks.addListener(_onTick);
    }
    _index = _resolve();
  }

  @override
  void dispose() {
    widget.ticks.removeListener(_onTick);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LyricVisualizerContext c = widget.visualizer;
    final List<LyricVisualizerLine> lines = c.runtime.lines;
    if (lines.isEmpty) return const SizedBox.expand();
    final List<int?> slots = stillSlotIndices(_index, lines.length);
    return IgnorePointer(
      child: RepaintBoundary(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            StillMetrics.horizontalPadding,
            0,
            StillMetrics.horizontalPadding,
            StillMetrics.bottomPadding,
          ),
          child: LayoutBuilder(
            builder: (BuildContext bc, BoxConstraints box) {
              final double width = box.maxWidth.isFinite
                  ? box.maxWidth.clamp(0, StillMetrics.maxWidth).toDouble()
                  : StillMetrics.maxWidth;
              // 三句都很长时（窄屏 / 大字号）整体等比缩小，保证不溢出。
              return Center(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: SizedBox(
                    width: width,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (int s = 0; s < slots.length; s++) ...<Widget>[
                          if (s > 0)
                            const SizedBox(height: StillMetrics.slotGap),
                          _StillSlot(
                            key: ValueKey<int?>(slots[s] ?? -100 - s),
                            line: slots[s] == null ? null : lines[slots[s]!],
                            style: StillSlotStyle.of(isCurrent: s == 1),
                            palette: c.palette,
                            fontScale: c.fontScale,
                            visualizer: c,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 一个槽位：原文 + 译文；空槽是固定高度的空白（folia `h-20`）。
class _StillSlot extends StatelessWidget {
  const _StillSlot({
    super.key,
    required this.line,
    required this.style,
    required this.palette,
    required this.fontScale,
    required this.visualizer,
  });

  final LyricVisualizerLine? line;
  final StillSlotStyle style;
  final LyricVisualizerPalette palette;
  final double fontScale;
  final LyricVisualizerContext visualizer;

  @override
  Widget build(BuildContext context) {
    final LyricVisualizerLine? l = line;
    if (l == null) {
      return const SizedBox(height: StillMetrics.emptySlotHeight);
    }
    final double lyricSize = style.fontSize * fontScale;
    // 副字幕：按全局字幕偏好取行（隐藏 / 不要时没有；字号再乘字幕字号倍数，folia
    // `lyricsFontScale * subtitleFontScale`）。folia 静止只读译文，这里按偏好也能显示罗马音 / 两行。
    final LyricVisualizerSubtitleSettings sub = visualizer.subtitle;
    final double transSize =
        style.translationFontSize * fontScale * sub.effectiveFontScale;
    final List<LyricVisualizerSubtitleRow> rows = sub.rowsFor(
      lineText: l.text,
      translation: l.translation,
      romanization: l.romanization,
    );
    // folia：原文 theme.primaryColor（drop-shadow-md），译文 secondaryColor（drop-shadow-sm）。
    final Color lyricColor = palette.text.withValues(
      alpha: palette.text.a * style.opacity,
    );
    final Color transBase = stillTranslationColor(palette, visualizer.theme);
    final Color transColor = transBase.withValues(
      alpha: transBase.a * style.translationOpacity,
    );
    final Color shadow = const Color(
      0xFF000000,
    ).withValues(alpha: 0.18 * style.opacity);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          l.text,
          textAlign: TextAlign.center,
          // 字重 / 字体照 folia `resolveThemeFontWeight(theme, 700 / 600)` 与主题字体栈。
          style: visualizer.applyThemeFont(
            TextStyle(
              color: lyricColor,
              fontSize: lyricSize,
              height: style.lineHeight,
              letterSpacing: lyricSize * StillMetrics.lyricTrackingEm,
              fontWeight: style.weight,
              shadows: <Shadow>[
                Shadow(
                  color: shadow,
                  offset: const Offset(0, 4),
                  blurRadius: 3,
                ),
              ],
            ),
          ),
        ),
        for (int r = 0; r < rows.length; r++) ...<Widget>[
          SizedBox(
            height: r == 0
                ? style.translationGap * fontScale
                : transSize *
                      kLyricVisualizerSecondarySubtitleSize *
                      kLyricVisualizerSecondarySubtitleGapEm,
          ),
          Text(
            rows[r].text,
            key: ValueKey<String>('still_subtitle_${rows[r].kind.name}'),
            textAlign: TextAlign.center,
            // 双行时第二行退一级（字号 0.88、透明度 0.82，folia subtitleTrackStyle）。
            style: sub.applyFont(
              TextStyle(
                color: r == 0
                    ? transColor
                    : transColor.withValues(
                        alpha:
                            transColor.a *
                            kLyricVisualizerSecondarySubtitleOpacity,
                      ),
                fontSize: r == 0
                    ? transSize
                    : transSize * kLyricVisualizerSecondarySubtitleSize,
                height: 1.33,
                letterSpacing: transSize * StillMetrics.translationTrackingEm,
                fontWeight: style.translationWeight,
                shadows: <Shadow>[
                  Shadow(
                    color: shadow,
                    offset: const Offset(0, 1),
                    blurRadius: 1,
                  ),
                ],
              ),
              visualizer.theme,
            ),
          ),
        ],
      ],
    );
  }
}
