/// 莫奈的浮动装饰（移植 folia `MonetFloatingDecor.tsx`）：主题图标（`LyricVisualizerTheme.lyricsIcons`）
/// 以极低透明度在画面里缓慢漂浮、旋转。主题没有图标时什么都不画。
///
/// folia 画 Lucide 线稿（`strokeWidth={1} absoluteStrokeWidth`：不论图标多大都是 1px 线）；这里
/// 取主题图标映射到的语义图标字形，只描它的轮廓（1px 描边、不填充），得到同样的细线稿观感。
/// 不搬 Lucide 的图形本身（许可约定），所以线条走向与原版图标不同。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

/// 一个漂浮粒子（folia `FloatingParticle`，各值由下标确定、不随机）。
@immutable
class MonetDecorParticle {
  const MonetDecorParticle({
    required this.id,
    required this.x,
    required this.y,
    required this.size,
    required this.rotation,
    required this.duration,
    required this.delay,
    required this.opacity,
    required this.icon,
    required this.reverse,
  });

  final int id;

  /// 左上角位置（画面宽 / 高的百分比）。
  final double x;
  final double y;

  /// 图标边长（逻辑像素）。
  final double size;

  /// 初始旋转（度）。
  final double rotation;

  /// 一轮漂浮的秒数与起步延迟。
  final double duration;
  final double delay;
  final double opacity;
  final IconData icon;

  /// 反向漂（偶数下标）。
  final bool reverse;
}

/// folia `PARTICLE_COUNT`。
const int kMonetDecorParticleCount = 10;

/// folia `buildParticles`：10 个槽位，部分留空；图标按下标轮流取。
List<MonetDecorParticle> buildMonetDecorParticles(List<IconData> icons) {
  if (icons.isEmpty) return const <MonetDecorParticle>[];
  return <MonetDecorParticle>[
    for (int i = 0; i < kMonetDecorParticleCount; i++)
      if ((i * 37 + 11) % 100 > 20)
        MonetDecorParticle(
          id: i,
          x: ((i * 127 + 43) % 80) + 10,
          y: ((i * 211 + 17) % 80) + 5,
          size: 46 + ((i * 53) % 40).toDouble(),
          rotation: ((i * 97) % 360).toDouble(),
          duration: 20 + ((i * 71) % 20).toDouble(),
          delay: ((i * 41) % 80) / 10,
          opacity: 0.06 + ((i * 31) % 12) / 100,
          icon: icons[i % icons.length],
          reverse: i.isEven,
        ),
  ];
}

/// 粒子在 [t] 秒（从入场算起）时的偏移 / 旋转 / 透明度：五个关键帧等分一轮，段内 easeInOut
/// （framer `animate` 关键帧数组 + `ease: 'easeInOut'`），延迟前停在第一帧。
({double dx, double dy, double rotation, double opacity}) monetDecorPose(
  MonetDecorParticle p,
  double t,
) {
  final double s = p.reverse ? -1 : 1;
  final List<double> ys = <double>[40, -60, 20, -40, 40];
  final List<double> xs = <double>[-15, 25, -10, 20, -15];
  final List<double> rs = <double>[0, 120, 60, 180, 0];
  final List<double> os = <double>[0.6, 1.2, 1, 1.3, 0.7];
  final double local = t - p.delay;
  double phase = 0;
  if (local > 0) {
    phase = (local % p.duration) / p.duration;
  }
  final double f = phase * 4;
  final int k = math.min(f.floor(), 3);
  final double e = Curves.easeInOut.transform((f - k).clamp(0.0, 1.0));
  double lerp(List<double> v) => v[k] + (v[k + 1] - v[k]) * e;
  return (
    dx: s * lerp(xs),
    dy: s * lerp(ys),
    rotation: p.rotation + s * lerp(rs),
    opacity: p.opacity * lerp(os),
  );
}

