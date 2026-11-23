/// 花火的调色板（移植 folia `hanabi/color.ts` + `hanabiSky.ts`）：预设的 PaletteRole × 主题色 ×
/// colorMode → [HanabiPalette]；色块上的字色按亮度自动选，并把色块调到与字色有足够的对比度。
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

/// 一个镜头的颜色（全是 0xRRGGBB）。
class HanabiPalette {
  const HanabiPalette({
    required this.ink,
    required this.paper,
    required this.blocks,
    required this.sparks,
    required this.accent,
    required this.glow,
  });

  /// 色块上的字色。
  final int ink;

  /// 反差色：描边、没有色块时的字色、纸白。
  final int paper;
  final List<int> blocks;
  final List<int> sparks;
  final int accent;
  final int glow;
}

/// 配色来源（folia `colorMode`）。
enum HanabiColorMode { theme, vivid, mixed }

/// 主题色（folia `Theme` 的四个颜色），由 [LyricVisualizerPalette] 转来。
class HanabiTheme {
  const HanabiTheme({
    required this.primary,
    required this.accent,
    required this.secondary,
    required this.background,
  });

  final int primary;
  final int accent;
  final int secondary;
  final int background;
}

// ─── HSL ───────────────────────────────────────────────────────────────

typedef _Hsl = (double, double, double);

_Hsl _toHsl(int hex) {
  final double r = ((hex >> 16) & 255) / 255;
  final double g = ((hex >> 8) & 255) / 255;
  final double b = (hex & 255) / 255;
  final double max = math.max(r, math.max(g, b));
  final double min = math.min(r, math.min(g, b));
  final double l = (max + min) / 2;
  if (max == min) return (0, 0, l);
  final double d = max - min;
  final double s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  final double h = max == r
      ? (g - b) / d + (g < b ? 6 : 0)
      : max == g
      ? (b - r) / d + 2
      : (r - g) / d + 4;
  return (h / 6, s, l);
}

int _hexOfRgb(double r, double g, double b) {
  int c(double v) => (clamp01(v) * 255).round();
  return (c(r) << 16) | (c(g) << 8) | c(b);
}

int _fromHsl(double h, double s, double l) {
  if (s == 0) return _hexOfRgb(l, l, l);
  final double q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  final double p = 2 * l - q;
  double channel(double t) {
    final double x = t < 0 ? t + 1 : (t > 1 ? t - 1 : t);
    if (x < 1 / 6) return p + (q - p) * 6 * x;
    if (x < 1 / 2) return q;
    if (x < 2 / 3) return p + (q - p) * (2 / 3 - x) * 6;
    return p;
  }

  return _hexOfRgb(channel(h + 1 / 3), channel(h), channel(h - 1 / 3));
}

/// 色相沿最短方向往 target 转 amount。
double _mixHue(double from, double to, double amount) {
  double delta = to - from;
  if (delta > 0.5) delta -= 1;
  if (delta < -0.5) delta += 1;
  return (from + delta * amount + 1) % 1;
}

/// 调成烟花色：饱和度至少 sat、亮度落在 [minL, maxL]。
int _vivid(int hex, double sat, double minL, double maxL) {
  final (double h, double s, double l) = _toHsl(hex);
  final double saturation = s < 0.05 ? s : math.max(s, sat);
  return _fromHsl(h, saturation, math.min(maxL, math.max(minL, l)));
}

// ─── 对比度 ─────────────────────────────────────────────────────────────

double _linear(double v) =>
    v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();

double relativeLuminance(int hex) {
  final double r = ((hex >> 16) & 255) / 255;
  final double g = ((hex >> 8) & 255) / 255;
  final double b = (hex & 255) / 255;
  return 0.2126 * _linear(r) + 0.7152 * _linear(g) + 0.0722 * _linear(b);
}

