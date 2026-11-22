/// 全屏歌词动画样式「回环」（移植自 folia-major `src/components/visualizer/claddagh/`）。
///
/// 歌词沿一条倾斜的扁椭圆轨道排开：正在唱的字转到正前方、放大发光，背面的字缩小、
/// 模糊、收拢；每换一行整环用弹簧转半圈，下一行从背面转上来。中间一条与长轴垂直的
/// 短轴线随（歌词起字）能量变色伸缩。可选把译文沿同一圈排在歌词下方。
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
  sharedBackdrop: true,
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
    final TextStyle base = DefaultTextStyle.of(
      context,
    ).style.copyWith(decoration: TextDecoration.none, shadows: null);
    final CladdaghScene scene = _scene ??= CladdaghScene(widget.context, base);
    scene.update(widget.context, base);
    _cache.baseStyle = base;
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

  set baseStyle(TextStyle v) {
    if (v == _baseStyle) return;
    _baseStyle = v;
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
    final String key =
        '${d.text}|${d.fontPx.toStringAsFixed(1)}|${d.translation ? 6 : 7}|'
        '${color.toARGB32()}|$glow|${glowColor.toARGB32()}|$blur';
    final TextPainter? hit = _map.remove(key);
    if (hit != null) {
      _map[key] = hit;
      return hit;
    }
    final TextStyle style = claddaghGlyphStyle(
      _baseStyle,
      d.fontPx,
      d.translation ? FontWeight.w600 : FontWeight.w700,
    );
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
          shadows: glow > 0 && glowColor.a > 0
              ? <Shadow>[Shadow(color: glowColor, blurRadius: glow)]
              : null,
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
