/// 凝彩的静态图形节点（folia `temperaShapes.ts` 的 Pixi Graphics 工厂 + `temperaBlocks.ts` 的
/// 运动状态 + `temperaCompositionContext.ts` 的绘图契约）。
///
/// 节点在建分镜时一次性生成 Path / Paint，播放时只写变换与透明度，不再动几何。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_geometry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_motion.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_palette.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_program.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_random.dart';

/// gradient 模式：一个分镜的四色 ramp 与它的方向。
class TemperaGradientFill {
  const TemperaGradientFill(this.colors, this.angle);

  final List<Color> colors;
  final double angle;
}

/// 一条绘制指令（填充或描边）。
class TemperaOp {
  TemperaOp({
    required this.path,
    required this.color,
    required this.alpha,
    this.strokeWidth,
    TemperaGradientFill? gradient,
  }) {
    paint
      ..isAntiAlias = true
      ..style = strokeWidth == null ? PaintingStyle.fill : PaintingStyle.stroke
      ..strokeWidth = strokeWidth ?? 0
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter;
    if (gradient != null && gradient.colors.length > 1 && strokeWidth == null) {
      // 每个 stop 向本形状要的那一档 tone 拉一半：封面色相在，明暗结构也在。
      final Rect b = path.getBounds();
      final double dx = math.cos(gradient.angle) * 0.5;
      final double dy = math.sin(gradient.angle) * 0.5;
      final int n = gradient.colors.length;
      shader = ui.Gradient.linear(
        Offset(b.left + (0.5 - dx) * b.width, b.top + (0.5 - dy) * b.height),
        Offset(b.left + (0.5 + dx) * b.width, b.top + (0.5 + dy) * b.height),
        <Color>[
          for (final Color c in gradient.colors) temperaMix(c, color, 0.5),
        ],
        <double>[for (int i = 0; i < n; i++) i / (n - 1)],
      );
      paint.shader = shader;
    }
  }

  final Path path;

  /// 形状要的那一档颜色（反色判定也读它）。
  final Color color;
  final double alpha;

  /// null = 填充。
  final double? strokeWidth;
  ui.Shader? shader;
  final Paint paint = Paint();

  /// 以 [opacity] 画出来。
  void draw(Canvas canvas, double opacity) {
    final double a = (alpha * opacity).clamp(0.0, 1.0);
    if (a <= 0.002) return;
    paint.color = shader != null
        ? Color.fromRGBO(0, 0, 0, a)
        : color.withValues(alpha: color.a * a);
    canvas.drawPath(path, paint);
  }
}

/// 一个图形节点：若干指令 + 枢轴（缩放 / 旋转绕它进行）。
class TemperaNode {
  TemperaNode(this.ops, {this.pivotX = 0, this.pivotY = 0})
    : x = pivotX,
      y = pivotY;

  final List<TemperaOp> ops;
  final double pivotX;
  final double pivotY;

  /// 静态位置（枢轴节点 = 枢轴本身）。
  double x;
  double y;
}

/// 带旋转的定位组（海报构图、蝴蝶结、散落的小心）。
class TemperaGroup {
  const TemperaGroup(this.rotation, this.x, this.y);

  final double rotation;
  final double x;
  final double y;
}

/// 色块的入场参数（时长是分镜时长的比例）。
class TemperaBlockOptions {
  const TemperaBlockOptions({
    this.alpha = 1,
    this.enterDX = 0,
    this.enterDY = 0,
    this.delay = 0,
    this.span = 0.45,
    this.drift = false,
    this.grow = false,
  });

  final double alpha;
  final double enterDX;
  final double enterDY;
  final double delay;
  final double span;

  /// 落位后缓慢的确定性浮动。
  final bool drift;

  /// 从枢轴横向展开（网点密度揭开）。
  final bool grow;
}

/// 动画器里的一项。
class TemperaBlockItem {
  TemperaBlockItem(this.node, this.options, this.group, this.driftPhase)
    : baseX = node.x,
      baseY = node.y;

  final TemperaNode node;
  final TemperaBlockOptions options;
  final TemperaGroup? group;
  final double driftPhase;
  final double baseX;
  final double baseY;

  // 逐帧状态
  double alpha = 0;
  bool visible = false;
  double x = 0;
  double y = 0;
  double scaleX = 1;
  double scaleY = 1;
  double rotation = 0;

  /// 秒；只依赖分镜歌词长度，长度不变就复用。
  double delay = 0;
  double span = 1;

