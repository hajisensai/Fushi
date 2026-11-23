/// 背景「漫游」（移植 folia `backgrounds/nomand/`：`NomandBackgroundLayer.tsx`、
/// `nomandShaderAdjustments.ts`、`tuning.ts`）：把封面（或用户自定义图）做成一种图片效果铺满——
/// 像素画（有序抖动）/ 纹理玻璃 / 纸张纹理 / 半调网点 / 镜头畸变，用主题色上色，可叠底色提升可读性。
///
/// 这五个效果在 folia 里都是静态的（Paper 图片着色器不随时间变），所以这里在后台 isolate 里按
/// 画布的设备像素尺寸逐像素烘焙一张图（参数 / 配色 / 尺寸变了才重烘，拖滑杆防抖），每帧只铺这张图。
/// 纸张纹理是程序生成的噪声，不带任何贴图。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/background_scene.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_frame.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

// ---------------------------------------------------------------------------
// 参数（folia `DEFAULT_NOMAND_BACKGROUND_TUNING`，键名沿用字段名）
// ---------------------------------------------------------------------------

abstract final class NomandBackgroundKeys {
  static const String imageSource = 'imageSource';
  static const String imagePack = 'imagePack';
  static const String effect = 'effect';
  static const String ditheringType = 'ditheringType';
  static const String size = 'size';
  static const String colorSteps = 'colorSteps';
  static const String originalColors = 'originalColors';
  static const String inverted = 'inverted';
  static const String flutedGlassSize = 'flutedGlassSize';
  static const String flutedGlassDistortion = 'flutedGlassDistortion';
  static const String flutedGlassBlur = 'flutedGlassBlur';
  static const String paperTextureContrast = 'paperTextureContrast';
  static const String paperTextureRoughness = 'paperTextureRoughness';
  static const String paperTextureFiber = 'paperTextureFiber';
  static const String halftoneDotsSize = 'halftoneDotsSize';
  static const String halftoneDotsRadius = 'halftoneDotsRadius';
  static const String halftoneDotsContrast = 'halftoneDotsContrast';
  static const String halftoneDotsOriginalColors = 'halftoneDotsOriginalColors';
  static const String halftoneDotsInverted = 'halftoneDotsInverted';
  static const String lensDistortionSpread = 'lensDistortionSpread';
  static const String lensDistortionBulge = 'lensDistortionBulge';
  static const String lensDistortionDispersion = 'lensDistortionDispersion';
  static const String overlayEnabled = 'overlayEnabled';
  static const String overlayOpacity = 'overlayOpacity';
}

/// 效果（落库值冻结）。
enum NomandEffect {
  dithering('dithering'),
  flutedGlass('fluted-glass'),
  paperTexture('paper-texture'),
  halftoneDots('halftone-dots'),
  lensDistortion('lens-distortion');

  const NomandEffect(this.value);

  final String value;

  static NomandEffect of(String v) {
    for (final NomandEffect e in values) {
      if (e.value == v) return e;
    }
    return dithering;
  }
}

String _fixed2(double v) => v.toStringAsFixed(2);
String _percent(double v) => '${(v * 100).round()}%';

bool Function(LyricVisualizerTuning) _whenEffect(NomandEffect e) =>
    (LyricVisualizerTuning v) =>
        NomandEffect.of(v.choice(NomandBackgroundKeys.effect, 'dithering')) ==
        e;

