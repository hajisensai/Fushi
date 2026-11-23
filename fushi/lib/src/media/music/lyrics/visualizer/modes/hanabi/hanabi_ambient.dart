/// 夜空、环境层与画面框（移植 folia `hanabi/hanabiSky.ts`、`ambient.ts`、`overlay.ts`；拼贴层 `collage` 只取胶片边与网点两样）。
///
/// 环境层：远近两层星、烟、远处的小烟花、上飘的火星、前景散景；都按世界上升做视差，只由时间决定。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_color.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_fireworks.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

// ─── 夜空 ───────────────────────────────────────────────────────────────

/// 自上而下的夜空渐变；[alpha] 是 tuning.sky。
void paintHanabiSky(
  ui.Canvas canvas,
  Size size,
  HanabiTheme theme,
  double alpha,
) {
  if (alpha <= 0.01) return;
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
const double _distantDuration = 2.6;

double _moodRate(HanabiMood mood) => switch (mood) {
  HanabiMood.quiet => 0.08,
  HanabiMood.neutral => 0.2,
  HanabiMood.loud => 0.35,
};

/// 整首歌一份（种子固定）。尺寸 / 密度变了重建。
class HanabiAmbient {
  HanabiAmbient({
    required String seed,
    required this.density,
    required this.mood,
  }) : _seed = seed,
       _salt = (hanabiHashString(seed) % 9973).toDouble() {
    final HanabiRng rng = hanabiRng('$seed:ambient');
    final int stars = (110 * density).round();
    for (int i = 0; i < stars; i++) {
      final bool bright = rng() < 0.08;
      _stars.add(<double>[
        rng(), // x
        rng(), // y
        bright ? 1 : 0,
        bright ? 0.012 + 0.01 * rng() : 0.002 + 0.004 * rng(),
        bright ? 0.7 : 0.2 + 0.55 * rng(),
        0.15 + 0.7 * rng(), // freq
        rng() * kTau, // phase
        rng() < 0.5 ? 1 : 0, // near / far
      ]);
    }
    final int smoke = (5 * math.min(1.5, density)).round();
    for (int i = 0; i < smoke; i++) {
      _smoke.add(<double>[
        rng(),
        rng(),
        0.6 + 0.5 * rng(),
        0.035 + 0.035 * rng(),
        rng() * kTau,
      ]);
    }
    final int embers = (40 * density).round();
    for (int i = 0; i < embers; i++) {
      _embers.add(<double>[
        rng(),
        rng(),
        0.012 + 0.016 * rng(),
        0.55 + 0.45 * rng(),
        0.05 + 0.12 * rng(),
        rng() * kTau,
      ]);
    }
    final int bokeh = (6 * density).round();
    for (int i = 0; i < bokeh; i++) {
      _bokeh.add(<double>[
        rng(),
        rng(),
        0.08 + 0.1 * rng(),
        0.06 + 0.08 * rng(),
        rng() * kTau,
      ]);
    }
  }

  final String _seed;
  final double _salt;
  final double density;
  final HanabiMood mood;
  final List<List<double>> _stars = <List<double>>[];
  final List<List<double>> _smoke = <List<double>>[];
  final List<List<double>> _embers = <List<double>>[];
  final List<List<double>> _bokeh = <List<double>>[];
  final Map<int, BurstPlan> _distant = <int, BurstPlan>{};
  Size _distantSize = Size.zero;

  double _parallaxY(
    double y0,
    double rise,
    double parallax,
    double drift,
    double h,
    double margin,
  ) => wrapD(y0 + rise * parallax + drift + margin, h + 2 * margin) - margin;

  /// 星、烟、远处的烟花（画在歌词后面）。
  void paintBack(
    SparkBatch batch,
    Size size,
    double time,
    double rise,
    HanabiPalette palette,
  ) {
    if (density <= 0) return;
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final double margin = unit * 0.36;
    final int starTint = mixRgb(kWhite, palette.glow, 0.25);
    final int brightTint = mixRgb(kWhite, palette.glow, 0.4);
    for (final List<double> s in _stars) {
      final double parallax = s[7] > 0 ? _pStarsNear : _pStarsFar;
      final double y = _parallaxY(s[1] * h, rise, parallax, 0, h, margin);
      final double twinkle = 0.55 + 0.45 * math.sin(time * s[5] * kTau + s[6]);
      final bool bright = s[2] > 0;
      batch.sprite(
        bright ? SparkTexture.star4 : SparkTexture.dot,
        s[0] * w,
        y,
        unit * s[3] * (bright ? 2.4 : 1.6),
        0,
        s[4] * twinkle,
        bright ? brightTint : starTint,
      );
    }
    final int smokeTint = mixRgb(
      palette.sparks.isNotEmpty ? palette.sparks.first : palette.glow,
      0x9aa0b4,
      0.6,
    );
    for (final List<double> s in _smoke) {
      final double drift = -time * unit * 0.01;
      final double y = _parallaxY(s[1] * h, rise, _pSmoke, drift, h, margin);
      final double sway = math.sin(time * 0.07 + s[4]) * unit * 0.05;
      batch.sprite(
        SparkTexture.glow,
        s[0] * w + sway,
        y,
        unit * s[2] * 0.8 * 2,
        0,
        s[3],
        smokeTint,
      );
    }
    _paintDistant(batch, size, time, rise, palette);
  }

  void _paintDistant(
    SparkBatch batch,
    Size size,
    double time,
    double rise,
    HanabiPalette palette,
  ) {
    final double rate = _moodRate(mood) * math.min(2, density);
    if (rate <= 0) return;
    if (_distantSize != size) {
      _distantSize = size;
      _distant.clear();
    }
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final double margin = unit * 0.36;
    final int first = math.max(
      0,
      ((time - _distantDuration * 1.1) * rate).floor() - 1,
    );
    final int last = (time * rate).floor() + 1;
    _distant.removeWhere((int k, _) => k < first);
    final SparkBatch local = batch;
    final int budget = (240 * math.min(1.5, density)).round();
    final int before = local.used;
    for (int k = first; k <= last; k++) {
      double hh(int i) => mgHash01(k * 17.0 + i, _salt + 0.37);
      final double at = (k + 0.1 + hh(1) * 0.8) / rate;
      if (time < at || time > at + _distantDuration * 1.1) continue;
      final BurstPlan plan = _distant.putIfAbsent(k, () {
        final BurstKind kind =
            _distantKinds[(hh(2) * _distantKinds.length).floor() %
                _distantKinds.length];
        final BurstSpec spec =
            burstPreset(kind, <int>[
              (hh(10) * 5).floor(),
              (hh(11) * 5).floor(),
              (hh(12) * 5).floor(),
            ]).copyWith(
              count: (26 + 20 * hh(5)).round(),
              radius: 0.045 + 0.045 * hh(8),
              duration: _distantDuration * (0.75 + 0.25 * hh(9)),
              trail: 0.3 + 0.4 * hh(13),
              twinkle: 0.6 * hh(14),
            );
        return planBurst(
          BurstEvent(
            x: w * (0.06 + 0.88 * hh(3)),
            y: 0,
            at: at,
            spec: spec,
            seed: '$_seed:distant:$k',
            scale: 1,
            squash: 0.35 + 0.65 * hh(6),
            rotation: (hh(7) - 0.5) * 0.8,
          ),
          palette,
          unit: unit,
          amount: 1,
        );
      });
      final double y = _parallaxY(
        h * 0.45 * hh(4),
        rise,
        _pDistant,
        0,
        h,
        margin,
      );
      if (local.used - before >= budget) break;
      local.offsetY = y;
      local.alphaScale = 0.6;
      drawBursts(<BurstPlan>[plan], time, local);
      local.offsetY = 0;
      local.alphaScale = 1;
    }
  }

  /// 火星与散景（画在歌词前面）。
  void paintFront(
    SparkBatch batch,
    Size size,
    double time,
    double rise,
    HanabiPalette palette,
  ) {
    if (density <= 0) return;
    final double w = size.width;
    final double h = size.height;
    final double unit = math.min(w, h);
    final double margin = unit * 0.36;
    final int emberTint = mixRgb(
      kGold,
      palette.sparks.isNotEmpty ? palette.sparks.first : palette.glow,
      0.3,
    );
    for (final (int i, List<double> s) in _embers.indexed) {
      final double y = _parallaxY(
        s[1] * h,
        rise,
        _pEmbers,
        -time * unit * s[4],
        h,
        margin,
      );
      final double x = s[0] * w + math.sin(time * 0.8 + s[5]) * unit * 0.02;
      final double flicker =
          mgHash01((time * 9).floorToDouble(), i + _salt) < 0.25 ? 0.35 : 1;
      final double fade = 0.35 + 0.65 * clamp01(y / h);
      batch.sprite(
        SparkTexture.glow,
        x,
        y,
        unit * s[2] * 2,
        0,
        s[3] * flicker * fade,
        emberTint,
        additive: true,
      );
    }
    for (final List<double> s in _bokeh) {
      final double y = _parallaxY(
        s[1] * h,
        rise,
        _pBokeh,
        -time * unit * 0.006,
        h,
        margin,
      );
      final double x = s[0] * w + math.sin(time * 0.05 + s[4]) * unit * 0.04;
      batch.sprite(
        SparkTexture.glow,
        x,
        y,
        unit * s[2] * 2,
        0,
        s[3],
        palette.glow,
        additive: true,
      );
    }
  }
}

// ─── 拼贴（简化）────────────────────────────────────────────────────────

/// 左缘的胶片孔与右下角的网点块，跟着世界上升慢慢滑动。
void paintHanabiCollage(
  ui.Canvas canvas,
  Size size,
  double rise,
  HanabiPalette palette,
  double amount,
) {
  final double alpha = clamp01(amount) * 0.22;
  if (alpha <= 0.01) return;
  final double w = size.width;
  final double h = size.height;
  final double unit = math.min(w, h);
  final double hole = unit * 0.018;
  final double pitch = hole * 2.2;
  final double offset = wrapD(rise * 0.3, pitch);
  final Paint rail = Paint()..color = rgbColor(palette.paper, alpha * 0.6);
  final double railX = unit * 0.018;
  for (double y = -pitch + offset; y < h + pitch; y += pitch) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(railX, y, hole, hole * 0.7),
        Radius.circular(hole * 0.18),
      ),
      rail,
    );
  }
  final Paint dot = Paint()..color = rgbColor(palette.accent, alpha);
  final double dp = unit * 0.016;
  final double ox = w - unit * 0.22;
  final double oy = h - unit * 0.3 + wrapD(rise * 0.15, dp);
  for (int r = 0; r < 10; r++) {
    for (int c = 0; c < 10; c++) {
      final double k = 1 - (r + c) / 18;
      if (k <= 0) continue;
      canvas.drawCircle(Offset(ox + c * dp, oy + r * dp), dp * 0.32 * k, dot);
    }
  }
}