  /// 按当前姿态画；[paintOp] 给反色遮罩换色用。
  void draw(
    Canvas canvas,
    double opacity, {
    void Function(TemperaOp op, double alpha)? paintOp,
  }) {
    if (!visible) return;
    canvas.save();
    final TemperaGroup? g = group;
    if (g != null) {
      canvas.translate(g.x, g.y);
      if (g.rotation != 0) canvas.rotate(g.rotation);
    }
    canvas.translate(x, y);
    if (rotation != 0) canvas.rotate(rotation);
    if (scaleX != 1 || scaleY != 1) canvas.scale(scaleX, scaleY);
    canvas.translate(-node.pivotX, -node.pivotY);
    final double a = alpha * opacity;
    for (final TemperaOp op in node.ops) {
      if (paintOp != null) {
        paintOp(op, a);
      } else {
        op.draw(canvas, a);
      }
    }
    canvas.restore();
  }
}

// ---------------------------------------------------------------------------
// 工厂（folia temperaShapes.ts）
// ---------------------------------------------------------------------------

Path _polyPath(List<double> polygon) {
  final Path p = Path();
  if (polygon.length < 4) return p;
  p.moveTo(polygon[0], polygon[1]);
  for (int i = 2; i < polygon.length; i += 2) {
    p.lineTo(polygon[i], polygon[i + 1]);
  }
  p.close();
  return p;
}

