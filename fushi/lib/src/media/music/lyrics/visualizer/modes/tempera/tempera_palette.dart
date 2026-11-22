/// 凝彩调色板（folia `temperaPalette.ts`）：从封面配色派生 duo / mono / gradient 三种。
/// paper→ink 的亮度阶梯（tone1–tone4）单调，构图的明暗结构与文字反色都靠它。
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

/// 色彩模式。
enum TemperaColorMode { duo, mono, gradient }

/// 凝彩用到的全部颜色。
class TemperaPalette {
  const TemperaPalette({
    required this.paper,
    required this.ink,
    required this.accent,
    required this.line,
    required this.tone1,
    required this.tone2,
    required this.tone3,
    required this.tone4,
    required this.gradient,
    required this.textGradient,
  });

  final Color paper;
  final Color ink;
  final Color accent;

  /// 细线色（带透明度）。
  final Color line;
  final Color tone1;
  final Color tone2;
  final Color tone3;
  final Color tone4;

  /// gradient 模式的四色 ramp（paper→ink 亮度排序），其余模式为 null。
  final List<Color>? gradient;

  /// gradient 模式文字用的鲜艳 ramp（只保证与 paper 的亮度差 ≥88）。
  final List<Color>? textGradient;
}

/// paper→ink 的固定混合位置。
const List<double> temperaToneStops = <double>[0.12, 0.3, 0.52, 0.72];

int _c(double v) => v.round().clamp(0, 255);
int _r(Color c) => _c(c.r * 255);
int _g(Color c) => _c(c.g * 255);
int _b(Color c) => _c(c.b * 255);

/// Rec.709 亮度（0–255）。
double temperaLuminance(Color c) =>
    _r(c) * 0.2126 + _g(c) * 0.7152 + _b(c) * 0.0722;

/// RGB 线性混合（不动透明度，取 1）。
Color temperaMix(Color from, Color to, double amount) => Color.fromARGB(
  255,
  _c(_r(from) + (_r(to) - _r(from)) * amount),
  _c(_g(from) + (_g(to) - _g(from)) * amount),
  _c(_b(from) + (_b(to) - _b(from)) * amount),
);

Color _gray(Color c) {
  final int l = temperaLuminance(c).round();
  return Color.fromARGB(255, l, l, l);
}

Color _withAlpha(Color c, double a) => c.withValues(alpha: a);

const Color _light = Color(0xFFF4F4F2);
const Color _dark = Color(0xFF141414);

Color _ensureInkContrast(Color paper, Color ink) {
  if ((temperaLuminance(ink) - temperaLuminance(paper)).abs() >= 96) return ink;
  final Color target = temperaLuminance(paper) < 128 ? _light : _dark;
  final Color tinted = temperaMix(target, ink, 0.14);
  return (temperaLuminance(tinted) - temperaLuminance(paper)).abs() >= 96
      ? tinted
      : target;
}

/// 把带色相的颜色缩放回目标亮度，加色相不打乱阶梯。
Color temperaMatchLuminance(Color color, Color target) {
  final double current = temperaLuminance(color);
  final double wanted = temperaLuminance(target);
  if (current <= 0.5) return target;
  final double gain = wanted / current;
  final Color scaled = Color.fromARGB(
    255,
    _c(math.min(255, _r(color) * gain)),
    _c(math.min(255, _g(color) * gain)),
    _c(math.min(255, _b(color) * gain)),
  );
  if ((temperaLuminance(scaled) - wanted).abs() > 1.5) return target;
  return scaled;
}

List<Color> _toneLadder(Color paper, Color ink, Color? tintA, Color? tintB) {
  Color step(int i, Color? tint) {
    final Color base = temperaMix(paper, ink, temperaToneStops[i]);
    return tint == null
        ? base
        : temperaMatchLuminance(temperaMix(base, tint, 0.3), base);
  }

  return <Color>[step(0, tintA), step(1, tintB), step(2, tintA), step(3, null)];
}

List<Color> _gradientRamp(Color paper, Color ink, List<Color> sources) {
  final List<Color> ranked = <Color>[...sources]
    ..sort(
      (Color a, Color b) => temperaLuminance(a).compareTo(temperaLuminance(b)),
    );
  final bool towardInk = temperaLuminance(ink) < temperaLuminance(paper);
  final List<Color> ordered = towardInk ? ranked.reversed.toList() : ranked;
  return <Color>[
    for (int i = 0; i < temperaToneStops.length; i++)
      () {
        final Color rung = temperaMix(paper, ink, temperaToneStops[i]);
        if (ordered.isEmpty) return rung;
        final Color hue = ordered[i % ordered.length];
        return temperaMatchLuminance(temperaMix(rung, hue, 0.78), rung);
      }(),
  ];
}

