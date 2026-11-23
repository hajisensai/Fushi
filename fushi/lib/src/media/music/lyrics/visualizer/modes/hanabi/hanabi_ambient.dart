/// 夜空、环境层与画面框（移植 folia `hanabi/hanabiSky.ts`、`mg/ambient.ts`、`overlay.ts`）。
///
/// 环境层（整个场景单元一份）：back = 薄烟、远处星点（缓慢闪烁）、远方的小烟花；front = 前景散景、上升的火星。
/// 两层都按屏幕坐标画，每个点在自己的视差层里随 rise 下移，并在纵向 [−margin, height + margin) 里无缝循环。
/// 远方小烟花按种子排在整个单元的时间里，用 burstPlan 的闭式解；画面只由时间决定。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_fireworks.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

// ─── 夜空 ───────────────────────────────────────────────────────────────

/// 自上而下的夜空渐变；[alpha] 是 tuning.sky（folia 整层 alpha，≤ 0.002 不画）。
void paintHanabiSky(
  ui.Canvas canvas,
  Size size,
  HanabiTheme theme,
  double alpha,
) {
  if (alpha <= 0.002) return;
  final List<(double, Color)> stops = resolveHanabiSkyStops(theme);
  canvas.drawRect(
    Offset.zero & size,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(0, size.height),
        <Color>[
          for (final (_, Color c) in stops) c.withValues(alpha: clamp01(alpha)),
        ],
        <double>[for (final (double s, _) in stops) s],
      ),
  );
}

// ─── 环境层 ─────────────────────────────────────────────────────────────

/// 各层的视差系数：远处 0.2–0.6，前景 1.2–1.5（folia `AMBIENT_PARALLAX`）。
const double _pStarsNear = 0.42;
const double _pStarsFar = 0.2;
const double _pSmoke = 0.3;
const double _pDistant = 0.55;
const double _pEmbers = 1.25;
const double _pBokeh = 1.45;

const List<BurstKind> _distantKinds = <BurstKind>[
  BurstKind.kiku,
  BurstKind.botan,
  BurstKind.ring,
  BurstKind.yanagi,
  BurstKind.senrin,
  BurstKind.kamuro,
  BurstKind.strobe,
  BurstKind.kiku,
  BurstKind.botan,
];

/// 远方小烟花的基准时长（秒）。
const double kHanabiDistantDuration = 2.6;

/// 一个镜头情绪对应的远方小烟花频率（发 / 秒）。
double hanabiDistantRateOf(HanabiMood mood) => switch (mood) {
  HanabiMood.quiet => 0.08,
  HanabiMood.neutral => 0.2,
  HanabiMood.loud => 0.35,
};

/// 视差层里一个点的屏幕 y：y0 + rise × parallax + drift，在 [−margin, height + margin) 里循环。
double hanabiParallaxY(
  double y0,
  double rise,
  double parallax,
  double drift,
  double height,
  double margin,
) => wrapD(y0 + rise * parallax + drift + margin, height + margin * 2) - margin;

/// 远方小烟花：第 k 发（纯函数，按种子确定）。
class HanabiDistantBurst {
  const HanabiDistantBurst(this.at, this.x, this.y0, this.event);
  final double at;
  final double x;

  /// 在视差层里的纵向位置（0..span）。
  final double y0;
  final BurstEvent event;
}

HanabiDistantBurst hanabiDistantBurstAt(
  String seed,
  int k,
  double rate,
  double startTime,
  double width,
  double span,
) {
  final double salt = (hanabiHashString(seed) % 9973).toDouble();
  double h(int i) => mgHash01(k * 17.0 + i, salt + 0.37);
  final double at = startTime + (k + 0.1 + h(1) * 0.8) / rate;
  final BurstKind kind =
      _distantKinds[(h(2) * _distantKinds.length).floor() %
          _distantKinds.length];
  final double x = width * (0.06 + h(3) * 0.88);
  final double y0 = span * h(4);
  return HanabiDistantBurst(
    at,
    x,
    y0,
    BurstEvent(
      x: x,
      y: 0,
      at: at,
      seed: '$seed:distant:$k',
      scale: 1,
      squash: 0.35 + h(6) * 0.65,
      rotation: (h(7) - 0.5) * 0.8,
      spec: BurstSpec(
        kind: kind,
        count: 26 + (h(5) * 20).floor(),
        radius: 0.045 + h(8) * 0.045,
        duration: kHanabiDistantDuration * (0.75 + h(9) * 0.25),
        colors: <int>[
          (h(10) * 5).floor(),
          (h(11) * 5).floor(),
          (h(12) * 5).floor(),
        ],
        trail: 0.3 + h(13) * 0.4,
        twinkle: h(14) * 0.6,
      ),
    ),
  );
}

