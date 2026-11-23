/// 可「生长」的矢量记录器（folia `sonnetAnimatedGraphics.ts`）：构建时把描边 / 填充命令录下，
/// 播放时按共享的错峰时间表逐条画出来——描边按长度生长（PathMetric 截取），填充淡入，单独的
/// 矩形填充从左往右擦出。时间表只由命令顺序决定，跳转安全。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_program.dart';

class _Command {
  _Command(
    this.path,
    this.isStroke,
    this.color,
    this.alpha,
    this.width,
    this.rect,
  );

  final Path path;
  final bool isStroke;
  final Color color;
  final double alpha;
  final double width;

  /// 整条路径就是一个矩形时（folia `rect_hint`），填充按宽度擦出。
  final Rect? rect;
  double delay = 0;
  double span = 1;
  List<ui.PathMetric>? metrics;
  double length = 0;
}

/// 录制器：API 与 folia AnimatedGraphics（Pixi Graphics 子集）一致，便于逐行对照移植。
class SonnetAnimatedGraphics {
  /// [seed] 只用于圆的起笔角与方向（folia 用 Math.random，这里改成种子以保证每次一致）。
  SonnetAnimatedGraphics(int seed) : _rng = SonnetRng(seed);

  final SonnetRng _rng;
  final List<_Command> _commands = <_Command>[];
  Path _path = Path();
  bool _hasPath = false;
  int _segments = 0;
  Rect? _rectHint;
  bool _scheduled = false;
  ui.Picture? _finished;

  /// 整层旋转（geo 变体的确定性旋转）。
  double rotation = 0;

  bool get isEmpty => _commands.isEmpty;

  SonnetAnimatedGraphics moveTo(double x, double y) {
    _path.moveTo(x, y);
    _hasPath = true;
    return this;
  }

  SonnetAnimatedGraphics lineTo(double x, double y) {
    _path.lineTo(x, y);
    _hasPath = true;
    _segments++;
    return this;
  }

  SonnetAnimatedGraphics quadraticCurveTo(
    double cx,
    double cy,
    double x,
    double y,
  ) {
    _path.quadraticBezierTo(cx, cy, x, y);
    _hasPath = true;
    _segments++;
    return this;
  }

  SonnetAnimatedGraphics bezierCurveTo(
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x,
    double y,
  ) {
    _path.cubicTo(c1x, c1y, c2x, c2y, x, y);
    _hasPath = true;
    _segments++;
    return this;
  }

  SonnetAnimatedGraphics arc(
    double cx,
    double cy,
    double r,
    double start,
    double end, {
    bool anticlockwise = false,
  }) {
    double diff = end - start;
    if (anticlockwise && diff > 0) {
      diff -= math.pi * 2;
    } else if (!anticlockwise && diff < 0) {
      diff += math.pi * 2;
    }
    _arcSweep(cx, cy, r, start, diff, forceMove: !_hasPath);
    return this;
  }

  void _arcSweep(
    double cx,
    double cy,
    double r,
    double start,
    double sweep, {
    required bool forceMove,
  }) {
    final Rect oval = Rect.fromCircle(center: Offset(cx, cy), radius: r);
    // 整圈拆成两半：arcTo 的整圈扫角会退化。
    if (sweep.abs() >= math.pi * 2 - 1e-6) {
      final double half = sweep / 2;
      _path.arcTo(oval, start, half, forceMove);
      _path.arcTo(oval, start + half, half, false);
    } else {
      _path.arcTo(oval, start, sweep, forceMove);
    }
    _hasPath = true;
    _segments++;
  }

  SonnetAnimatedGraphics circle(double x, double y, double r) {
    final double start = _rng.next() * math.pi * 2;
    final bool anti = _rng.next() > 0.5;
    final double diff = anti ? -math.pi * 2 : math.pi * 2;
    moveTo(x + math.cos(start) * r, y + math.sin(start) * r);
    _arcSweep(x, y, r, start, diff, forceMove: false);
    return this;
  }

  SonnetAnimatedGraphics rect(double x, double y, double w, double h) {
    final bool fresh = !_hasPath;
    moveTo(
      x,
      y,
    ).lineTo(x + w, y).lineTo(x + w, y + h).lineTo(x, y + h).lineTo(x, y);
    _rectHint = fresh ? Rect.fromLTWH(x, y, w, h) : null;
    return this;
  }

