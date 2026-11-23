/// 町景里写字的发光面（folia `engine/lyricScreen.ts` / `ledStrip.ts` / 城寨 `hologram.ts`）：
/// 逐字点亮当前行的 LED 歌词屏（像素格、点亮边界、慢刷新带、面板玻璃反光；换行时信号
/// 切换——横带错位、色散、雪花点；大屏闪拍的亮斑）、LED 点阵跑马灯、全息投影、七段数码管、
/// 霓虹字。都是“面上的贴花”：在面的局部坐标里画，由渲染器仿射到屏幕上。
library;

import 'dart:collection';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_board_layout.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_director.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_render.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_text.dart';

/// 换行时屏幕信号切换的总时长（秒）。
const double machiScreenSwitchSeconds = 0.3;

/// 横向的像素格数（竖向按面的宽高比取，格子是方的）。
const int machiScreenCellsX = 150;

/// 逐字点亮的 LED 歌词屏。一个场景一块（便利店屋顶三面共用、货车侧面、城寨大屏）。
class MachiLyricScreen {
  MachiLyricScreen(this.widthM, this.heightM);

  final double widthM;
  final double heightM;

  final LinkedHashMap<String, MachiBoardLayout> _layouts =
      LinkedHashMap<String, MachiBoardLayout>();
  String _key = '';
  MachiBoardLayout? _layout;
  String? _pendingKey;
  MachiBoardLayout? _pendingLayout;
  double _switchElapsed = machiScreenSwitchSeconds;
  double _glitch = 0;
  double _chorusGlow = 0;
  Path? _grid;
  Size _gridSize = Size.zero;

  /// 有切换动画在走。
  bool get busy => _switchElapsed < machiScreenSwitchSeconds;

  double get glitch => _glitch;

  MachiBoardLayout? get layout => _layout;

  Size get localSize =>
      Size(widthM * machiLocalPxPerMeter, heightM * machiLocalPxPerMeter);

  MachiBoardLayout _prepare(
    String key,
    MachiBoardTarget target,
    List<LyricVisualizerLine> lines,
    String title,
    String subtitle,
    MachiTextCache text,
  ) {
    final MachiBoardLayout? hit = _layouts.remove(key);
    if (hit != null) {
      _layouts[key] = hit;
      return hit;
    }
    final Size s = localSize;
    final MachiBoardBox box = MachiBoardBox(width: s.width, height: s.height);
    final int? i = target.lineIndex;
    final MachiBoardLayout layout = i == null || i >= lines.length
        ? layoutMachiBoardCard(title, subtitle, box, text.measure)
        : layoutMachiBoardLine(lines[i].glyphs, box, text.measure);
    _layouts[key] = layout;
    while (_layouts.length > 6) {
      _layouts.remove(_layouts.keys.first);
    }
    return layout;
  }

  /// 换歌 / 换字体：牌面全部重排。
  void invalidate() {
    _layouts.clear();
    _key = '';
    _layout = null;
    _pendingKey = null;
    _pendingLayout = null;
  }

  /// 每帧：换牌面（信号切换过去；[immediate] 时直接换）、点亮、副歌平滑。
  void update({
    required MachiBoardTarget target,
    MachiBoardTarget? preheat,
    required List<LyricVisualizerLine> lines,
    required String title,
    required String subtitle,
    required MachiTextCache text,
    required double delta,
    required bool immediate,
    required double chorus,
  }) {
    final String key =
        '${target.isCard ? 'card' : 'line:${target.lineIndex}'}|$title|$subtitle';
    final String wanted = _pendingKey ?? _key;
    if (key != wanted) {
      final MachiBoardLayout l = _prepare(
        key,
        target,
        lines,
        title,
        subtitle,
        text,
      );
      if (immediate || _layout == null) {
        _key = key;
        _layout = l;
        _pendingKey = null;
        _pendingLayout = null;
        _switchElapsed = machiScreenSwitchSeconds;
      } else {
        _pendingKey = key;
        _pendingLayout = l;
        _switchElapsed = 0;
      }
    }
    if (preheat != null && !preheat.isCard) {
      _prepare(
        '${'line:${preheat.lineIndex}'}|$title|$subtitle',
        preheat,
        lines,
        title,
        subtitle,
        text,
      );
    }
    _glitch = 0;
    if (_switchElapsed < machiScreenSwitchSeconds) {
      _switchElapsed += immediate
          ? machiScreenSwitchSeconds
          : math.max(delta, 1 / 120);
      final double t = math.min(1, _switchElapsed / machiScreenSwitchSeconds);
      if (t >= 0.45 && _pendingLayout != null) {
        _key = _pendingKey!;
        _layout = _pendingLayout;
        _pendingKey = null;
        _pendingLayout = null;
      }
      _glitch = t >= 1 ? 0 : math.pow(math.sin(math.pi * t), 0.7).toDouble();
    }
    if (_pendingLayout != null && _switchElapsed >= machiScreenSwitchSeconds) {
      _key = _pendingKey!;
      _layout = _pendingLayout;
      _pendingKey = null;
      _pendingLayout = null;
    }
    _chorusGlow = immediate
        ? chorus
        : _chorusGlow + (chorus - _chorusGlow) * (1 - math.exp(-delta * 3));
  }