/// time 时可能在燃烧的远方小烟花序号范围 [first, last]（last < first 表示没有）。
(int, int) hanabiDistantRange(
  double time,
  double rate,
  double startTime,
  double endTime,
) {
  if (rate <= 0) return (0, -1);
  final int count = math.max(0, ((endTime - startTime) * rate).floor());
  final int first = math.max(
    0,
    ((time - kHanabiDistantDuration - startTime) * rate).floor() - 1,
  );
  final int last = math.min(count - 1, ((time - startTime) * rate).floor());
  return (first, last);
}

class _Dot {
  const _Dot({
    required this.texture,
    required this.tint,
    required this.x,
    required this.y0,
    required this.size,
    required this.alpha,
    required this.parallax,
    required this.speed,
    required this.freq,
    required this.phase,
    required this.sway,
  });
  final SparkTexture texture;
  final int tint;
  final double x;
  final double y0;
  final double size;
  final double alpha;
  final double parallax;
  final double speed;
  final double freq;
  final double phase;
  final double sway;
}

int _tintedSpark(HanabiPalette palette, int i) =>
    palette.sparks.isEmpty ? kWhite : palette.sparks[i % palette.sparks.length];

/// 环境层，整个场景单元一份（folia `createAmbient`）。尺寸 / 密度 / 调色变了重建。
class HanabiAmbient {
  HanabiAmbient({
    required this.seed,
    required this.size,
    required double density,
    required this.palette,
    required this.startTime,
    required this.endTime,
    required this.distantRate,
  }) : density = clampD(density, 0, 2) {
    final double width = size.width;
    final double height = size.height;
    final double unit = math.min(width, height);
    _margin = unit * 0.36;
    _span = height + _margin * 2;
    final HanabiRng rng = hanabiRng('$seed:ambient');
    final int starTint = mixRgb(kWhite, palette.glow, 0.25);
    final int brightTint = mixRgb(kWhite, palette.glow, 0.4);
    final int stars = (110 * this.density).round();
    for (int i = 0; i < stars; i++) {
      final bool bright = rng() < 0.08;
      final double depth = rng();
      final double x = rng() * width;
      final double y0 = rng() * _span;
      final double s =
          unit * (bright ? 0.012 + rng() * 0.01 : 0.002 + rng() * 0.004);
      final double alpha = bright ? 0.7 : 0.2 + rng() * 0.55;
      final double freq = 0.15 + rng() * 0.7;
      final double phase = rng() * kTau;
      _stars.add(
        _Dot(
          texture: bright ? SparkTexture.star4 : SparkTexture.dot,
          tint: bright ? brightTint : starTint,
          x: x,
          y0: y0,
          size: s,
          alpha: alpha,
          parallax: _pStarsFar + depth * (_pStarsNear - _pStarsFar),
          speed: 0,
          freq: freq,
          phase: phase,
          sway: 0,
        ),
      );
    }
    // 薄烟：folia 裁掉 glow 外圈 0.2、按 0.8 倍画，等于整张 glow 按 unit × (0.6–1.1) 画。
    final int smoke = (5 * math.min(1.5, this.density)).round();
    for (int i = 0; i < smoke; i++) {
      final double x = width * (0.1 + rng() * 0.8);
      final double y0 = rng() * _span;
      final double s = unit * (0.6 + rng() * 0.5);
      final double alpha = 0.035 + rng() * 0.035;
      final double freq = 0.03 + rng() * 0.04;
      final double phase = rng() * kTau;
      final double sway = unit * (0.05 + rng() * 0.08);
      _smoke.add(
        _Dot(
          texture: SparkTexture.glow,
          tint: mixRgb(_tintedSpark(palette, i), 0x9aa0b4, 0.6),
          x: x,
          y0: y0,
          size: s,
          alpha: alpha,
          parallax: _pSmoke,
          speed: 0,
          freq: freq,
          phase: phase,
          sway: sway,
        ),
      );
    }
    final int embers = (40 * this.density).round();
    for (int i = 0; i < embers; i++) {
      final double x = rng() * width;
      final double y0 = rng() * _span;
      final double s = unit * (0.012 + rng() * 0.016);
      final double alpha = 0.55 + rng() * 0.45;
      final double parallax = _pEmbers + rng() * 0.1;
      final double speed = unit * (0.05 + rng() * 0.12);
      final double freq = 0.4 + rng() * 0.9;
      final double phase = rng() * kTau;
      final double sway = unit * (0.008 + rng() * 0.02);
      _embers.add(
        _Dot(
          texture: SparkTexture.glow,
          tint: mixRgb(kGold, _tintedSpark(palette, i), 0.3),
          x: x,
          y0: y0,
          size: s,
          alpha: alpha,
          parallax: parallax,
          speed: speed,
          freq: freq,
          phase: phase,
          sway: sway,
        ),
      );
    }
    final int bokeh = (6 * this.density).round();
    for (int i = 0; i < bokeh; i++) {
      final double x = rng() * width;
      final double y0 = rng() * _span;
      final double s = unit * (0.08 + rng() * 0.1);
      final double alpha = 0.06 + rng() * 0.08;
      final double speed = unit * (0.01 + rng() * 0.02);
      final double freq = 0.1 + rng() * 0.2;
      final double phase = rng() * kTau;
      _bokeh.add(
        _Dot(
          texture: SparkTexture.glow,
          tint: _tintedSpark(palette, i + 2),
          x: x,
          y0: y0,
          size: s,
          alpha: alpha,
          parallax: _pBokeh,
          speed: speed,
          freq: freq,
          phase: phase,
          sway: unit * 0.02,
        ),
      );
    }
    _distantMax = (240 * math.min(1.5, this.density)).round();
  }