Rect _polyBounds(List<double> polygon) {
  double minX = double.infinity;
  double maxX = double.negativeInfinity;
  double minY = double.infinity;
  double maxY = double.negativeInfinity;
  for (int i = 0; i + 1 < polygon.length; i += 2) {
    minX = math.min(minX, polygon[i]);
    maxX = math.max(maxX, polygon[i]);
    minY = math.min(minY, polygon[i + 1]);
    maxY = math.max(maxY, polygon[i + 1]);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

TemperaNode drawPolygonFill(
  List<double> polygon,
  Color color, [
  double alpha = 1,
  TemperaGradientFill? gradient,
]) => TemperaNode(<TemperaOp>[
  TemperaOp(
    path: _polyPath(polygon),
    color: color,
    alpha: alpha,
    gradient: gradient,
  ),
]);

/// 挖了洞的填充：洞真的透明，露出宿主的共享背景。
TemperaNode drawPolygonFillWithHoles(
  List<double> polygon,
  List<List<double>> holes,
  Color color, [
  double alpha = 1,
  TemperaGradientFill? gradient,
]) {
  Path path = _polyPath(polygon);
  for (final List<double> hole in holes) {
    if (hole.length >= 6) {
      path = Path.combine(PathOperation.difference, path, _polyPath(hole));
    }
  }
  return TemperaNode(<TemperaOp>[
    TemperaOp(path: path, color: color, alpha: alpha, gradient: gradient),
  ]);
}

TemperaNode drawPolygonOutline(
  List<double> polygon,
  Color color,
  double width, [
  double alpha = 1,
]) => TemperaNode(<TemperaOp>[
  TemperaOp(
    path: _polyPath(polygon),
    color: color,
    alpha: alpha,
    strokeWidth: width,
  ),
]);

Path _linesPath(Iterable<TemperaLine> lines) {
  final Path p = Path();
  for (final TemperaLine l in lines) {
    p
      ..moveTo(l.x1, l.y1)
      ..lineTo(l.x2, l.y2);
  }
  return p;
}

/// 凸多边形里的平行斜线；枢轴在形状中心，便于横向展开。
TemperaNode drawHatchFill(
  List<double> polygon,
  TemperaHatchSpec spec,
  Color color, [
  double alpha = 1,
]) {
  final List<TemperaLine> lines = temperaHatchLines(polygon, spec);
  final Offset c = _polyBounds(polygon).center;
  return TemperaNode(
    <TemperaOp>[
      if (lines.isNotEmpty)
        TemperaOp(
          path: _linesPath(lines),
          color: color,
          alpha: alpha,
          strokeWidth: spec.width,
        ),
    ],
    pivotX: c.dx,
    pivotY: c.dy,
  );
}

Offset _discsCenter(List<TemperaDisc> discs) {
  if (discs.isEmpty) return Offset.zero;
  double minX = double.infinity;
  double maxX = double.negativeInfinity;
  double minY = double.infinity;
  double maxY = double.negativeInfinity;
  for (final TemperaDisc d in discs) {
    minX = math.min(minX, d.x - d.radius);
    maxX = math.max(maxX, d.x + d.radius);
    minY = math.min(minY, d.y - d.radius);
    maxY = math.max(maxY, d.y + d.radius);
  }
  return Offset((minX + maxX) / 2, (minY + maxY) / 2);
}

Path _discPath(List<TemperaDisc> discs) {
  final Path p = Path();
  for (final TemperaDisc d in discs) {
    p.addOval(
      Rect.fromCircle(
        center: Offset(d.x, d.y),
        radius: math.max(0.5, d.radius),
      ),
    );
  }
  return p;
}

/// 一整片圆是一个节点：一起入场、一起呼吸。
TemperaNode drawDiscs(
  List<TemperaDisc> discs,
  Color color, [
  double alpha = 1,
  TemperaGradientFill? gradient,
]) {
  final Offset c = _discsCenter(discs);
  return TemperaNode(
    <TemperaOp>[
      if (discs.isNotEmpty)
        TemperaOp(
          path: _discPath(discs),
          color: color,
          alpha: alpha,
          gradient: gradient,
        ),
    ],
    pivotX: c.dx,
    pivotY: c.dy,
  );
}

TemperaNode drawRings(
  List<TemperaDisc> discs,
  Color color,
  double width, [
  double alpha = 1,
]) {
  final Offset c = _discsCenter(discs);
  return TemperaNode(
    <TemperaOp>[
      if (discs.isNotEmpty)
        TemperaOp(
          path: _discPath(discs),
          color: color,
          alpha: alpha,
          strokeWidth: width,
        ),
    ],
    pivotX: c.dx,
    pivotY: c.dy,
  );
}

TemperaNode drawLines(
  List<TemperaLine> lines,
  Color color,
  double width, [
  double alpha = 1,
]) => TemperaNode(<TemperaOp>[
  if (lines.isNotEmpty)
    TemperaOp(
      path: _linesPath(lines),
      color: color,
      alpha: alpha,
      strokeWidth: width,
    ),
]);

TemperaNode drawPolyline(
  List<double> points,
  Color color,
  double width, [
  double alpha = 1,
]) {
  if (points.length < 4) return TemperaNode(<TemperaOp>[]);
  final Path p = Path()..moveTo(points[0], points[1]);
  for (int i = 2; i < points.length; i += 2) {
    p.lineTo(points[i], points[i + 1]);
  }
  return TemperaNode(<TemperaOp>[
    TemperaOp(path: p, color: color, alpha: alpha, strokeWidth: width),
  ]);
}

/// 同心菱形，粗细交替、外圈最粗。
TemperaNode drawConcentricDiamonds(
  double cx,
  double cy,
  double rx,
  double ry,
  int rings,
  Color color, [
  double alpha = 1,
]) => TemperaNode(
  <TemperaOp>[
    for (int ring = 0; ring < math.max(1, rings); ring++)
      TemperaOp(
        path: _polyPath(
          diamondPolygon(
            cx,
            cy,
            rx * (1 - ring * 0.22),
            ry * (1 - ring * 0.22),
          ),
        ),
        color: color,
        alpha: alpha,
        strokeWidth: ring.isEven ? 3.5 : 1.4,
      ),
  ],
  pivotX: cx,
  pivotY: cy,
);

TemperaNode drawCrossMarks(
  List<TemperaMark> marks,
  Color color,
  double width, [
  double alpha = 1,
]) {
  final Path p = Path();
  for (final TemperaMark m in marks) {
    final double c = math.cos(m.rotation + math.pi / 4) * m.size;
    final double s = math.sin(m.rotation + math.pi / 4) * m.size;
    p
      ..moveTo(m.x - c, m.y - s)
      ..lineTo(m.x + c, m.y + s)
      ..moveTo(m.x - s, m.y + c)
      ..lineTo(m.x + s, m.y - c);
  }
  return TemperaNode(<TemperaOp>[
    if (marks.isNotEmpty)
      TemperaOp(path: p, color: color, alpha: alpha, strokeWidth: width),
  ]);
}

TemperaNode drawSquareMarks(
  List<TemperaMark> marks,
  Color color, [
  double alpha = 1,
]) {
  final Path p = Path();
  for (final TemperaMark m in marks) {
    p.addRect(
      Rect.fromLTWH(m.x - m.size / 2, m.y - m.size / 2, m.size, m.size),
    );
  }
  return TemperaNode(<TemperaOp>[
    if (marks.isNotEmpty) TemperaOp(path: p, color: color, alpha: alpha),
  ]);
}

// ---------------------------------------------------------------------------
// 构图上下文 + 运动（folia temperaCompositionContext.ts / temperaBlocks.ts）
// ---------------------------------------------------------------------------

/// 构图绘制的上下文：构图只往里 add 静态节点，时间与运动全在 [TemperaBlocks]。
class TemperaComposer {
  TemperaComposer({
    required this.kind,
    required this.palette,
    required this.decor,
    required this.width,
    required this.height,
    required this.seed,
    required this.showDecor,
    required this.flowAngle,
  }) : bleed = math.max(width, height) * 0.09 + math.max(width, height) * 0.08,
       gradient = palette.gradient == null
           ? null
           : TemperaGradientFill(
               palette.gradient!,
               temperaHash01(seed, 3, 197) * math.pi * 2,
             );

  final String kind;
  final TemperaPalette palette;
  final TemperaDecorSpec decor;
  final double width;
  final double height;
  final int seed;
  final bool showDecor;
  final double flowAngle;

  /// 满出血形状要伸出画外的余量（构图整个分镜都在沿 flow 滑动）。
  final double bleed;
  final TemperaGradientFill? gradient;
  final List<TemperaBlockItem> items = <TemperaBlockItem>[];

  void add(
    TemperaNode node, [
    TemperaBlockOptions options = const TemperaBlockOptions(),
    TemperaGroup? group,
  ]) {
    items.add(
      TemperaBlockItem(
        node,
        options,
        group,
        temperaHash01(seed, items.length, 173) * math.pi * 2,
      ),
    );
  }

  TemperaGroup createGroup(double rotation, double x, double y) =>
      TemperaGroup(rotation, x, y);
}

/// 一个分镜的色块层运动：入场错峰按分镜歌词长度排，沿 flow 的持续推移按分镜可见时长走。
class TemperaBlocks {
  TemperaBlocks(this.items, double width, double height, double flowAngle)
    : _flowX = math.cos(flowAngle),
      _flowY = math.sin(flowAngle),
      _carry = math.max(width, height) * 0.09;

  final List<TemperaBlockItem> items;
  final double _flowX;
  final double _flowY;
  final double _carry;
  double _schedulePace = double.nan;

  void _resolveSchedule(double pace) {
    if (pace == _schedulePace) return;
    _schedulePace = pace;
    final double budget = math.max(0.5, pace);
    for (final TemperaBlockItem item in items) {
      final double d = temperaShotPaced(pace, item.options.delay, 0, 1.4);
      final double s = temperaShotPaced(pace, item.options.span, 0.7, 2.6);
      final double compress = math.min(1, budget / (d + s));
      item.delay = d * compress;
      item.span = s * compress;
    }
  }

  /// 按绝对时间摆好每一项；[still] = 减弱动态效果（直接落位、不漂）。
  void update(
    double time,
    double shotStart,
    double shotEnd,
    double lyricEnd, {
    bool still = false,
  }) {
    final double duration = math.max(shotEnd - shotStart, 0.2);
    final double pace = math.max(lyricEnd - shotStart, 0.2);
    final double progress = temperaClamp01((time - shotStart) / duration);
    final double creep = still ? 0 : temperaEaseInOut(progress) * _carry * 0.35;
    _resolveSchedule(pace);
    for (final TemperaBlockItem item in items) {
      final double enter = still
          ? 1
          : temperaEaseEnter((time - shotStart - item.delay) / item.span);
      item.alpha = item.options.alpha * enter;
      item.visible = enter > 0.001;
      final double behind = (1 - enter) * _carry - creep;
      item.x =
          item.baseX + item.options.enterDX * (1 - enter) - _flowX * behind;
      item.y =
          item.baseY + item.options.enterDY * (1 - enter) - _flowY * behind;
      item.scaleX = 1;
      item.scaleY = 1;
      item.rotation = 0;
      if (!still && (item.options.drift || item.options.grow)) {
        final double float = item.options.drift
            ? 1 + math.sin(time * 0.5 + item.driftPhase) * 0.02
            : 1;
        item.scaleX = item.options.grow
            ? math.max(0.0001, enter) * float
            : float;
        item.scaleY = float;
        if (item.options.drift) {
          item.rotation = math.sin(time * 0.33 + item.driftPhase) * 0.012;
        }
      }
    }
  }
}