  /// 贴花：画进屏幕面的局部坐标。
  void paint(Canvas canvas, Size size, MachiFrame f) {
    final bool light = f.palette.boardIsLight;
    final Color base = f.palette.boardBase;
    final Rect all = Offset.zero & size;
    canvas.drawRect(
      all,
      Paint()
        ..shader = ui.Gradient.linear(all.topCenter, all.bottomCenter, <Color>[
          machiScale(base, 1.0),
          machiScale(base, light ? 0.97 : 0.9),
        ]),
    );
    final MachiBoardLayout? layout = _layout;
    final double bright = 1 + 0.05 * f.audio + 0.06 * _chorusGlow;
    final Color lit = light
        ? f.palette.boardLit
        : machiScale(
            machiMix(
              f.palette.boardLit,
              const Color(0xFFFFFFFF),
              0.08 * _chorusGlow,
            ),
            bright,
          );
    final Color unlit = machiScale(f.palette.boardUnlit, light ? 1 : 0.9);
    if (layout != null) {
      final List<double> reveal = resolveMachiBoardReveal(
        layout,
        f.song * 1000,
      );
      if (_glitch > 0.02) {
        // 信号切换：几条横带错开、色散。
        const int bands = 14;
        final int tick = (f.ambient * 24).floor();
        for (int b = 0; b < bands; b++) {
          final double tear = machiHash01(0x5eed, b + tick * 7, 0x31);
          final double dx = tear > 0.62
              ? (tear - 0.5) * 0.08 * size.width * _glitch * 2
              : 0;
          final Rect band = Rect.fromLTWH(
            0,
            size.height * b / bands,
            size.width,
            size.height / bands + 0.5,
          );
          canvas.save();
          canvas.clipRect(band);
          canvas.translate(dx, 0);
          _drawRows(canvas, f.text, layout, reveal, unlit, lit, null);
          canvas.restore();
        }
        final double split = (0.0008 + 0.006 * _glitch) * size.width;
        canvas.save();
        canvas.translate(split, 0);
        _drawRows(
          canvas,
          f.text,
          layout,
          reveal,
          null,
          const Color(0xFFFF2040).withValues(alpha: 0.5 * _glitch),
          BlendMode.plus,
        );
        canvas.translate(-2 * split, 0);
        _drawRows(
          canvas,
          f.text,
          layout,
          reveal,
          null,
          const Color(0xFF2050FF).withValues(alpha: 0.5 * _glitch),
          BlendMode.plus,
        );
        canvas.restore();
      } else {
        _drawRows(canvas, f.text, layout, reveal, unlit, lit, null);
      }
    }
    // 大屏闪拍的亮斑。
    for (int i = 0; i < 4; i++) {
      final double amp = f.beat.swellAmp[i];
      if (amp <= 0.002) continue;
      final Offset c = Offset(f.beat.swellAt[i] * size.width, size.height / 2);
      final double r = size.width * 0.38;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = ui.Gradient.radial(c, r, <Color>[
            lit.withValues(alpha: machiClamp(0.32 * amp, 0, 1)),
            lit.withValues(alpha: 0),
          ]),
      );
    }
    _paintGrid(canvas, size, f);
    // 慢慢往下走的刷新带。
    final double roll = (f.ambient * 0.07) % 1;
    final Rect bandRect = Rect.fromCenter(
      center: Offset(size.width / 2, roll * size.height),
      width: size.width,
      height: size.height * 0.25,
    );
    canvas.drawRect(
      bandRect,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.linear(
          bandRect.topCenter,
          bandRect.bottomCenter,
          <Color>[
            const Color(0x00FFFFFF),
            const Color(0x0EFFFFFF),
            const Color(0x00FFFFFF),
          ],
          const <double>[0, 0.5, 1],
        ),
    );
    // 切换时的雪花点。
    if (_glitch > 0.02) {
      final Paint dot = Paint()..blendMode = BlendMode.plus;
      final int tick = (f.ambient * 30).floor();
      final double cell = size.width / machiScreenCellsX;
      for (int i = 0; i < 90; i++) {
        final double x = machiHash01(tick, i, 0x71) * size.width;
        final double y = machiHash01(tick, i, 0x72) * size.height;
        dot.color = Color.fromRGBO(255, 255, 255, 0.35 * _glitch);
        canvas.drawRect(Rect.fromLTWH(x, y, cell, cell), dot);
      }
      canvas.drawRect(
        all,
        Paint()..color = Color.fromRGBO(0, 0, 0, 0.25 * _glitch),
      );
    }
    // 面板玻璃：一道斜的柔光与一点天光反射。
    canvas.drawRect(
      all,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = ui.Gradient.linear(
          Offset(size.width * 0.55, 0),
          Offset(size.width * 0.85, size.height),
          <Color>[
            const Color(0x00FFFFFF),
            Color.fromRGBO(255, 255, 255, light ? 0.04 : 0.06),
            const Color(0x00FFFFFF),
          ],
          const <double>[0, 0.5, 1],
        ),
    );
    // 边缘一圈略暗（边框阴影）。
    canvas.drawRect(
      all.deflate(size.height * 0.015),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = size.height * 0.04
        ..color = const Color(0x55000000)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, size.height * 0.02),
    );
  }

  void _drawRows(
    Canvas canvas,
    MachiTextCache text,
    MachiBoardLayout layout,
    List<double> reveal,
    Color? unlit,
    Color lit,
    BlendMode? blend,
  ) {
    for (int r = 0; r < layout.rows.length; r++) {
      final MachiBoardRow row = layout.rows[r];
      if (row.text.isEmpty) continue;
      final Offset at = Offset(row.left, row.centerY - row.fontPx * 1.15 / 2);
      if (unlit != null) {
        text
            .painter(row.text, row.fontPx, unlit, weight: FontWeight.w800)
            .paint(canvas, at);
      }
      final double x = r < reveal.length ? reveal[r] : 0;
      if (x <= row.left) continue;
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(0, row.top, x, row.bottom));
      final TextPainter tp = text.painter(
        row.text,
        row.fontPx,
        lit,
        weight: FontWeight.w800,
      );
      if (blend != null) {
        canvas.saveLayer(null, Paint()..blendMode = blend);
        tp.paint(canvas, at);
        canvas.restore();
      } else {
        tp.paint(canvas, at);
      }
      canvas.restore();
    }
  }

  /// 像素格之间的黑缝：格子在屏幕上小到约 2.5 像素以下就淡掉（免得出摩尔纹）。
  void _paintGrid(Canvas canvas, Size size, MachiFrame f) {
    final double cell = size.width / machiScreenCellsX;
    final double cellPx = cell * f.camera.scale / machiLocalPxPerMeter;
    final double a = machiSmoothstep(2.2, 4.2, cellPx);
    if (a <= 0.01) return;
    if (_grid == null || _gridSize != size) {
      final Path p = Path();
      for (int i = 1; i < machiScreenCellsX; i++) {
        p
          ..moveTo(i * cell, 0)
          ..lineTo(i * cell, size.height);
      }
      final int rows = (size.height / cell).round();
      for (int j = 1; j < rows; j++) {
        p
          ..moveTo(0, j * cell)
          ..lineTo(size.width, j * cell);
      }
      _grid = p;
      _gridSize = size;
    }
    canvas.drawPath(
      _grid!,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = cell * 0.22
        ..color = Color.fromRGBO(0, 0, 0, 0.42 * a),
    );
  }
}