  /// 单元种子（rng 键为 `$seed:ambient`，folia 同）。
  final String seed;
  final Size size;
  final double density;
  final HanabiPalette palette;
  final double startTime;
  final double endTime;

  /// 远方小烟花的频率（单元里各镜头情绪频率的平均）。
  final double distantRate;
  late final double _margin;
  late final double _span;
  late final int _distantMax;
  final List<_Dot> _stars = <_Dot>[];
  final List<_Dot> _smoke = <_Dot>[];
  final List<_Dot> _embers = <_Dot>[];
  final List<_Dot> _bokeh = <_Dot>[];
  final Map<int, (HanabiDistantBurst, BurstPlan)> _distant =
      <int, (HanabiDistantBurst, BurstPlan)>{};
  final SparkBatch _batch = SparkBatch();

  /// 星、烟、火星、散景的点数（测试用）。
  int get dotCount =>
      _stars.length + _smoke.length + _embers.length + _bokeh.length;

  void _place(_Dot dot, double x, double y, double s, double alpha) {
    if (alpha <= 0.004 || y <= -s || y >= size.height + s) return;
    _batch.sprite(dot.texture, x, y, s, 0, alpha, dot.tint);
  }

  void _resetBatch() {
    _batch
      ..reset(1 << 30)
      // 环境层不进烟花层的辉光（folia 的 glow filter 只挂在镜头的烟花层上）。
      ..halo = 0
      ..offsetX = 0
      ..offsetY = 0
      ..alphaScale = 1;
  }