final List<LyricVisualizerTuningSpec> nomandBackgroundTunings =
    <LyricVisualizerTuningSpec>[
      lyricBgImageSourceSpec(NomandBackgroundKeys.imageSource),
      lyricBgImagePackSpec(
        NomandBackgroundKeys.imagePack,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.choice(NomandBackgroundKeys.imageSource, '') ==
            kLyricBgSourceUploaded,
      ),
      LyricVisualizerChoiceSpec(
        key: NomandBackgroundKeys.effect,
        label: () => t.music_visualizer_background_nomand_effect,
        options: <(String, String Function())>[
          (
            NomandEffect.dithering.value,
            () => t.music_visualizer_background_nomand_effect_dithering,
          ),
          (
            NomandEffect.flutedGlass.value,
            () => t.music_visualizer_background_nomand_effect_fluted_glass,
          ),
          (
            NomandEffect.paperTexture.value,
            () => t.music_visualizer_background_nomand_effect_paper_texture,
          ),
          (
            NomandEffect.halftoneDots.value,
            () => t.music_visualizer_background_nomand_effect_halftone,
          ),
          (
            NomandEffect.lensDistortion.value,
            () => t.music_visualizer_background_nomand_effect_lens,
          ),
        ],
        initial: NomandEffect.dithering.value,
      ),
      // 像素画
      LyricVisualizerChoiceSpec(
        key: NomandBackgroundKeys.ditheringType,
        label: () => t.music_visualizer_background_nomand_dithering_type,
        options: <(String, String Function())>[
          ('2x2', () => '2×2'),
          ('4x4', () => '4×4'),
          ('8x8', () => '8×8'),
        ],
        initial: '8x8',
        visibleWhen: _whenEffect(NomandEffect.dithering),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.size,
        label: () => t.music_visualizer_background_nomand_size,
        min: 0.5,
        max: 20,
        initial: 3,
        divisions: 39,
        format: (double v) => v.toStringAsFixed(1),
        visibleWhen: _whenEffect(NomandEffect.dithering),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.colorSteps,
        label: () => t.music_visualizer_background_nomand_color_steps,
        min: 1,
        max: 7,
        initial: 4,
        divisions: 6,
        format: (double v) => '${v.round()}',
        visibleWhen: _whenEffect(NomandEffect.dithering),
      ),
      LyricVisualizerToggleSpec(
        key: NomandBackgroundKeys.originalColors,
        label: () => t.music_visualizer_background_nomand_original_colors,
        initial: false,
        visibleWhen: _whenEffect(NomandEffect.dithering),
      ),
      LyricVisualizerToggleSpec(
        key: NomandBackgroundKeys.inverted,
        label: () => t.music_visualizer_background_nomand_inverted,
        initial: false,
        visibleWhen: _whenEffect(NomandEffect.dithering),
      ),
      // 纹理玻璃
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.flutedGlassSize,
        label: () => t.music_visualizer_background_nomand_fluted_size,
        min: 0.1,
        max: 1,
        initial: 0.5,
        divisions: 18,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.flutedGlass),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.flutedGlassDistortion,
        label: () => t.music_visualizer_background_nomand_distortion,
        min: 0,
        max: 1,
        initial: 0.5,
        divisions: 20,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.flutedGlass),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.flutedGlassBlur,
        label: () => t.music_visualizer_background_nomand_blur,
        min: 0,
        max: 1,
        initial: 0.08,
        divisions: 100,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.flutedGlass),
      ),
      // 纸张纹理
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.paperTextureContrast,
        label: () => t.music_visualizer_background_nomand_contrast,
        min: 0,
        max: 1,
        initial: 0.32,
        divisions: 100,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.paperTexture),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.paperTextureRoughness,
        label: () => t.music_visualizer_background_nomand_roughness,
        min: 0,
        max: 1,
        initial: 0.42,
        divisions: 100,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.paperTexture),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.paperTextureFiber,
        label: () => t.music_visualizer_background_nomand_fiber,
        min: 0,
        max: 1,
        initial: 0.3,
        divisions: 20,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.paperTexture),
      ),
      // 半调网点
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.halftoneDotsSize,
        label: () => t.music_visualizer_background_nomand_size,
        min: 0.1,
        max: 1,
        initial: 0.5,
        divisions: 18,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.halftoneDots),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.halftoneDotsRadius,
        label: () => t.music_visualizer_background_nomand_dot_radius,
        min: 0.1,
        max: 2,
        initial: 1.25,
        divisions: 38,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.halftoneDots),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.halftoneDotsContrast,
        label: () => t.music_visualizer_background_nomand_contrast,
        min: 0,
        max: 1,
        initial: 0.4,
        divisions: 20,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.halftoneDots),
      ),
      LyricVisualizerToggleSpec(
        key: NomandBackgroundKeys.halftoneDotsOriginalColors,
        label: () => t.music_visualizer_background_nomand_original_colors,
        initial: false,
        visibleWhen: _whenEffect(NomandEffect.halftoneDots),
      ),
      LyricVisualizerToggleSpec(
        key: NomandBackgroundKeys.halftoneDotsInverted,
        label: () => t.music_visualizer_background_nomand_inverted,
        initial: false,
        visibleWhen: _whenEffect(NomandEffect.halftoneDots),
      ),
      // 镜头畸变
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.lensDistortionSpread,
        label: () => t.music_visualizer_background_nomand_lens_spread,
        min: 0,
        max: 1,
        initial: 0.45,
        divisions: 20,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.lensDistortion),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.lensDistortionBulge,
        label: () => t.music_visualizer_background_nomand_lens_bulge,
        min: -1,
        max: 1,
        initial: 0.3,
        divisions: 40,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.lensDistortion),
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.lensDistortionDispersion,
        label: () => t.music_visualizer_background_nomand_lens_dispersion,
        min: 0,
        max: 1,
        initial: 0.65,
        divisions: 20,
        format: _fixed2,
        visibleWhen: _whenEffect(NomandEffect.lensDistortion),
      ),
      LyricVisualizerToggleSpec(
        key: NomandBackgroundKeys.overlayEnabled,
        label: () => t.music_visualizer_background_overlay,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: NomandBackgroundKeys.overlayOpacity,
        label: () => t.music_visualizer_background_overlay_opacity,
        min: 0,
        max: 1,
        initial: 0.35,
        divisions: 20,
        format: _percent,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.flag(NomandBackgroundKeys.overlayEnabled, true),
      ),
    ];

final LyricVisualizerBackgroundEntry nomandBackgroundEntry =
    LyricVisualizerBackgroundEntry(
      id: 'nomand',
      label: () => t.music_visualizer_background_nomand,
      icon: FushiIcons.gridView,
      tunings: nomandBackgroundTunings,
      builder: (LyricVisualizerContext c, LyricVisualizerTuning tu) =>
          LyricVisualizerBackgroundView(
            context: c,
            tuning: tu,
            create: NomandBackgroundScene.new,
          ),
    );

// ---------------------------------------------------------------------------
// folia `nomandShaderAdjustments.ts`（逐字移植）
// ---------------------------------------------------------------------------

const double _kMaxOverscan = 1.8;
const double _kOverscanMargin = 0.01;
const double _kReferenceAspect = 16 / 9;

// 纸张纹理固定形状参数（folia `NOMAND_PAPER_TEXTURE_SHAPE`）。
const double _kPaperFolds = 0.65;
const double _kPaperCrumples = 0.35;
const double _kPaperDrops = 0.2;
const int _kPaperFoldCount = 5;
const double _kPaperSeed = 5.8;

// 镜头固定形状参数（folia `NOMAND_LENS_SHAPE`）。
const double _kLensFocusCenter = 0.55;
const double _kLensFocusEdges = 0.8;
const double _kLensSwirl = 0.08;

double _clampOverscan(double s) => s.clamp(1.0, _kMaxOverscan);

double _overscanMargin(double s) =>
    s <= 1 ? 1 : _clampOverscan(s + _kOverscanMargin);

double _overscanForMargin(double margin) =>
    _overscanMargin(1 / (1 - 2 * margin.clamp(0.0, 0.45)));