double contrastRatio(int a, int b) {
  final double la = relativeLuminance(a);
  final double lb = relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// 色块上的深色字：深梅紫。
const int kDarkInk = 0x2b1f3d;
const int kLightInk = 0xffffff;
const double kMinBlockContrast = 3.2;
const double kMinSungContrast = 3;
const double kMinFlashContrast = 2;

int _separate(int block, int ink) {
  if (contrastRatio(block, ink) >= kMinBlockContrast) return block;
  final (double h, double s, double l) = _toHsl(block);
  final bool darker = relativeLuminance(ink) > 0.5;
  for (int step = 1; step <= 20; step++) {
    final int next = _fromHsl(
      h,
      s,
      clamp01(darker ? l - step * 0.04 : l + step * 0.04),
    );
    if (contrastRatio(next, ink) >= kMinBlockContrast) return next;
  }
  return darker ? 0x000000 : 0xffffff;
}

/// 把 color 的亮度往远离 against 的方向推，直到对比度达到 min。
int ensureContrast(int color, int against, double min) {
  if (contrastRatio(color, against) >= min) return color;
  final (double h, double s, double l) = _toHsl(color);
  final List<int> directions = relativeLuminance(against) > 0.18
      ? const <int>[-1, 1]
      : const <int>[1, -1];
  for (int step = 1; step <= 25; step++) {
    for (final int direction in directions) {
      final int next = _fromHsl(h, s, clamp01(l + direction * step * 0.04));
      if (contrastRatio(next, against) >= min) return next;
    }
  }
  return contrastRatio(0x000000, against) >= contrastRatio(0xffffff, against)
      ? 0x000000
      : 0xffffff;
}

/// 字后面没有色块时的底。
int hanabiBackdropOf(HanabiPalette palette) =>
    relativeLuminance(palette.paper) > 0.5 ? 0x0b0d24 : 0xf3efe9;

class HanabiGlyphColors {
  const HanabiGlyphColors({
    required this.ink,
    required this.sung,
    required this.flash,
    required this.back,
  });

  final int ink;
  final int sung;
  final int flash;
  final int back;
}

/// 一个字的几种颜色，都按它身后的色块（under）来挑。
HanabiGlyphColors resolveHanabiGlyphColors(
  HanabiPalette palette,
  int base,
  int under,
) {
  final int ink = ensureContrast(base, under, kMinSungContrast);
  final List<int> candidates = <int>[
    palette.accent,
    ...palette.sparks,
    palette.glow,
  ];
  int? sung;
  for (final int c in candidates) {
    if (contrastRatio(c, under) >= kMinSungContrast &&
        contrastRatio(c, ink) >= 1.3) {
      sung = c;
      break;
    }
  }
  return HanabiGlyphColors(
    ink: ink,
    sung: sung ?? ensureContrast(palette.accent, under, kMinSungContrast),
    flash: ensureContrast(palette.glow, under, kMinFlashContrast),
    back: ensureContrast(
      palette.sparks.isEmpty ? palette.accent : palette.sparks.first,
      under,
      kMinFlashContrast,
    ),
  );
}

// ─── 九种角色的鲜艳配色 ─────────────────────────────────────────────────

class _RoleColors {
  const _RoleColors(this.blocks, this.sparks, this.accent, this.glow);
  final List<int> blocks;
  final List<int> sparks;
  final int accent;
  final int glow;
}

const Map<PaletteRole, _RoleColors> _roles = <PaletteRole, _RoleColors>{
  PaletteRole.night: _RoleColors(
    <int>[0x1d2b7a, 0xd62f74, 0x5b3cc4],
    <int>[0xffd166, 0xff6fa5, 0x7bdff2, 0xffffff, 0xb79cff],
    0xffd166,
    0xffe3a3,
  ),
  PaletteRole.festival: _RoleColors(
    <int>[0xe60033, 0x1e50a2, 0xd9480f],
    <int>[0xffcc1a, 0xff3355, 0x3cc8ff, 0x6dff9a, 0xffffff],
    0xffc400,
    0xffa24a,
  ),
  PaletteRole.pastel: _RoleColors(
    <int>[0xff9ec0, 0x8fd8ff, 0xfff08a],
    <int>[0xffc4e1, 0xa8e8ff, 0xfff5b0, 0xd4bfff],
    0xff7fb2,
    0xfff0f6,
  ),
  PaletteRole.mono: _RoleColors(
    <int>[0xf4f1ea, 0xc9c3b3],
    <int>[0xffffff, 0xe8e2d0, 0xfff3d6],
    0xffffff,
    0xfff7e6,
  ),
  PaletteRole.gold: _RoleColors(
    <int>[0xf2b01e, 0xffd970, 0xfff1c9],
    <int>[0xffd36e, 0xffae3b, 0xfff1c1, 0xff8a3d],
    0xffc94a,
    0xffcf70,
  ),
  PaletteRole.neon: _RoleColors(
    <int>[0xff2bd6, 0x00e5ff, 0x7a2cff],
    <int>[0xff2bd6, 0x00f0ff, 0xb8ff1f, 0xffffff, 0x8f6bff],
    0x00f0ff,
    0xff6bf0,
  ),
  PaletteRole.sakura: _RoleColors(
    <int>[0xff5f9e, 0xfff4f8, 0xffb8d2],
    <int>[0xffb7d5, 0xffffff, 0xff6fae, 0xffe0ec],
    0xff4f93,
    0xffd6e8,
  ),
  PaletteRole.kawaii: _RoleColors(
    <int>[0xff7eb6, 0x7fd8ff, 0xffe066],
    <int>[0xffb3d9, 0xa0f0ff, 0xfff3a0, 0xd9b8ff, 0xffffff],
    0xff5fa2,
    0xffd1e8,
  ),
  PaletteRole.ocean: _RoleColors(
    <int>[0x0a5cff, 0x00c2b8, 0xeaf6ff],
    <int>[0x5ce1ff, 0x2bffd5, 0xffffff, 0x4d86ff],
    0x5ce1ff,
    0xa8f0ff,
  ),
};

_RoleColors _themeColors(HanabiTheme theme) {
  int spark(int hex) => _vivid(hex, 0.6, 0.58, 0.8);
  return _RoleColors(
    <int>[
      _vivid(theme.accent, 0.55, 0.3, 0.7),
      _vivid(theme.primary, 0.45, 0.25, 0.75),
      _vivid(theme.secondary, 0.5, 0.3, 0.7),
    ],
    <int>[
      spark(theme.accent),
      spark(theme.primary),
      spark(theme.secondary),
      0xffffff,
    ],
    spark(theme.accent),
    _vivid(theme.accent, 0.5, 0.75, 0.88),
  );
}

/// 主题强调色低于这个饱和度时不进色块与火花。
const double _mixMinSaturation = 0.2;

_RoleColors _mixColors(_RoleColors role, HanabiTheme theme) {
  final (double th, double ts, _) = _toHsl(theme.accent);
  if (ts < _mixMinSaturation) return role;
  final _RoleColors themed = _themeColors(theme);
  int lean(int hex) {
    final (double h, double s, double l) = _toHsl(hex);
    if (s < 0.05) return hex;
    return _fromHsl(_mixHue(h, th, 0.4), s, l);
  }

  return _RoleColors(
    <int>[themed.blocks.first, ...role.blocks.skip(1).map(lean)],
    <int>[themed.sparks.first, ...role.sparks.skip(1).map(lean)],
    themed.accent,
    lean(role.glow),
  );
}

/// 一个镜头的调色板。
HanabiPalette resolveHanabiPalette(
  PaletteRole role,
  HanabiTheme theme,
  HanabiColorMode mode,
) {
  final _RoleColors base = _roles[role] ?? _roles[PaletteRole.night]!;
  final _RoleColors colors = switch (mode) {
    HanabiColorMode.theme => _themeColors(theme),
    HanabiColorMode.mixed => _mixColors(base, theme),
    HanabiColorMode.vivid => base,
  };
  final int paper = relativeLuminance(theme.background) > 0.4
      ? kDarkInk
      : kLightInk;
  double worst(int ink) =>
      colors.blocks.map((int b) => contrastRatio(b, ink)).reduce(math.min);
  final int ink = worst(kDarkInk) >= worst(kLightInk) ? kDarkInk : kLightInk;
  return HanabiPalette(
    ink: ink,
    paper: paper,
    blocks: <int>[for (final int b in colors.blocks) _separate(b, ink)],
    sparks: colors.sparks,
    accent: colors.accent,
    glow: colors.glow,
  );
}

/// 夜空渐变的四个色标（`hanabiSky.ts`）。
List<(double, Color)> resolveHanabiSkyStops(HanabiTheme theme) {
  final (double hue, double saturation, _) = _toHsl(theme.accent);
  double lean(double base) {
    if (saturation < 0.2) return base;
    double delta = hue - base;
    if (delta > 0.5) delta -= 1;
    if (delta < -0.5) delta += 1;
    return base + delta * 0.3;
  }

  Color c(double h, double s, double l) =>
      rgbColor(_fromHsl(((h % 1) + 1) % 1, s, l));
  return <(double, Color)>[
    (0, c(lean(0.66), 0.62, 0.06)),
    (0.45, c(lean(0.7), 0.5, 0.11)),
    (0.82, c(lean(0.8), 0.48, 0.19)),
    (1, c(lean(0.9), 0.55, 0.27)),
  ];
}