  /// 薄烟、星点、远方小烟花（单元里最底下，屏幕坐标）。
  void paintBack(
    ui.Canvas canvas,
    HanabiSprites sprites,
    double time,
    double rise,
  ) {
    if (density <= 0) return;
    final double height = size.height;
    final double unit = math.min(size.width, height);
    _resetBatch();
    for (final _Dot dot in _smoke) {
      final double y = hanabiParallaxY(
        dot.y0,
        rise,
        dot.parallax,
        -time * unit * 0.01,
        height,
        _margin,
      );
      final double x =
          dot.x + math.sin(time * dot.freq * kTau + dot.phase) * dot.sway;
      _place(
        dot,
        x,
        y,
        dot.size * (1 + 0.1 * math.sin(time * 0.2 + dot.phase)),
        dot.alpha,
      );
    }
    for (final _Dot dot in _stars) {
      final double y = hanabiParallaxY(
        dot.y0,
        rise,
        dot.parallax,
        0,
        height,
        _margin,
      );
      final double twinkle =
          0.55 + 0.45 * math.sin(time * dot.freq * kTau + dot.phase);
      _place(
        dot,
        dot.x,
        y,
        dot.size * (0.85 + 0.3 * twinkle),
        dot.alpha * twinkle,
      );
    }
    if (distantRate > 0 && _distantMax > 0) {
      final (int first, int last) = hanabiDistantRange(
        time,
        distantRate,
        startTime,
        endTime,
      );
      _distant.removeWhere((int k, _) => k < first || k > last);
      final int base = _batch.used;
      for (int k = first; k <= last; k++) {
        final (HanabiDistantBurst burst, BurstPlan plan) = _distant.putIfAbsent(
          k,
          () {
            final HanabiDistantBurst burst = hanabiDistantBurstAt(
              seed,
              k,
              distantRate,
              startTime,
              size.width,
              _span,
            );
            return (
              burst,
              planBurst(
                burst.event,
                palette,
                unit: unit,
                amount: math.min(1.5, density),
              ),
            );
          },
        );
        if (time < plan.at || time > plan.end) continue;
        final int left = _distantMax - (_batch.used - base);
        if (left <= 0) break;
        _batch
          ..budget = _batch.used + left
          ..offsetY = hanabiParallaxY(
            burst.y0,
            rise,
            _pDistant,
            0,
            height,
            _margin,
          )
          // 远处的更淡。
          ..alphaScale = 0.6;
        drawBursts(<BurstPlan>[plan], time, _batch);
      }
      _batch
        ..budget = 1 << 30
        ..offsetY = 0
        ..alphaScale = 1;
    }
    _batch.flush(canvas, sprites);
  }

  /// 前景散景与上升的火星（单元里最上面，屏幕坐标，普通混合）。
  void paintFront(
    ui.Canvas canvas,
    HanabiSprites sprites,
    double time,
    double rise,
  ) {
    if (density <= 0) return;
    final double height = size.height;
    _resetBatch();
    for (final _Dot dot in _bokeh) {
      final double y = hanabiParallaxY(
        dot.y0,
        rise,
        dot.parallax,
        -time * dot.speed,
        height,
        _margin,
      );
      final double x =
          dot.x + math.sin(time * dot.freq * kTau + dot.phase) * dot.sway;
      _place(
        dot,
        x,
        y,
        dot.size,
        dot.alpha * (0.8 + 0.2 * math.sin(time * 0.5 + dot.phase)),
      );
    }
    for (final _Dot dot in _embers) {
      final double y = hanabiParallaxY(
        dot.y0,
        rise,
        dot.parallax,
        -time * dot.speed,
        height,
        _margin,
      );
      final double x =
          dot.x + math.sin(time * dot.freq * kTau + dot.phase) * dot.sway;
      final double flicker =
          mgHash01((time * 14 + dot.phase * 10).floorToDouble(), dot.phase) <
              0.25
          ? 0.35
          : 1;
      // 越往上越暗：像飘起来慢慢燃尽的火星。
      final double fade = 0.35 + 0.65 * clamp01(y / height);
      _place(
        dot,
        x,
        y,
        dot.size * (0.8 + 0.4 * flicker),
        dot.alpha * flicker * fade,
      );
    }
    _batch.flush(canvas, sprites);
  }
}

// ─── 画面框（overlay.ts）────────────────────────────────────────────────

/// 花火的画框装饰：左上角一枚「花火」朱印，右缘竖排的小字 HANABI，左下三颗烟花色圆点 + 细线，右下一个角标。
/// 静态、小而淡。[paint] 的调色板应是 kawaii 调色（folia `resolveHanabiPalette('kawaii', theme, colorMode)`）。
class HanabiOverlay {
  final Map<String, TextPainter> _painters = <String, TextPainter>{};