/// 明暗自适应反色（浅色主题、非原色时把亮度翻一次）。
bool nomandDaylightInversion(bool inverted, bool original, bool daylight) =>
    daylight && !original ? !inverted : inverted;

/// 半调网点的反色基准与像素画相反（见 folia 注释）。
bool nomandHalftoneInversion(bool inverted, bool original, bool daylight) =>
    nomandDaylightInversion(!inverted, original, daylight);

/// 纸张法线把图像 UV 推出去时，遮住裁切边需要的预放大。
double nomandPaperOverscan(double roughness, double fiber) {
  final double maxNormal =
      2 * _kPaperFolds +
      1.5 * _kPaperCrumples +
      0.2 * _kPaperDrops +
      0.75 * roughness.clamp(0.0, 1.0) +
      0.1 * fiber.clamp(0.0, 1.0);
  return _overscanForMargin(0.02 * maxNormal);
}

/// 镜头膨胀把四角推出去时需要的预放大（二分反解，folia `getLensDistortionOverscan`）。
double nomandLensOverscan(double bulge, double spread) {
  final double outRadius =
      0.5 * math.sqrt(_kReferenceAspect * _kReferenceAspect + 1);
  final double s = spread.clamp(0.0, 1.0);
  final double reach = 0.7 * math.pow(s, 1.3 + 2.7 * s);
  final double edgeReach = reach * (1 - _kLensFocusEdges);
  final double headroom = math.max(0.35, 1 - edgeReach / outRadius);
  if (bulge <= 0) return _overscanMargin(1 / headroom);
  final double amount = math.min(bulge, 1) * 1.4;
  double cornerPush(double scale) {
    final double rn = 2 * outRadius / scale;
    return math.tan(rn * amount) / math.tan(amount) / rn;
  }

  double low = math.max(1, 2 * outRadius * amount / 1.45);
  if (low >= _kMaxOverscan ||
      cornerPush(_kMaxOverscan) > _kMaxOverscan * headroom) {
    return _kMaxOverscan;
  }
  if (low == 1 && cornerPush(1) <= headroom) {
    return _overscanMargin(1 / headroom);
  }
  double high = _kMaxOverscan;
  for (int i = 0; i < 32; i++) {
    final double mid = (low + high) / 2;
    if (cornerPush(mid) > mid * headroom) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return _overscanMargin(high);
}

// ---------------------------------------------------------------------------
// 逐像素效果（纯函数，跑在 isolate）
// ---------------------------------------------------------------------------

/// 一次烘焙的输入（跨 isolate 传，只含基本类型与 TypedData）。
class NomandJob {
  NomandJob({
    required this.source,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.width,
    required this.height,
    required this.pixelRatio,
    required this.effect,
    required this.params,
    required this.back,
    required this.front,
    required this.highlight,
    required this.shadow,
    required this.daylight,
  });

  /// 源图 RGBA8888。
  final Uint8List source;
  final int sourceWidth;
  final int sourceHeight;

  /// 输出尺寸（设备像素）。
  final int width;
  final int height;

  /// 输出每逻辑像素多少设备像素（尺寸类参数按逻辑像素给）。
  final double pixelRatio;
  final NomandEffect effect;

  /// 当前效果的参数（键见 [NomandBackgroundKeys]）。
  final Map<String, double> params;

  /// 颜色 0xAARRGGBB：底 / 前景 / 高光 / 阴影。
  final int back;
  final int front;
  final int highlight;
  final int shadow;
  final bool daylight;

  double p(String key, double fallback) => params[key] ?? fallback;
}

int _r(int c) => (c >> 16) & 0xFF;
int _g(int c) => (c >> 8) & 0xFF;
int _b(int c) => c & 0xFF;

double _mixD(double a, double b, double t) => a + (b - a) * t;

/// 源图采样器：输出像素坐标 → 源图（object-fit: cover × [overscan]），双线性。
class _Sampler {
  _Sampler(NomandJob j, double overscan)
    : _src = j.source,
      _sw = j.sourceWidth,
      _sh = j.sourceHeight,
      _cx = j.width / 2,
      _cy = j.height / 2,
      _scale =
          math.max(j.width / j.sourceWidth, j.height / j.sourceHeight) *
          overscan;

  final Uint8List _src;
  final int _sw;
  final int _sh;
  final double _cx;
  final double _cy;
  final double _scale;

  /// 采样输出坐标 ([x], [y])；落到图外返回 false（[out] 不动）。
  bool sample(double x, double y, Float64List out) {
    final double sx = (x - _cx) / _scale + _sw / 2 - 0.5;
    final double sy = (y - _cy) / _scale + _sh / 2 - 0.5;
    if (sx < -0.5 || sy < -0.5 || sx > _sw - 0.5 || sy > _sh - 0.5) {
      return false;
    }
    final double fx = sx.clamp(0.0, _sw - 1.0);
    final double fy = sy.clamp(0.0, _sh - 1.0);
    final int x0 = fx.floor();
    final int y0 = fy.floor();
    final int x1 = math.min(x0 + 1, _sw - 1);
    final int y1 = math.min(y0 + 1, _sh - 1);
    final double tx = fx - x0;
    final double ty = fy - y0;
    for (int c = 0; c < 3; c++) {
      final double a = _src[(y0 * _sw + x0) * 4 + c].toDouble();
      final double b = _src[(y0 * _sw + x1) * 4 + c].toDouble();
      final double d = _src[(y1 * _sw + x0) * 4 + c].toDouble();
      final double e = _src[(y1 * _sw + x1) * 4 + c].toDouble();
      out[c] = _mixD(_mixD(a, b, tx), _mixD(d, e, tx), ty);
    }
    return true;
  }
}

double _lum(Float64List c) =>
    (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255;

/// n×n Bayer 阈值（0–1，n = 2 / 4 / 8；递归定义 M(2n) = [[4M, 4M+2], [4M+3, 4M+1]]）。
double nomandBayer(int n, int x, int y) {
  const List<int> base = <int>[0, 2, 3, 1];
  final int xx = x % n;
  final int yy = y % n;
  int v = 0;
  for (int bit = (math.log(n) / math.ln2).round() - 1; bit >= 0; bit--) {
    final int bx = (xx >> bit) & 1;
    final int by = (yy >> bit) & 1;
    v = v * 4 + base[(by << 1) | bx];
  }
  return (v + 0.5) / (n * n);
}

/// 有序抖动量化：[v] 0–1 → {0, 1/steps, …, 1}（[threshold] 是 Bayer 阈值）。
double nomandQuantize(double v, int steps, double threshold) {
  final int n = math.max(1, steps);
  return ((v * n + threshold).floorToDouble() / n).clamp(0.0, 1.0);
}

/// value noise（用于纸张纹理），种子固定。
double _hash(int x, int y) {
  int h = x * 374761393 + y * 668265263 + (_kPaperSeed * 1000).toInt();
  h = (h ^ (h >> 13)) * 1274126177;
  h = h ^ (h >> 16);
  return (h & 0xFFFF) / 65535.0;
}

double _valueNoise(double x, double y) {
  final int xi = x.floor();
  final int yi = y.floor();
  final double fx = x - xi;
  final double fy = y - yi;
  final double ux = fx * fx * (3 - 2 * fx);
  final double uy = fy * fy * (3 - 2 * fy);
  final double a = _hash(xi, yi);
  final double b = _hash(xi + 1, yi);
  final double c = _hash(xi, yi + 1);
  final double d = _hash(xi + 1, yi + 1);
  return _mixD(_mixD(a, b, ux), _mixD(c, d, ux), uy);
}

double _fbm(double x, double y, int octaves) {
  double sum = 0;
  double amp = 0.5;
  double f = 1;
  for (int i = 0; i < octaves; i++) {
    sum += amp * _valueNoise(x * f, y * f);
    f *= 2.03;
    amp *= 0.5;
  }
  return sum;
}

/// 烘焙一张效果图，返回 RGBA8888（[NomandJob.width]×[NomandJob.height]）。
Uint8List nomandRender(NomandJob j) {
  switch (j.effect) {
    case NomandEffect.dithering:
      return _dithering(j);
    case NomandEffect.flutedGlass:
      return _flutedGlass(j);
    case NomandEffect.paperTexture:
      return _paperTexture(j);
    case NomandEffect.halftoneDots:
      return _halftone(j);
    case NomandEffect.lensDistortion:
      return _lens(j);
  }
}

void _put(Uint8List out, int i, double r, double g, double b) {
  out[i] = r.round().clamp(0, 255);
  out[i + 1] = g.round().clamp(0, 255);
  out[i + 2] = b.round().clamp(0, 255);
  out[i + 3] = 255;
}

/// 像素画（Paper `ImageDithering`）：按 [size] 逻辑像素分格，格心取色，有序抖动量化到
/// [colorSteps] 级；非原色时亮度映射到「底 → 前景 → 高光」。
Uint8List _dithering(NomandJob j) {
  final Uint8List out = Uint8List(j.width * j.height * 4);
  final _Sampler s = _Sampler(j, 1);
  final int n = switch (j.p(NomandBackgroundKeys.ditheringType, 8).round()) {
    2 => 2,
    4 => 4,
    _ => 8,
  };
  final double cell = math.max(
    1,
    j.p(NomandBackgroundKeys.size, 3) * j.pixelRatio,
  );
  final int steps = j.p(NomandBackgroundKeys.colorSteps, 4).round().clamp(1, 7);
  final bool original = j.p(NomandBackgroundKeys.originalColors, 0) > 0.5;
  final bool inverted = nomandDaylightInversion(
    j.p(NomandBackgroundKeys.inverted, 0) > 0.5,
    original,
    j.daylight,
  );
  final Float64List c = Float64List(3);
  final int cols = (j.width / cell).ceil();
  final int rows = (j.height / cell).ceil();
  for (int cy = 0; cy < rows; cy++) {
    for (int cx = 0; cx < cols; cx++) {
      final double thr = nomandBayer(n, cx, cy);
      double r;
      double g;
      double b;
      if (!s.sample((cx + 0.5) * cell, (cy + 0.5) * cell, c)) {
        r = _r(j.back).toDouble();
        g = _g(j.back).toDouble();
        b = _b(j.back).toDouble();
      } else if (original) {
        double ch(double v) {
          final double q = nomandQuantize(
            inverted ? 1 - v / 255 : v / 255,
            steps,
            thr,
          );
          return q * 255;
        }

        r = ch(c[0]);
        g = ch(c[1]);
        b = ch(c[2]);
      } else {
        double l = _lum(c);
        if (inverted) l = 1 - l;
        final double q = nomandQuantize(l, steps, thr);
        if (q >= 1 && steps > 1) {
          r = _r(j.highlight).toDouble();
          g = _g(j.highlight).toDouble();
          b = _b(j.highlight).toDouble();
        } else {
          final double k = steps > 1 ? q * steps / (steps - 1) : q;
          r = _mixD(
            _r(j.back).toDouble(),
            _r(j.front).toDouble(),
            k.clamp(0, 1),
          );
          g = _mixD(
            _g(j.back).toDouble(),
            _g(j.front).toDouble(),
            k.clamp(0, 1),
          );
          b = _mixD(
            _b(j.back).toDouble(),
            _b(j.front).toDouble(),
            k.clamp(0, 1),
          );
        }
      }
      final int x0 = (cx * cell).floor();
      final int y0 = (cy * cell).floor();
      final int x1 = math.min(j.width, ((cx + 1) * cell).floor());
      final int y1 = math.min(j.height, ((cy + 1) * cell).floor());
      for (int y = y0; y < y1; y++) {
        for (int x = x0; x < x1; x++) {
          _put(out, (y * j.width + x) * 4, r, g, b);
        }
      }
    }
  }
  return out;
}

/// 纹理玻璃（Paper `FlutedGlass`，竖条棱镜）：每条里横向错位取样 + 横向模糊，条右侧压阴影色、
/// 左缘提高光、条缝描暗边；图外露底色。
Uint8List _flutedGlass(NomandJob j) {
  final Uint8List out = Uint8List(j.width * j.height * 4);
  final _Sampler s = _Sampler(j, 1);
  final double period =
      (8 + j.p(NomandBackgroundKeys.flutedGlassSize, 0.5) * 120) * j.pixelRatio;
  final double distortion = j.p(
    NomandBackgroundKeys.flutedGlassDistortion,
    0.5,
  );
  final double blur = j.p(NomandBackgroundKeys.flutedGlassBlur, 0.08);
  const double shadows = 0.25;
  const double highlights = 0.1;
  const double edges = 0.25;
  final Float64List c = Float64List(3);
  const int taps = 5;
  for (int y = 0; y < j.height; y++) {
    for (int x = 0; x < j.width; x++) {
      final double f = (x / period) - (x / period).floorToDouble();
      // 棱镜：条内取样点向条心反向偏移（像透过斜面看过去）。
      final double shift = (f - 0.5) * period * distortion * 1.2;
      double r = 0;
      double g = 0;
      double b = 0;
      int hits = 0;
      for (int k = 0; k < taps; k++) {
        final double o = blur <= 0 ? 0 : (k / (taps - 1) - 0.5) * blur * period;
        if (s.sample(x - shift + o, y.toDouble(), c)) {
          r += c[0];
          g += c[1];
          b += c[2];
        } else {
          r += _r(j.back);
          g += _g(j.back);
          b += _b(j.back);
        }
        hits++;
        if (blur <= 0) break;
      }
      r /= hits;
      g /= hits;
      b /= hits;
      final double sh = shadows * lyricBgSmoothstep(0.55, 1, f);
      r = _mixD(r, r * _r(j.shadow) / 255, sh);
      g = _mixD(g, g * _g(j.shadow) / 255, sh);
      b = _mixD(b, b * _b(j.shadow) / 255, sh);
      final double hi = highlights * (1 - lyricBgSmoothstep(0, 0.18, f));
      r = _mixD(r, _r(j.highlight).toDouble(), hi);
      g = _mixD(g, _g(j.highlight).toDouble(), hi);
      b = _mixD(b, _b(j.highlight).toDouble(), hi);
      final double edge = edges * (1 - lyricBgSmoothstep(0, 0.035, f));
      r *= 1 - edge;
      g *= 1 - edge;
      b *= 1 - edge;
      _put(out, (y * j.width + x) * 4, r, g, b);
    }
  }
  return out;
}

/// 纸张纹理（Paper `PaperTexture`）：程序噪声拼出纸面高度（粗糙度 / 纤维 / 皱褶 / 折痕 / 水渍），
/// 法线推动图像取样（×0.02）、按光照明暗，再按对比度透出纸色（底 → 前景）。
Uint8List _paperTexture(NomandJob j) {
  final int w = j.width;
  final int h = j.height;
  final double roughness = j.p(
    NomandBackgroundKeys.paperTextureRoughness,
    0.42,
  );
  final double fiber = j.p(NomandBackgroundKeys.paperTextureFiber, 0.3);
  final double contrast = j.p(NomandBackgroundKeys.paperTextureContrast, 0.32);
  final _Sampler s = _Sampler(j, nomandPaperOverscan(roughness, fiber));
  final double unit = math.min(w, h).toDouble();
  final math.Random fold = math.Random(_kPaperSeed.toInt());
  final List<({double nx, double ny, double d})> folds =
      <({double nx, double ny, double d})>[
        for (int i = 0; i < _kPaperFoldCount; i++)
          () {
            final double a = fold.nextDouble() * math.pi;
            return (
              nx: math.cos(a),
              ny: math.sin(a),
              d: (fold.nextDouble() - 0.5) * 1.2,
            );
          }(),
      ];
  final Float32List height = Float32List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double u = (x - w / 2) / unit;
      final double v = (y - h / 2) / unit;
      double hgt = roughness * 0.75 * _fbm(u * 60, v * 60, 3);
      hgt += fiber * 0.1 * _valueNoise(u * 400, v * 25);
      hgt +=
          _kPaperCrumples *
          1.5 *
          (1 - (_fbm(u * 6, v * 6, 3) * 2 - 1).abs()) *
          0.35;
      for (final ({double nx, double ny, double d}) f in folds) {
        final double dist = (u * f.nx + v * f.ny - f.d).abs();
        hgt += _kPaperFolds * 2 * math.exp(-dist * dist * 900) * 0.25;
      }
      hgt +=
          _kPaperDrops *
          0.2 *
          lyricBgSmoothstep(0.78, 0.8, _valueNoise(u * 9, v * 9));
      height[y * w + x] = hgt;
    }
  }
  final Uint8List out = Uint8List(w * h * 4);
  final Float64List c = Float64List(3);
  // 法线幅度按逻辑像素尺度取差分。
  final double k = 4 * j.pixelRatio;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double hl = height[y * w + math.max(0, x - 1)];
      final double hr = height[y * w + math.min(w - 1, x + 1)];
      final double hu = height[math.max(0, y - 1) * w + x];
      final double hd = height[math.min(h - 1, y + 1) * w + x];
      final double nx = (hr - hl) * k;
      final double ny = (hd - hu) * k;
      double r;
      double g;
      double b;
      if (s.sample(x + 0.02 * nx * unit, y + 0.02 * ny * unit, c)) {
        r = c[0];
        g = c[1];
        b = c[2];
      } else {
        r = _r(j.back).toDouble();
        g = _g(j.back).toDouble();
        b = _b(j.back).toDouble();
      }
      final double light = (-nx * 0.6 - ny * 0.8).clamp(-1.0, 1.0);
      final double shade = 1 + light * (0.35 + contrast * 0.9);
      r *= shade;
      g *= shade;
      b *= shade;
      final double paperT = height[y * w + x].clamp(0.0, 1.0);
      final double pr = _mixD(
        _r(j.back).toDouble(),
        _r(j.front).toDouble(),
        paperT,
      );
      final double pg = _mixD(
        _g(j.back).toDouble(),
        _g(j.front).toDouble(),
        paperT,
      );
      final double pb = _mixD(
        _b(j.back).toDouble(),
        _b(j.front).toDouble(),
        paperT,
      );
      final double tint = contrast * 0.35;
      _put(
        out,
        (y * w + x) * 4,
        _mixD(r, pr, tint),
        _mixD(g, pg, tint),
        _mixD(b, pb, tint),
      );
    }
  }
  return out;
}