/// LED 点阵跑马灯：深色底上 LED 色的字往左滚，盖一层点阵的黑缝。
void machiPaintTicker(
  Canvas canvas,
  Size size,
  MachiFrame f, {
  Color? led,
  String? text,
  double speed = 1,
}) {
  final Rect all = Offset.zero & size;
  canvas.drawRect(all, Paint()..color = const Color(0xFF0B0D12));
  final String s = text ?? f.tickerText;
  final Color c = f.emissive(led ?? f.palette.led, 1.1);
  if (s.isNotEmpty) {
    final TextPainter tp = f.text.painter(
      s,
      size.height * 0.72,
      c,
      weight: FontWeight.w800,
    );
    final double gap = size.height * 2;
    final double total = tp.width + gap;
    final double scroll = (f.tickerScroll * speed * size.height) % total;
    final double y = (size.height - tp.height) / 2;
    for (double x = size.width - scroll - total; x < size.width; x += total) {
      if (x + tp.width < 0) continue;
      tp.paint(canvas, Offset(x, y));
    }
  }
  // 点阵：每格一颗 LED。
  final double cell = size.height / 9;
  final double cellPx = cell * f.camera.scale / machiLocalPxPerMeter;
  if (cellPx >= 1.6) {
    final Path p = Path();
    for (double x = cell; x < size.width; x += cell) {
      p
        ..moveTo(x, 0)
        ..lineTo(x, size.height);
    }
    for (double y = cell; y < size.height; y += cell) {
      p
        ..moveTo(0, y)
        ..lineTo(size.width, y);
    }
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = cell * 0.34
        ..color = Color.fromRGBO(
          0,
          0,
          0,
          0.55 * machiSmoothstep(1.6, 3, cellPx),
        ),
    );
  }
}