// ─── 画面框（overlay.ts）────────────────────────────────────────────────

/// 左上印章、右上竖排 HANABI、左下三个火花点、右下角线。
class HanabiOverlay {
  final Map<String, TextPainter> _painters = <String, TextPainter>{};

  TextPainter _text(String text, double size, Color color, TextStyle base) {
    final String key =
        '$text|${size.toStringAsFixed(1)}|${color.toARGB32()}|${base.fontFamily}';
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
            fontWeight: FontWeight.w800,
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
    // 印章
    final double seal = unit * 0.024;
    final Offset sc = Offset(padX + seal, padY + seal);
    canvas.drawCircle(sc, seal, Paint()..color = rgbColor(block, 0.85 * alpha));
    canvas.drawCircle(
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
    );
    stamp.paint(canvas, sc - Offset(stamp.width / 2, stamp.height / 2));
    // 竖排 HANABI
    final double ls = unit * 0.017;
    const String word = 'HANABI';
    double bottom = padY;
    for (int i = 0; i < word.length; i++) {
      final TextPainter p = _text(
        word[i],
        ls,
        rgbColor(palette.paper, 0.55 * alpha),
        base,
      );
      final double cy = padY + ls * (0.6 + i * 1.5);
      p.paint(canvas, Offset(w - padX - p.width / 2, cy - p.height / 2));
      bottom = cy + ls;
    }
    canvas.drawLine(
      Offset(w - padX, bottom + ls * 0.4),
      Offset(w - padX, bottom + ls * 0.4 + unit * 0.08),
      Paint()
        ..color = rgbColor(palette.paper, 0.35 * alpha)
        ..strokeWidth = line,
    );
    // 左下火花点
    for (int i = 0; i < 3; i++) {
      final int c = palette.sparks.isNotEmpty
          ? palette.sparks[i % palette.sparks.length]
          : palette.accent;
      canvas.drawCircle(
        Offset(padX + i * unit * 0.018, h - padY),
        unit * 0.0055,
        Paint()..color = rgbColor(c, alpha),
      );
    }
    canvas.drawLine(
      Offset(padX + 3 * unit * 0.018, h - padY),
      Offset(padX + unit * 0.16, h - padY),
      Paint()
        ..color = rgbColor(palette.paper, 0.35 * alpha)
        ..strokeWidth = line,
    );
    // 右下角线
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