double _smin(double a, double b, double k) {
  final double h = (0.5 + 0.5 * (b - a) / k).clamp(0.0, 1.0);
  return _mixD(b, a, h) - k * h * (1 - h);
}

/// 半调网点（Paper `HalftoneDots`，六角网格、gooey 粘连）：每个网点按格心亮度定半径，
/// 相邻网点用平滑并集粘起来；底色 / 前景色（或图片原色），叠一点颗粒。
Uint8List _halftone(NomandJob j) {
  final int w = j.width;
  final int h = j.height;
  final Uint8List out = Uint8List(w * h * 4);
  final _Sampler s = _Sampler(j, 1);
  final double cell =
      (4 + j.p(NomandBackgroundKeys.halftoneDotsSize, 0.5) * 44) * j.pixelRatio;
  final double radius = j.p(NomandBackgroundKeys.halftoneDotsRadius, 1.25);
  final double contrast = j.p(NomandBackgroundKeys.halftoneDotsContrast, 0.4);
  final bool original =
      j.p(NomandBackgroundKeys.halftoneDotsOriginalColors, 0) > 0.5;
  final bool inverted = nomandHalftoneInversion(
    j.p(NomandBackgroundKeys.halftoneDotsInverted, 0) > 0.5,
    original,
    j.daylight,
  );
  final double rowH = cell * math.sqrt(3) / 2;
  final int rows = (h / rowH).ceil() + 2;
  final int cols = (w / cell).ceil() + 2;
  // 先算每个网点的半径与颜色。
  final Float32List radii = Float32List(rows * cols);
  final Int32List colors = Int32List(rows * cols);
  final Float64List c = Float64List(3);
  for (int ry = 0; ry < rows; ry++) {
    for (int rx = 0; rx < cols; rx++) {
      final double cx = (rx - 1) * cell + (ry.isOdd ? cell / 2 : 0);
      final double cy = (ry - 1) * rowH;
      double l = 0;
      int col = j.front;
      if (s.sample(cx, cy, c)) {
        l = _lum(c);
        if (original) {
          col =
              0xFF000000 |
              (c[0].round().clamp(0, 255) << 16) |
              (c[1].round().clamp(0, 255) << 8) |
              c[2].round().clamp(0, 255);
        }
      }
      l = ((l - 0.5) * (1 + contrast * 2) + 0.5).clamp(0.0, 1.0);
      if (inverted) l = 1 - l;
      radii[ry * cols + rx] = (1 - l) * 0.5 * cell * radius;
      colors[ry * cols + rx] = col;
    }
  }
  final double goo = cell * 0.22;
  for (int y = 0; y < h; y++) {
    final int ry0 = (y / rowH).floor() + 1;
    for (int x = 0; x < w; x++) {
      double d = 1e9;
      double best = 1e9;
      int bestColor = j.front;
      for (int ry = ry0 - 1; ry <= ry0 + 1; ry++) {
        if (ry < 0 || ry >= rows) continue;
        final double off = ry.isOdd ? cell / 2 : 0;
        final int rx0 = ((x - off) / cell).floor() + 1;
        for (int rx = rx0 - 1; rx <= rx0 + 1; rx++) {
          if (rx < 0 || rx >= cols) continue;
          final double r = radii[ry * cols + rx];
          if (r <= 0.01) continue;
          final double dx = x - ((rx - 1) * cell + off);
          final double dy = y - (ry - 1) * rowH;
          final double sd = math.sqrt(dx * dx + dy * dy) - r;
          d = d >= 1e8 ? sd : _smin(d, sd, goo);
          if (sd < best) {
            best = sd;
            bestColor = colors[ry * cols + rx];
          }
        }
      }
      final double cover = 1 - lyricBgSmoothstep(-0.75, 0.75, d);
      final double grain = (_hash(x, y) - 0.5) * 0.12 * 255 * 0.5;
      _put(
        out,
        (y * w + x) * 4,
        _mixD(_r(j.back).toDouble(), _r(bestColor).toDouble(), cover) + grain,
        _mixD(_g(j.back).toDouble(), _g(bestColor).toDouble(), cover) + grain,
        _mixD(_b(j.back).toDouble(), _b(bestColor).toDouble(), cover) + grain,
      );
    }
  }
  return out;
}