Color _enforceReadable(Color paper, Color color) {
  final double pl = temperaLuminance(paper);
  if ((temperaLuminance(color) - pl).abs() >= 88) return color;
  final Color away = pl < 128
      ? const Color(0xFFFFFFFF)
      : const Color(0xFF101010);
  for (int step = 1; step <= 5; step++) {
    final Color pushed = temperaMix(color, away, step * 0.16);
    if ((temperaLuminance(pushed) - pl).abs() >= 88) return pushed;
  }
  return temperaMix(color, away, 0.8);
}

/// 封面色向主题色混合的比例：封面占主导，但主题不被完全丢掉。
const double _themeHueMix = 0.32;

/// 由配色 + 色彩模式 + 封面取色得到调色板。
///
/// [background] / [primary] / [secondary] / [accent] 对应 folia 主题的
/// backgroundColor / primaryColor / secondaryColor / accentColor。
TemperaPalette resolveTemperaPalette({
  required Color background,
  required Color primary,
  required Color secondary,
  required Color accent,
  required TemperaColorMode mode,
  List<Color> coverColors = const <Color>[],
}) {
  if (mode == TemperaColorMode.mono) {
    final Color paper = _gray(background);
    Color ink = _gray(primary);
    if ((_r(ink) - _r(paper)).abs() < 96) {
      ink = _r(paper) < 128 ? const Color(0xFFF2F2F2) : _dark;
    }
    final List<Color> ladder = _toneLadder(paper, ink, null, null);
    return TemperaPalette(
      paper: paper,
      ink: ink,
      accent: temperaMix(paper, ink, 0.85),
      line: _withAlpha(temperaMix(paper, ink, 0.55), 0.55),
      tone1: ladder[0],
      tone2: ladder[1],
      tone3: ladder[2],
      tone4: ladder[3],
      gradient: null,
      textGradient: null,
    );
  }
  final Color paper = background.withValues(alpha: 1);
  final Color ink = _ensureInkContrast(paper, primary.withValues(alpha: 1));
  if (mode == TemperaColorMode.gradient) {
    final List<Color> themeHues = <Color>[accent, secondary, primary, ink];
    final List<Color> hues = coverColors.length >= 2
        ? <Color>[
            for (int i = 0; i < math.min(4, coverColors.length); i++)
              temperaMix(
                coverColors[i],
                themeHues[i % themeHues.length],
                _themeHueMix,
              ),
          ]
        : themeHues;
    final List<Color> ramp = _gradientRamp(paper, ink, hues);
    return TemperaPalette(
      paper: paper,
      ink: ink,
      accent: accent,
      line: _withAlpha(temperaMix(paper, ink, 0.6), 0.5),
      tone1: ramp[0],
      tone2: ramp[1],
      tone3: ramp[2],
      tone4: ramp[3],
      gradient: ramp,
      textGradient: <Color>[
        for (int i = 0; i < 4; i++)
          _enforceReadable(paper, hues[i % hues.length]),
      ],
    );
  }
  final List<Color> ladder = _toneLadder(paper, ink, accent, secondary);
  return TemperaPalette(
    paper: paper,
    ink: ink,
    accent: accent,
    line: _withAlpha(temperaMix(paper, ink, 0.6), 0.5),
    tone1: ladder[0],
    tone2: ladder[1],
    tone3: ladder[2],
    tone4: ladder[3],
    gradient: null,
    textGradient: null,
  );
}

/// 文字反色的判定：在 ink / paper 中选与底色亮度差更大的一个。
bool temperaPrefersPaper(Color backdrop, Color ink, Color paper) {
  final double l = temperaLuminance(backdrop);
  return (l - temperaLuminance(paper)).abs() >
      (l - temperaLuminance(ink)).abs();
}

/// 把颜色的亮度换成 [target] 的亮度（色相保留）：gradient 模式文字 tint 用。
Color temperaWithLuminanceOf(Color hue, Color target) {
  final double current = temperaLuminance(hue);
  final double wanted = temperaLuminance(target);
  if (current <= 0.5) return target;
  final double gain = wanted / current;
  final Color scaled = Color.fromARGB(
    255,
    _c(_r(hue) * gain),
    _c(_g(hue) * gain),
    _c(_b(hue) * gain),
  );
  // 亮色通道截断时向白 / 黑补齐亮度。
  final double got = temperaLuminance(scaled);
  if ((got - wanted).abs() <= 2) return scaled;
  return wanted > got
      ? temperaMix(
          scaled,
          const Color(0xFFFFFFFF),
          ((wanted - got) / (255 - got + 1e-6)).clamp(0.0, 1.0),
        )
      : temperaMix(
          scaled,
          const Color(0xFF000000),
          ((got - wanted) / (got + 1e-6)).clamp(0.0, 1.0),
        );
}
