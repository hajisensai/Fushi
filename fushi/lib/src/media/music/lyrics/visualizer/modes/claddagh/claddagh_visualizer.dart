/// 全屏歌词动画样式「回环」（移植自 folia-major `src/components/visualizer/claddagh/`）。
///
/// 歌词沿一条倾斜的扁椭圆轨道排开：正在唱的字转到正前方、放大发光，背面的字缩小、
/// 模糊、收拢；每换一行整环用弹簧转半圈，下一行从背面转上来。中间一条与长轴垂直的
/// 短轴线随低频 / 人声能量（音频分析；没有时回落歌词起字包络）变色伸缩，副歌时加光晕。
/// 可选把译文沿同一圈排在歌词下方。
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_tuning.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。
final LyricVisualizerEntry claddaghVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.claddagh,
  label: () => t.music_visualizer_mode_claddagh,
  description: () => t.music_visualizer_claddagh_description,
  icon: FushiIcons.radioUnchecked,
  tunings: claddaghTuningSpecs,
  // folia 回环套在 VisualizerShell 里：用用户选的共享背景。
  background: (LyricVisualizerTuning _) =>
      LyricVisualizerBackgroundRequest.selected,
  builder: (LyricVisualizerContext c) => CladdaghVisualizer(context: c),
);

/// 回环样式本体。纯展示，不接手势（点按退出归宿主）。
class CladdaghVisualizer extends StatefulWidget {
  const CladdaghVisualizer({super.key, required this.context});

  final LyricVisualizerContext context;

  @override
  State<CladdaghVisualizer> createState() => _CladdaghVisualizerState();
}

class _CladdaghVisualizerState extends State<CladdaghVisualizer> {
  CladdaghScene? _scene;
  final CladdaghGlyphCache _cache = CladdaghGlyphCache();

  @override
  void dispose() {
    _cache.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle base = widget.context.applyThemeFont(
      DefaultTextStyle.of(
        context,
      ).style.copyWith(decoration: TextDecoration.none, shadows: null),
    );
    // folia `resolveThemeFontWeight(theme, 700)`（译文 600）：主题给了字重就用主题的。
    final FontWeight? themeWeight = widget.context.theme?.fontWeight;
    final FontWeight lyricWeight = themeWeight ?? FontWeight.w700;
    final FontWeight translationWeight = themeWeight ?? FontWeight.w600;
    final CladdaghScene scene = _scene ??= CladdaghScene(
      widget.context,
      base,
      lyricWeight: lyricWeight,
      translationWeight: translationWeight,
    );
    scene.update(
      widget.context,
      base,
      lyricWeight: lyricWeight,
      translationWeight: translationWeight,
    );
    _cache.setStyle(base, lyricWeight, translationWeight);
    return LyricVisualizerFrame(
      context: widget.context,
      builder: (BuildContext c, LyricVisualizerTicks ticks) => RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _CladdaghPainter(
            ticks: ticks,
            scene: scene,
            cache: _cache,
            input: widget.context,
          ),
        ),
      ),
    );
  }
}

/// 单字排版缓存：按（字、字号、粗细、量化后的颜色 / 发光 / 模糊）缓存 [TextPainter]，
/// 每帧只画不排。最近最少使用淘汰，淘汰时释放。
class CladdaghGlyphCache {
  static const int _limit = 900;

  final LinkedHashMap<String, TextPainter> _map =
      LinkedHashMap<String, TextPainter>();
  TextStyle _baseStyle = const TextStyle();
  FontWeight _lyricWeight = FontWeight.w700;
  FontWeight _translationWeight = FontWeight.w600;

  /// 换排版样式（主题字体 / 字重）；变了就清缓存。
  void setStyle(TextStyle base, FontWeight lyric, FontWeight translation) {
    if (base == _baseStyle &&
        lyric == _lyricWeight &&
        translation == _translationWeight) {
      return;
    }
    _baseStyle = base;
    _lyricWeight = lyric;
    _translationWeight = translation;
    clear();
  }

  int get length => _map.length;

  static double _q(double v, double step) => (v / step).roundToDouble() * step;

  static Color _qa(Color c) =>
      c.withValues(alpha: _q(c.a.clamp(0.0, 1.0), 1 / 64));

