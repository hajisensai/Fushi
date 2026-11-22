/// 町景的调色板（folia `engine/palette.ts`）：封面配色 → 场景各部分的颜色。底子（深蓝灰的夜、
/// 暖琥珀的灯）是固定的美术方向，封面色只在限定范围里推它：品牌三色条、屏幕字、LED、霓虹、
/// 贩卖机、商品用封面色，天空和暖光只偏一点色相。封面偏灰时按 seed 选经典便利店配色。纯函数。
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';

/// 背景亮度高于它时按亮色主题处理（广告屏换成白底）。
const double machiLightThemeLuminance = 0.4;
const double machiBoardMinContrast = 4.5;
const double _chromaticSaturation = 0.22;

const List<List<int>> _classicTriads = <List<int>>[
  <int>[0xf0781e, 0xf4f1ea, 0x1f9a52],
  <int>[0x2f6fd6, 0xf4f1ea, 0x58b8ea],
  <int>[0x1d9a63, 0xf4f1ea, 0x2d6cc0],
  <int>[0xe2402f, 0xf4f1ea, 0xf2b520],
  <int>[0x7a4fd0, 0xf4f1ea, 0xf07fae],
];

const List<int> _productFallback = <int>[
  0xe85d4a,
  0xf2c14e,
  0x4fa3d8,
  0x7ccf7a,
  0xf08cc0,
  0xf4f1ea,
  0x9b7be0,
  0xff9d4d,
];

class MachiPalette {
  const MachiPalette({
    required this.skyTop,
    required this.skyBottom,
    required this.skyTopDusk,
    required this.skyBottomDusk,
    required this.skyTopDay,
    required this.skyBottomDay,
    required this.hemiSky,
    required this.hemiSkyDusk,
    required this.hemiSkyDay,
    required this.moon,
    required this.moonDusk,
    required this.moonDay,
    required this.asphalt,
    required this.concrete,
    required this.interiorLight,
    required this.brand,
    required this.signText,
    required this.boardBase,
    required this.boardUnlit,
    required this.boardLit,
    required this.boardIsLight,
    required this.led,
    required this.neon,
    required this.vendingBody,
    required this.vendingAccent,
    required this.products,
  });

  final Color skyTop;
  final Color skyBottom;
  final Color skyTopDusk;
  final Color skyBottomDusk;
  final Color skyTopDay;
  final Color skyBottomDay;
  final Color hemiSky;
  final Color hemiSkyDusk;
  final Color hemiSkyDay;
  final Color moon;
  final Color moonDusk;
  final Color moonDay;
  final Color asphalt;
  final Color concrete;

  /// 场景里的暖光（店内、营业房），向封面强调色偏一点。
  final Color interiorLight;

  /// 品牌三色条（封面的“连锁店”配色）。
  final List<Color> brand;
  final Color signText;

  /// 歌词屏：底色、未唱到的字、唱到的字；亮色主题是白底彩字。
  final Color boardBase;
  final Color boardUnlit;
  final Color boardLit;
  final bool boardIsLight;
  final Color led;
  final Color neon;
  final Color vendingBody;
  final Color vendingAccent;
  final List<Color> products;

  // 固定的美术色。
  static final Color roadPaint = machiHex(0xc9d1dc);
  static final Color curb = machiHex(0x5f6878);
  static final Color plinthTop = machiHex(0x20242c);
  static final Color plinthMid = machiHex(0x3d3a36);
  static final Color plinthLow = machiHex(0x2b2622);
  static final Color plinthTrim = machiHex(0x15171c);
  static final Color glass = machiHex(0x9cc3e6);
  static final Color metal = machiHex(0x8a94a1);
  static final Color darkMetal = machiHex(0x383e49);
  static final Color pole = machiHex(0x979ca4);
  static final Color rubber = machiHex(0x1c1f26);
  static final Color wire = machiHex(0x11141a);
  static final Color caution = machiHex(0xe7b42e);
  static final Color stopRed = machiHex(0xc7302b);
  static final Color streetLight = machiHex(0xffe4b8);
  static final Color vendingLight = machiHex(0xd4ebff);
  static final Color gold = machiHex(0xffc861);
  static final Color snow = machiHex(0xf2f5fa);
}

bool _isChromatic(Color c) {
  final MachiHsl h = MachiHsl.of(c);
  return h.s >= _chromaticSaturation && h.l > 0.08 && h.l < 0.94;
}

/// 招牌色：拉到够鲜、亮度在招牌能读的区间。
Color machiVivid(
  Color c, {
  double minSaturation = 0.58,
  double minLightness = 0.42,
  double maxLightness = 0.62,
}) {
  final MachiHsl h = MachiHsl.of(c);
  return MachiHsl(
    h.h,
    math.max(minSaturation, h.s),
    machiClamp(h.l, minLightness, maxLightness),
  ).toColor();
}

Color _pullHue(Color base, Color toward, double amount) {
  final MachiHsl from = MachiHsl.of(base);
  final MachiHsl to = MachiHsl.of(toward);
  if (amount <= 0) return base;
  double diff = ((to.h - from.h) % 360 + 360) % 360;
  if (diff > 180) diff -= 360;
  return from.copyWith(h: from.h + diff * amount).toColor();
}

/// 天空 / 路面这些暗色：向背景色相偏 ≤25%（背景越有颜色偏得越多），亮度不动。
Color _tintDark(Color base, Color background) {
  final MachiHsl b = MachiHsl.of(background);
  if (b.s < 0.08) return base;
  return _pullHue(base, background, math.min(0.25, b.s * 0.45));
}