/// 画浮动装饰。[seconds] 是入场后的秒数；[still] 时按静止姿态画（folia staticMode）。
class MonetFloatingDecorPainter extends CustomPainter {
  MonetFloatingDecorPainter({
    required this.particles,
    required this.color,
    required this.seconds,
    required this.still,
    required this.fade,
  });

  final List<MonetDecorParticle> particles;
  final Color color;
  final double seconds;
  final bool still;

  /// 整层的入场淡入（folia 外层 2.2 秒 easeOut）。
  final double fade;

  @override
  void paint(Canvas canvas, Size size) {
    if (particles.isEmpty || fade <= 0) return;
    for (final MonetDecorParticle p in particles) {
      final ({double dx, double dy, double rotation, double opacity}) pose =
          still
          ? (dx: 0, dy: 0, rotation: p.rotation, opacity: p.opacity)
          : monetDecorPose(p, seconds);
      final double alpha = (pose.opacity * fade).clamp(0.0, 1.0);
      if (alpha <= 0) continue;
      final Offset center = Offset(
        size.width * p.x / 100 + p.size / 2 + pose.dx,
        size.height * p.y / 100 + p.size / 2 + pose.dy,
      );
      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(pose.rotation * math.pi / 180);
      paintMonetOutlineGlyph(
        canvas,
        p.icon,
        p.size,
        color.withValues(alpha: color.a * alpha),
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(MonetFloatingDecorPainter old) =>
      old.seconds != seconds ||
      old.fade != fade ||
      old.color != color ||
      old.still != still ||
      !identical(old.particles, particles);
}

final Map<(int, String?, int), ui.Paragraph> _outlineCache =
    <(int, String?, int), ui.Paragraph>{};

/// 以原点为中心画 [icon] 字形的 1px 轮廓线（边长 [size]，颜色 [color]）。排版按（码位、字族、
/// 字号）缓存成白色描边，上色走图层的 `srcIn` 滤镜，逐帧变透明度不重新排版。
void paintMonetOutlineGlyph(
  Canvas canvas,
  IconData icon,
  double size,
  Color color,
) {
  if (size <= 0 || color.a <= 0) return;
  final int px = size.round().clamp(1, 1024);
  final (int, String?, int) key = (icon.codePoint, icon.fontFamily, px);
  ui.Paragraph? p = _outlineCache[key];
  if (p == null) {
    if (_outlineCache.length > 64) {
      for (final ui.Paragraph old in _outlineCache.values) {
        old.dispose();
      }
      _outlineCache.clear();
    }
    final ui.ParagraphBuilder b =
        ui.ParagraphBuilder(
            ui.ParagraphStyle(
              fontFamily: icon.fontFamily,
              fontSize: px.toDouble(),
              height: 1,
            ),
          )
          ..pushStyle(
            ui.TextStyle(
              fontFamily: icon.fontFamily,
              fontSize: px.toDouble(),
              height: 1,
              foreground: Paint()
                ..style = PaintingStyle.stroke
                // `absoluteStrokeWidth`：屏幕上恒为 1px（字号缩放在下面抵消）。
                ..strokeWidth = 1
                ..strokeJoin = StrokeJoin.round
                ..color = const Color(0xFFFFFFFF),
            ),
          )
          ..addText(String.fromCharCode(icon.codePoint));
    p = b.build()..layout(const ui.ParagraphConstraints(width: 4096));
    _outlineCache[key] = p;
  }
  final double scale = size / px;
  final Rect bounds = Rect.fromCenter(
    center: Offset.zero,
    width: size + 4,
    height: size + 4,
  );
  canvas.saveLayer(
    bounds,
    Paint()..colorFilter = ColorFilter.mode(color, BlendMode.srcIn),
  );
  canvas.scale(scale);
  canvas.drawParagraph(p, Offset(-p.maxIntrinsicWidth / 2, -p.height / 2));
  canvas.restore();
}