/// 镜头畸变（Paper `LensDistortion`）：以内切圆归一的半径做 tan 膨胀（bulge > 0）或向内收
/// （bulge < 0），带一点旋涡；越靠边色彩分离（spread）越强，色散（dispersion）把 R / G / B 三次
/// 取样扩成更连续的多次取样；预放大由 [nomandLensOverscan] 保证四角不露底。
Uint8List _lens(NomandJob j) {
  final int w = j.width;
  final int h = j.height;
  final Uint8List out = Uint8List(w * h * 4);
  final double bulge = j.p(NomandBackgroundKeys.lensDistortionBulge, 0.3);
  final double spread = j.p(NomandBackgroundKeys.lensDistortionSpread, 0.45);
  final double dispersion = j.p(
    NomandBackgroundKeys.lensDistortionDispersion,
    0.65,
  );
  final _Sampler s = _Sampler(j, nomandLensOverscan(bulge, spread));
  final double cx = w / 2;
  final double cy = h / 2;
  final double inr = math.min(w, h) / 2;
  final double amount = math.min(bulge.abs(), 1) * 1.4;
  final double sp = spread.clamp(0.0, 1.0);
  final double reach = 0.7 * math.pow(sp, 1.3 + 2.7 * sp);
  final Float64List c = Float64List(3);
  final int taps = 3 + (dispersion * 4).round() * 2;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double dx = (x - cx) / inr;
      final double dy = (y - cy) / inr;
      final double rn = math.sqrt(dx * dx + dy * dy);
      double scale = 1;
      if (rn > 1e-6 && amount > 1e-6) {
        if (bulge > 0) {
          final double a = math.min(rn * amount, 1.45);
          scale = math.tan(a) / math.tan(amount) / rn;
        } else {
          scale = 1 + bulge * 0.3 * rn;
        }
      }
      final double ang = _kLensSwirl * rn;
      final double cs = math.cos(ang);
      final double sn = math.sin(ang);
      final double ux = (cs * dx - sn * dy) * scale;
      final double uy = (sn * dx + cs * dy) * scale;
      // 焦点：中心区域（focusCenter）几乎不分离，边缘按 focusEdges 保留残量。
      final double edgeW =
          lyricBgSmoothstep(_kLensFocusCenter * 0.5, 1.2, rn) *
          (1 - _kLensFocusEdges * lyricBgSmoothstep(1.2, 2, rn));
      final double k = reach * 0.12 * edgeW;
      double r = 0;
      double g = 0;
      double b = 0;
      double wr = 0;
      double wg = 0;
      double wb = 0;
      for (int i = 0; i < taps; i++) {
        final double tt = taps == 1 ? 0 : i / (taps - 1) * 2 - 1;
        final double m = 1 + k * tt;
        if (!s.sample(cx + ux * m * inr, cy + uy * m * inr, c)) {
          c[0] = _r(j.back).toDouble();
          c[1] = _g(j.back).toDouble();
          c[2] = _b(j.back).toDouble();
        }
        // 光谱权重：-1 偏红、0 偏绿、+1 偏蓝。
        final double cr = math.max(0, 1 - (tt + 1).abs());
        final double cg = math.max(0, 1 - tt.abs());
        final double cb = math.max(0, 1 - (tt - 1).abs());
        r += c[0] * cr;
        g += c[1] * cg;
        b += c[2] * cb;
        wr += cr;
        wg += cg;
        wb += cb;
      }
      double fade = 1;
      if (bulge > 0 && rn * amount >= 1.45) {
        fade = 1 - lyricBgSmoothstep(1.45, 1.6, rn * amount);
      }
      _put(
        out,
        (y * w + x) * 4,
        _mixD(_r(j.back).toDouble(), r / math.max(wr, 1e-6), fade),
        _mixD(_g(j.back).toDouble(), g / math.max(wg, 1e-6), fade),
        _mixD(_b(j.back).toDouble(), b / math.max(wb, 1e-6), fade),
      );
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// 场景
// ---------------------------------------------------------------------------

/// 烘焙尺寸上限（像素数，folia `maxPixelCount: 1920 * 1080`）。
const int _kMaxBakePixels = 1920 * 1080;

/// 源图缩到的最长边（效果都不需要更细的源）。
const int _kSourceMaxSide = 1024;

/// 拖滑杆时的防抖（秒）。
const double _kDebounceSeconds = 0.18;

/// 当前参数 → [NomandJob.params]（只带数字；布尔记成 0 / 1，选项记成数字）。
Map<String, double> nomandParamsOf(LyricVisualizerTuning tu) {
  final Map<String, Object> m = tu.toMap();
  return <String, double>{
    for (final MapEntry<String, Object> e in m.entries)
      if (e.value is double)
        e.key: e.value as double
      else if (e.value is bool)
        e.key: (e.value as bool) ? 1 : 0,
    NomandBackgroundKeys.ditheringType: double.parse(
      tu.choice(NomandBackgroundKeys.ditheringType, '8x8').split('x').first,
    ),
  };
}

class NomandBackgroundScene extends LyricVisualizerBackgroundScene {
  NomandBackgroundScene() {
    _source.addListener(_onSource);
  }

  final LyricBgImageSource _source = LyricBgImageSource();
  late LyricVisualizerContext _c;
  late LyricVisualizerTuning _tu;
  double _dpr = 1;
  Size _size = Size.zero;
  ui.Image? _baked;
  Object? _bakedKey;
  int _generation = 0;
  bool _pending = false;
  double _pendingSince = 0;
  double _wall = 0;
  bool _disposed = false;
  bool _configured = false;

  void _onSource() => _request(immediate: true);

  @override
  void configure(
    LyricVisualizerContext context,
    LyricVisualizerTuning tuning,
    double devicePixelRatio,
  ) {
    _c = context;
    _tu = tuning;
    _dpr = devicePixelRatio;
    _configured = true;
    final bool uploaded =
        tuning.choice(NomandBackgroundKeys.imageSource, kLyricBgSourceCover) ==
        kLyricBgSourceUploaded;
    _source.select(
      coverPath: context.coverPath,
      pack: uploaded
          ? tuning.assetPack(NomandBackgroundKeys.imagePack, 'default')
          : null,
      preferPack: uploaded,
    );
    _request(immediate: false);
  }

  /// 烘焙尺寸（设备像素，限制总像素数；按 32 取整，窗口微调不重烘）。
  ({int w, int h, double ratio}) _bakeSize() {
    double w = _size.width * _dpr;
    double h = _size.height * _dpr;
    final double k = math.min(
      1,
      math.sqrt(_kMaxBakePixels / math.max(1, w * h)),
    );
    w = (w * k / 32).ceilToDouble() * 32;
    h = (h * k / 32).ceilToDouble() * 32;
    return (
      w: math.max(32, w.toInt()),
      h: math.max(32, h.toInt()),
      ratio: _dpr * k,
    );
  }

  Object? get _key {
    final ui.Image? img = _source.image;
    if (img == null || _size.isEmpty) return null;
    final ({int w, int h, double ratio}) b = _bakeSize();
    return Object.hash(identityHashCode(img), _c.palette, _tu, b.w, b.h);
  }

  void _request({required bool immediate}) {
    if (!_configured) return;
    final Object? key = _key;
    if (key == _bakedKey) {
      _pending = false;
      return;
    }
    if (immediate || _baked == null || !_c.motion) {
      _bake();
    } else if (!_pending) {
      _pending = true;
      _pendingSince = _wall;
    }
  }

  void _bake() {
    _pending = false;
    final Object? key = _key;
    _bakedKey = key;
    final int gen = ++_generation;
    final ui.Image? img = _source.image;
    if (key == null || img == null) {
      _baked?.dispose();
      _baked = null;
      notifyListeners();
      return;
    }
    final ui.Image src = img.clone();
    final ({int w, int h, double ratio}) size = _bakeSize();
    final LyricVisualizerPalette p = _c.palette;
    final NomandEffect effect = NomandEffect.of(
      _tu.choice(NomandBackgroundKeys.effect, 'dithering'),
    );
    final Map<String, double> params = nomandParamsOf(_tu);
    unawaited(
      bakeNomandBackground(
            src,
            width: size.w,
            height: size.h,
            pixelRatio: size.ratio,
            effect: effect,
            params: params,
            palette: p,
          )
          .then<void>(
            (ui.Image baked) {
              if (_disposed || gen != _generation) {
                baked.dispose();
                return;
              }
              _baked?.dispose();
              _baked = baked;
              notifyListeners();
            },
            onError: (Object _) {
              // 坏图：留着上一张。
            },
          )
          .whenComplete(src.dispose),
    );
  }

  @override
  void advance(LyricVisualizerTick tick) {
    _wall += tick.dt;
    if (_pending && _wall - _pendingSince >= _kDebounceSeconds) _bake();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size != _size) {
      _size = size;
      // 尺寸在 paint 里才知道：烘焙推到下一个微任务，别在绘制中通知。
      scheduleMicrotask(() {
        if (!_disposed) _request(immediate: false);
      });
    }
    final Rect all = Offset.zero & size;
    canvas.drawRect(all, Paint()..color = _c.palette.background);
    final ui.Image? img = _baked;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        lyricBgCoverRect(
          Size(img.width.toDouble(), img.height.toDouble()),
          all,
        ),
        Paint()..filterQuality = FilterQuality.medium,
      );
    }
    if (_tu.flag(NomandBackgroundKeys.overlayEnabled, true)) {
      final double o = _tu.number(NomandBackgroundKeys.overlayOpacity, 0.35);
      if (o > 0) {
        canvas.drawRect(
          all,
          Paint()..color = _c.palette.background.withValues(alpha: o),
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _source.removeListener(_onSource);
    _source.dispose();
    _baked?.dispose();
    super.dispose();
  }
}

Future<Uint8List> _renderInIsolate(NomandJob job) =>
    Isolate.run(() => nomandRender(job));

/// 源图 → 后台逐像素效果 → `ui.Image`。[source] 归调用方。
Future<ui.Image> bakeNomandBackground(
  ui.Image source, {
  required int width,
  required int height,
  required double pixelRatio,
  required NomandEffect effect,
  required Map<String, double> params,
  required LyricVisualizerPalette palette,
}) async {
  final double k = math.min(
    1,
    _kSourceMaxSide / math.max(source.width, source.height),
  );
  final int sw = math.max(1, (source.width * k).round());
  final int sh = math.max(1, (source.height * k).round());
  final ui.PictureRecorder rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(0, 0, sw.toDouble(), sh.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final ui.Picture picture = rec.endRecording();
  final ui.Image small = await picture.toImage(sw, sh);
  picture.dispose();
  final ByteData? raw;
  try {
    raw = await small.toByteData();
  } finally {
    small.dispose();
  }
  if (raw == null) throw StateError('nomand: no pixels');
  final NomandJob job = NomandJob(
    source: raw.buffer.asUint8List(),
    sourceWidth: sw,
    sourceHeight: sh,
    width: width,
    height: height,
    pixelRatio: pixelRatio,
    effect: effect,
    params: params,
    back: palette.background.toARGB32(),
    front: palette.accent.toARGB32(),
    highlight: palette.primary.toARGB32(),
    shadow: palette.secondary.toARGB32(),
    daylight: palette.brightness == Brightness.light,
  );
  final Uint8List pixels = await _renderInIsolate(job);
  final Completer<ui.Image> done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    width,
    height,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}