/// 把 [c] 的亮度往远离 [against] 的方向调，直到对比度够 [ratio]。
Color machiAdjustForContrast(Color c, Color against, double ratio) {
  if (machiContrast(c, against) >= ratio) return c;
  final MachiHsl h = MachiHsl.of(c);
  final bool darken = machiLuminance(against) > 0.18;
  for (int i = 1; i <= 40; i++) {
    final double l = machiClamp(h.l + (darken ? -i : i) * 0.025, 0, 1);
    final Color out = h.copyWith(l: l).toColor();
    if (machiContrast(out, against) >= ratio) return out;
  }
  return darken ? machiHex(0x111111) : machiHex(0xffffff);
}

/// 封面配色 + seed → 町景调色板。同样的输入总得到同样的结果。
MachiPalette resolveMachiPalette(LyricVisualizerPalette theme, int seed) {
  final Color background = theme.background;
  final bool isLight = machiLuminance(background) > machiLightThemeLuminance;
  final List<Color> candidates = <Color>[
    theme.primary,
    theme.accent,
    theme.secondary,
  ].where(_isChromatic).toList();

  List<Color> brand;
  if (candidates.isEmpty) {
    final List<int> triad =
        _classicTriads[machiHashString('$seed:brand') % _classicTriads.length];
    brand = triad.map(machiHex).toList();
  } else {
    final Color first = machiVivid(candidates.first);
    final double firstHue = MachiHsl.of(first).h;
    Color? second;
    for (final Color c in candidates.skip(1)) {
      if (machiHueDistance(MachiHsl.of(c).h, firstHue) >= 40) {
        second = c;
        break;
      }
    }
    final Color third = second != null
        ? machiVivid(second)
        : MachiHsl.of(first).copyWith(h: firstHue + 150).toColor();
    brand = <Color>[first, machiHex(0xf4f1ea), third];
  }
  final Color accent = candidates.isNotEmpty ? candidates.first : brand[0];

  Color boardBase;
  Color boardUnlit;
  Color boardLit;
  if (isLight) {
    boardBase = machiHex(0xf3eee4);
    boardUnlit = machiHex(0x9aa0ab);
    boardLit = machiAdjustForContrast(
      machiVivid(
        accent,
        minSaturation: 0.62,
        minLightness: 0.3,
        maxLightness: 0.46,
      ),
      boardBase,
      machiBoardMinContrast,
    );
  } else {
    boardBase = machiMix(machiHex(0x0f1420), machiVivid(accent), 0.12);
    boardUnlit = machiHex(0x6c7384);
    final Color glow = _isChromatic(accent)
        ? machiVivid(
            accent,
            minSaturation: 0.62,
            minLightness: 0.64,
            maxLightness: 0.74,
          )
        : MachiPalette.gold;
    boardLit = machiAdjustForContrast(glow, boardBase, machiBoardMinContrast);
  }

  final MachiHsl interior = MachiHsl.of(
    machiMix(machiHex(0xffc887), machiVivid(accent), 0.16),
  );
  final Color interiorLight = interior
      .copyWith(l: math.max(0.72, interior.l))
      .toColor();
  final Color signText =
      machiContrast(machiHex(0x1b1f27), brand[1]) >= machiBoardMinContrast
      ? machiHex(0x1b1f27)
      : machiHex(0xffffff);
  final MachiHsl vb = MachiHsl.of(brand[2]);
  final int offset =
      machiHashString('$seed:products') % _productFallback.length;
  final List<Color> pool = <Color>[
    brand[0],
    brand[2],
    for (int i = 0; i < _productFallback.length; i++)
      machiHex(_productFallback[(i + offset) % _productFallback.length]),
  ];

  return MachiPalette(
    skyTop: _tintDark(machiHex(0x0e1524), background),
    skyBottom: _tintDark(machiHex(0x26324a), background),
    skyTopDusk: _tintDark(machiHex(0x2c2f5c), background),
    skyBottomDusk: machiHex(0xe58a62),
    skyTopDay: _tintDark(machiHex(0x4d8bd4), background),
    skyBottomDay: machiHex(0xcde4f2),
    hemiSky: _tintDark(machiHex(0x3a4b6c), background),
    hemiSkyDusk: machiHex(0x8b79a6),
    hemiSkyDay: machiHex(0xbcd6ee),
    moon: machiHex(0x9cb3dc),
    moonDusk: machiHex(0xffae78),
    moonDay: machiHex(0xfff0da),
    asphalt: _tintDark(machiHex(0x2a303c), background),
    concrete: _tintDark(machiHex(0x4b5363), background),
    interiorLight: interiorLight,
    brand: brand,
    signText: signText,
    boardBase: boardBase,
    boardUnlit: boardUnlit,
    boardLit: boardLit,
    boardIsLight: isLight,
    led: machiVivid(
      accent,
      minSaturation: 0.85,
      minLightness: 0.58,
      maxLightness: 0.66,
    ),
    neon: machiVivid(
      accent,
      minSaturation: 0.75,
      minLightness: 0.6,
      maxLightness: 0.7,
    ),
    vendingBody: vb
        .copyWith(s: machiClamp(vb.s, 0.35, 0.62), l: 0.42)
        .toColor(),
    vendingAccent: machiVivid(
      brand[0],
      minSaturation: 0.6,
      minLightness: 0.48,
      maxLightness: 0.6,
    ),
    products: pool.take(8).toList(),
  );
}