/// 全息投影（城寨巷子里，下一句）：加色、扫描线、换字时横带错位。
void machiPaintHologram(Canvas canvas, Size size, MachiFrame f) {
  final Rect all = Offset.zero & size;
  const Color cyan = Color(0xFF3FE8FF);
  const Color pink = Color(0xFFFF4FB0);
  final double flick = f.motion
      ? 0.85 + 0.15 * math.sin(f.ambient * 23) * math.sin(f.ambient * 7.3)
      : 1;
  canvas.saveLayer(all, Paint()..blendMode = BlendMode.plus);
  canvas.drawRect(
    all,
    Paint()
      ..shader = ui.Gradient.linear(all.bottomCenter, all.topCenter, <Color>[
        cyan.withValues(alpha: 0.22 * flick),
        cyan.withValues(alpha: 0.04),
      ]),
  );
  final String s = f.nextLine.isEmpty ? '♪ ${f.title}' : f.nextLine;
  final int tick = (f.ambient * 24).floor();
  const int bands = 8;
  for (int b = 0; b < bands; b++) {
    final double tear = machiHash01(0x401, b + tick * 5, 0x21);
    final double dx = f.nextGlitch > 0.02 && tear > 0.55
        ? (tear - 0.5) * size.width * 0.12 * f.nextGlitch
        : 0;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(
        0,
        size.height * b / bands,
        size.width,
        size.height / bands + 0.5,
      ),
    );
    canvas.translate(dx, 0);
    f.text.drawFitted(
      canvas,
      s,
      all.deflate(size.height * 0.12),
      pink.withValues(alpha: 0.55 * flick),
      fill: 0.62,
    );
    canvas.translate(size.height * 0.02, 0);
    f.text.drawFitted(
      canvas,
      s,
      all.deflate(size.height * 0.12),
      cyan.withValues(alpha: 0.9 * flick),
      fill: 0.62,
    );
    canvas.restore();
  }
  // 扫描线。
  final Paint scan = Paint()..color = const Color(0x66000000);
  final double step = math.max(2, size.height / 40);
  final double shift = f.motion ? (f.ambient * 30) % step : 0;
  for (double y = shift; y < size.height; y += step) {
    canvas.drawRect(
      Rect.fromLTWH(0, y, size.width, step * 0.4),
      scan..blendMode = BlendMode.dstOut,
    );
  }
  canvas.restore();
  canvas.drawRect(
    all,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.height * 0.02
      ..color = cyan.withValues(alpha: 0.5 * flick),
  );
}

/// 七段数码管的一行（价格立柱：播放进度 / 总时长 / 第几句）：灭着的 8 打底，亮的字压上。
void machiPaintSevenSeg(
  Canvas canvas,
  Rect box,
  String value,
  Color color,
  MachiFrame f,
) {
  final String ghost = value.replaceAll(RegExp(r'[0-9]'), '8');
  f.text.drawFitted(
    canvas,
    ghost,
    box,
    color.withValues(alpha: 0.12),
    fill: 0.8,
    weight: FontWeight.w900,
    align: Alignment.centerRight,
  );
  f.text.drawFitted(
    canvas,
    value,
    box,
    color,
    fill: 0.8,
    weight: FontWeight.w900,
    align: Alignment.centerRight,
    shadows: <Shadow>[Shadow(color: color, blurRadius: box.height * 0.25)],
  );
}

/// 霓虹字（发光的描边字）。
void machiPaintNeonText(
  Canvas canvas,
  String text,
  Rect box,
  Color color,
  MachiFrame f, {
  double intensity = 1,
  bool vertical = false,
}) {
  final double k = machiClamp(intensity, 0, 1.6);
  final Color core = machiMix(color, const Color(0xFFFFFFFF), 0.35 * k);
  final List<Shadow> glow = f.glow
      ? <Shadow>[
          Shadow(
            color: color.withValues(alpha: machiClamp(0.9 * k, 0, 1)),
            blurRadius: box.shortestSide * 0.18,
          ),
        ]
      : const <Shadow>[];
  final Color c = Color.lerp(
    machiScale(color, 0.35),
    core,
    machiClamp(k, 0, 1),
  )!;
  if (vertical) {
    f.text.drawVertical(canvas, text, box, c, shadows: glow);
  } else {
    f.text.drawFitted(canvas, text, box, c, shadows: glow);
  }
}