  TextPainter _text(
    String text,
    double size,
    Color color,
    TextStyle base, {
    double letterSpacing = 0,
  }) {
    final String key =
        '$text|${size.toStringAsFixed(1)}|${color.toARGB32()}|'
        '${base.fontFamily}|${base.fontWeight}|${letterSpacing.toStringAsFixed(2)}';
    return _painters.putIfAbsent(key, () {
      if (_painters.length > 32) {
        for (final TextPainter p in _painters.values) {
          p.dispose();
        }
        _painters.clear();
      }
      return TextPainter(
        text: TextSpan(
          text: text,
          style: base.copyWith(
            fontSize: size,
            color: color,
            // folia resolveThemeFontWeight(theme, 700)：主题没给字重时 700。
            fontWeight: base.fontWeight ?? FontWeight.w700,
            letterSpacing: letterSpacing,
            height: 1,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  void paint(
    ui.Canvas canvas,
    Size size,
    HanabiPalette palette,
    TextStyle base,
    double alpha,
  ) {
    if (alpha <= 0.01) return;
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final double padX = math.max(0.07 * w, unit * 0.06);
    final double padY = math.max(0.08 * h, unit * 0.06);
    final double line = math.max(1.2, unit / 640);
    final int block = palette.blocks.isNotEmpty
        ? palette.blocks.first
        : palette.accent;
    // 左上角的朱印。
    final double seal = unit * 0.024;
    final Offset sc = Offset(padX + seal, padY + seal);
    canvas
      ..drawCircle(sc, seal, Paint()..color = rgbColor(block, 0.85 * alpha))
      ..drawCircle(
        sc,
        seal * 1.28,
        Paint()
          ..color = rgbColor(block, 0.5 * alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = line,
      );
    final TextPainter stamp = _text(
      '花火',
      seal * 0.66,
      rgbColor(palette.ink, alpha),
      base,
      letterSpacing: -seal * 0.04,
    );
    stamp.paint(canvas, sc - Offset(stamp.width / 2, stamp.height / 2));
    // 右缘竖排的 HANABI。
    final double ls = unit * 0.017;
    const String word = 'HANABI';
    for (int i = 0; i < word.length; i++) {
      final TextPainter p = _text(
        word[i],
        ls,
        rgbColor(palette.paper, 0.55 * alpha),
        base,
      );
      final double cy = padY + ls * (0.6 + i * 1.5);
      p.paint(canvas, Offset(w - padX - p.width / 2, cy - p.height / 2));
    }
    final double stemTop = padY + ls * (0.6 + 6 * 1.5);
    canvas.drawLine(
      Offset(w - padX, stemTop),
      Offset(w - padX, stemTop + unit * 0.08),
      Paint()
        ..color = rgbColor(palette.paper, 0.35 * alpha)
        ..strokeWidth = line,
    );
    // 左下三颗圆点 + 细线。
    final double dotY = h - padY;
    for (int i = 0; i < math.min(3, palette.sparks.length); i++) {
      canvas.drawCircle(
        Offset(padX + i * unit * 0.018, dotY),
        unit * 0.0055,
        Paint()..color = rgbColor(palette.sparks[i], 0.85 * alpha),
      );
    }
    canvas.drawLine(
      Offset(padX + unit * 0.05, dotY),
      Offset(padX + unit * 0.16, dotY),
      Paint()
        ..color = rgbColor(palette.paper, 0.35 * alpha)
        ..strokeWidth = line,
    );
    // 右下角标。
    final double arm = unit * 0.035;
    final ui.Path corner = ui.Path()
      ..moveTo(w - padX - arm, h - padY)
      ..lineTo(w - padX, h - padY)
      ..lineTo(w - padX, h - padY - arm);
    canvas.drawPath(
      corner,
      Paint()
        ..color = rgbColor(palette.accent, 0.6 * alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = line * 1.4,
    );
  }

  void dispose() {
    for (final TextPainter p in _painters.values) {
      p.dispose();
    }
    _painters.clear();
  }
}