  TextPainter painterFor(CladdaghDraw d) {
    final Color color = _qa(d.color);
    final double glow = _q(d.glowRadius, 0.5);
    final Color glowColor = _qa(d.glowColor);
    final double blur = _q(d.blur, 0.25);
    final Color coreColor = _qa(d.coreColor);
    final String key =
        '${d.text}|${d.fontPx.toStringAsFixed(1)}|${d.translation ? 6 : 7}|'
        '${color.toARGB32()}|$glow|${glowColor.toARGB32()}|$blur|'
        '${d.chorus ? coreColor.toARGB32() : 0}';
    final TextPainter? hit = _map.remove(key);
    if (hit != null) {
      _map[key] = hit;
      return hit;
    }
    final TextStyle style = claddaghGlyphStyle(
      _baseStyle,
      d.fontPx,
      d.translation ? _translationWeight : _lyricWeight,
    );
    final bool hasGlow = glow > 0 && glowColor.a > 0;
    // 副歌三层（folia：内核 0.35r 混主色、r、1.6r）；平时一层 r。
    final List<Shadow>? shadows = !hasGlow
        ? null
        : d.chorus
        ? <Shadow>[
            Shadow(color: coreColor, blurRadius: glow * 0.35),
            Shadow(color: glowColor, blurRadius: glow),
            Shadow(color: glowColor, blurRadius: glow * 1.6),
          ]
        : <Shadow>[Shadow(color: glowColor, blurRadius: glow)];
    final TextPainter painter = TextPainter(
      text: TextSpan(
        text: d.text,
        style: style.copyWith(
          color: blur > 0 ? null : color,
          foreground: blur > 0
              ? (Paint()
                  ..color = color
                  ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur))
              : null,
          shadows: shadows,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    _map[key] = painter;
    while (_map.length > _limit) {
      final String oldest = _map.keys.first;
      _map.remove(oldest)?.dispose();
    }
    return painter;
  }

  void clear() {
    for (final TextPainter p in _map.values) {
      p.dispose();
    }
    _map.clear();
  }

  void dispose() => clear();
}

class _CladdaghPainter extends CustomPainter {
  _CladdaghPainter({
    required this.ticks,
    required this.scene,
    required this.cache,
    required this.input,
  }) : super(repaint: ticks);

  final LyricVisualizerTicks ticks;
  final CladdaghScene scene;
  final CladdaghGlyphCache cache;

  /// 参数 / 配色变了但时间没走时也要重画。
  final LyricVisualizerContext input;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final CladdaghFrame frame = scene.compute(ticks.value.timeMs, size);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final CladdaghAxis? axis = frame.axis;
    if (axis != null) _paintAxis(canvas, frame.center, axis);
    for (final CladdaghDraw d in frame.glyphs) {
      final TextPainter p = cache.painterFor(d);
      canvas.save();
      canvas.translate(
        frame.center.dx + d.offset.dx,
        frame.center.dy + d.offset.dy,
      );
      canvas.rotate(d.rotationDeg * math.pi / 180);
      canvas.scale(d.scale);
      p.paint(canvas, Offset(-p.width / 2, -p.height / 2));
      canvas.restore();
    }
    canvas.restore();
  }

  /// 两端淡出的短线段（folia：300×4，渐变 transparent → 20% → 80% → transparent）。
  void _paintAxis(Canvas canvas, Offset center, CladdaghAxis axis) {
    const double thickness = 4;
    final double half = axis.length / 2;
    final Rect rect = Rect.fromLTRB(-half, -thickness / 2, half, thickness / 2);
    final Color clear = axis.color.withValues(alpha: 0);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(axis.angleDeg * math.pi / 180);
    canvas.scale(axis.scaleX, axis.scaleY);
    if (axis.glowSize > 0 && axis.glowColor.a > 0) {
      // 副歌光晕：CSS drop-shadow 的模糊半径是两个标准差。
      final Color glowClear = axis.glowColor.withValues(alpha: 0);
      canvas.drawRect(
        rect,
        Paint()
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, axis.glowSize / 2)
          ..shader = ui.Gradient.linear(
            rect.centerLeft,
            rect.centerRight,
            <Color>[glowClear, axis.glowColor, axis.glowColor, glowClear],
            const <double>[0, 0.2, 0.8, 1],
          ),
      );
    }
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.centerLeft,
          rect.centerRight,
          <Color>[clear, axis.color, axis.color, clear],
          const <double>[0, 0.2, 0.8, 1],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CladdaghPainter old) =>
      old.ticks != ticks ||
      old.scene != scene ||
      old.cache != cache ||
      !identical(old.input, input);
}