  void _record(bool stroke, Color color, double alpha, double width) {
    if (!_hasPath) return;
    _commands.add(
      _Command(
        _path,
        stroke,
        color,
        alpha,
        width,
        _segments == 4 ? _rectHint : null,
      ),
    );
    _path = Path();
    _hasPath = false;
    _segments = 0;
    _rectHint = null;
    _scheduled = false;
    _finished?.dispose();
    _finished = null;
  }

  SonnetAnimatedGraphics stroke(
    Color color, {
    double width = 1,
    double alpha = 1,
  }) {
    _record(true, color, alpha, width);
    return this;
  }

  SonnetAnimatedGraphics fill(Color color, {double alpha = 1}) {
    _record(false, color, alpha, 0);
    return this;
  }

  /// 每条命令自己的时间窗：黄金分割错开起点，抖动时长，全部恰好在进度 1 画完。
  void _schedule() {
    const double golden = 0.6180339887498949;
    int strokeIndex = 0;
    int fillIndex = 0;
    for (final _Command c in _commands) {
      final int index = c.isStroke ? strokeIndex++ : fillIndex++;
      final double slot = (index * golden) % 1;
      final double jitter = sonnetImul(index, 2654435761) / 4294967296.0;
      final double delay = slot * (c.isStroke ? 0.5 : 0.45);
      final double span = c.isStroke
          ? 0.32 + jitter * 0.26
          : 0.4 + jitter * 0.25;
      c.delay = delay;
      c.span = math.min(span, 1 - delay);
    }
    _scheduled = true;
  }

  static final Paint _paint = Paint();

  void _drawCommand(Canvas canvas, _Command c, double raw) {
    final double local = math.min(1, math.max(0, (raw - c.delay) / c.span));
    if (local <= 0) return;
    final double eased = 1 - math.pow(1 - local, 3).toDouble();
    if (c.isStroke) {
      _paint
        ..style = PaintingStyle.stroke
        ..strokeWidth = c.width
        ..strokeCap = StrokeCap.butt
        ..strokeJoin = StrokeJoin.miter
        ..color = c.color.withValues(alpha: c.alpha.clamp(0.0, 1.0));
      if (local >= 1) {
        canvas.drawPath(c.path, _paint);
        return;
      }
      final List<ui.PathMetric> metrics = c.metrics ??= () {
        final List<ui.PathMetric> m = c.path.computeMetrics().toList();
        c.length = m.fold<double>(
          0,
          (double s, ui.PathMetric x) => s + x.length,
        );
        return m;
      }();
      double remaining = c.length * eased;
      final Path partial = Path();
      for (final ui.PathMetric m in metrics) {
        if (remaining <= 0) break;
        final double take = math.min(remaining, m.length);
        partial.addPath(m.extractPath(0, take), Offset.zero);
        remaining -= take;
      }
      canvas.drawPath(partial, _paint);
    } else {
      final double alphaProgress =
          1 - math.pow(1 - math.min(1, local * 2), 3).toDouble();
      _paint
        ..style = PaintingStyle.fill
        ..color = c.color.withValues(
          alpha: (c.alpha * alphaProgress).clamp(0.0, 1.0),
        );
      final Rect? r = c.rect;
      if (r != null && local < 1) {
        canvas.drawRect(
          Rect.fromLTWH(r.left, r.top, r.width * eased, r.height),
          _paint,
        );
      } else {
        canvas.drawPath(c.path, _paint);
      }
    }
  }

  /// 按原始进度 0..1 画出（画完后录成 Picture 复用）。
  void paint(Canvas canvas, double rawProgress) {
    if (_commands.isEmpty) return;
    if (!_scheduled) _schedule();
    final double raw = math.min(1, math.max(0, rawProgress));
    if (rotation != 0) {
      canvas.save();
      canvas.rotate(rotation);
    }
    if (raw >= 1) {
      ui.Picture? pic = _finished;
      if (pic == null) {
        final ui.PictureRecorder rec = ui.PictureRecorder();
        final Canvas c = Canvas(rec);
        for (final _Command cmd in _commands) {
          _drawCommand(c, cmd, 1);
        }
        pic = _finished = rec.endRecording();
      }
      canvas.drawPicture(pic);
    } else {
      for (final _Command cmd in _commands) {
        _drawCommand(canvas, cmd, raw);
      }
    }
    if (rotation != 0) canvas.restore();
  }

  void dispose() {
    _finished?.dispose();
    _finished = null;
  }
}
