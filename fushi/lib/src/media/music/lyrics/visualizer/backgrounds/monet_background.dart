/// 背景「莫奈」（移植 folia `backgrounds/monet/`：`MonetBackgroundLayer.tsx`、`monetBackgroundDrift.ts`、
/// `tuning.ts`，以及 `monet/monetBackgroundPaint.ts`）：封面（或用户自定义图）裁满、去色 / 饱和度 /
/// 水洗重着色逐像素处理（后台 isolate）、模糊 + 主题叠色 + 竖向纹理烘焙成一张图；画面上按
/// 「全屏叠色 / 半屏渐变」铺开，用周期分形噪声缓慢漂移，换图时淡入。
///
/// 莫奈样式（`modes/monet/`）请求的就是这个背景；其他样式也能选它。
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
// 参数（folia `DEFAULT_MONET_BACKGROUND_TUNING`；键名沿用 folia 字段名，落库冻结）
// ---------------------------------------------------------------------------

/// 背景 id（冻结）。
const String kMonetBackgroundId = 'monet';

abstract final class MonetBackgroundKeys {
  static const String backgroundSource = 'backgroundSource';
  static const String imagePack = 'imagePack';
  static const String backgroundLayout = 'backgroundLayout';
  static const String backgroundBlurPx = 'backgroundBlurPx';
  static const String backgroundOverlayOpacity = 'backgroundOverlayOpacity';
  static const String backgroundGrayscale = 'backgroundGrayscale';
  static const String backgroundSaturation = 'backgroundSaturation';
  static const String backgroundWash = 'backgroundWash';
  static const String backgroundWashColorMode = 'backgroundWashColorMode';
  static const String backgroundWashCustomColor = 'backgroundWashCustomColor';
  static const String backgroundHalfPaneOffsetX = 'backgroundHalfPaneOffsetX';
  static const String backgroundDriftEnabled = 'backgroundDriftEnabled';
  static const String backgroundDriftStrength = 'backgroundDriftStrength';
  static const String backgroundStreaksEnabled = 'backgroundStreaksEnabled';
}

String _percent(double v) => '${(v * 100).round()}%';
String _px(double v) => '${v.round()} px';

bool _isHalfPane(LyricVisualizerTuning v) =>
    v.choice(MonetBackgroundKeys.backgroundLayout, 'full-overlay') ==
    'half-pane-gradient';

final List<LyricVisualizerTuningSpec> monetBackgroundTunings =
    <LyricVisualizerTuningSpec>[
      lyricBgImageSourceSpec(MonetBackgroundKeys.backgroundSource),
      lyricBgImagePackSpec(
        MonetBackgroundKeys.imagePack,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.choice(MonetBackgroundKeys.backgroundSource, '') ==
            kLyricBgSourceUploaded,
      ),
      LyricVisualizerChoiceSpec(
        key: MonetBackgroundKeys.backgroundLayout,
        label: () => t.music_visualizer_monet_background_layout,
        options: <(String, String Function())>[
          ('full-overlay', () => t.music_visualizer_monet_layout_full),
          ('half-pane-gradient', () => t.music_visualizer_monet_layout_half),
        ],
        initial: 'full-overlay',
      ),
      LyricVisualizerSliderSpec(
        key: MonetBackgroundKeys.backgroundHalfPaneOffsetX,
        label: () => t.music_visualizer_monet_background_offset,
        min: -40,
        max: 40,
        initial: 0,
        divisions: 40,
        format: (double v) => '${v.round()}%',
        visibleWhen: _isHalfPane,
      ),
      LyricVisualizerToggleSpec(
        key: MonetBackgroundKeys.backgroundDriftEnabled,
        label: () => t.music_visualizer_monet_background_drift,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: MonetBackgroundKeys.backgroundDriftStrength,
        label: () => t.music_visualizer_monet_background_drift_strength,
        min: 0,
        max: 1,
        initial: 0.5,
        divisions: 20,
        format: _percent,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.flag(MonetBackgroundKeys.backgroundDriftEnabled, true),
      ),
      LyricVisualizerSliderSpec(
        key: MonetBackgroundKeys.backgroundBlurPx,
        label: () => t.music_visualizer_monet_background_blur,
        min: 0,
        max: 60,
        initial: 6,
        divisions: 30,
        format: _px,
      ),
      LyricVisualizerSliderSpec(
        key: MonetBackgroundKeys.backgroundSaturation,
        label: () => t.music_visualizer_monet_background_saturation,
        min: 0,
        max: 2,
        initial: 1.05,
        divisions: 40,
        format: _percent,
      ),
      LyricVisualizerSliderSpec(
        key: MonetBackgroundKeys.backgroundGrayscale,
        label: () => t.music_visualizer_monet_background_grayscale,
        min: 0,
        max: 1,
        initial: 0,
        divisions: 50,
        format: _percent,
      ),
      LyricVisualizerSliderSpec(
        key: MonetBackgroundKeys.backgroundOverlayOpacity,
        label: () => t.music_visualizer_monet_background_overlay,
        min: 0,
        max: 1,
        initial: 0.74,
        divisions: 50,
        format: _percent,
      ),
      LyricVisualizerSliderSpec(
        key: MonetBackgroundKeys.backgroundWash,
        label: () => t.music_visualizer_monet_background_wash,
        min: 0,
        max: 1,
        initial: 0.34,
        divisions: 50,
        format: _percent,
      ),
      LyricVisualizerToggleSpec(
        key: MonetBackgroundKeys.backgroundStreaksEnabled,
        label: () => t.music_visualizer_monet_background_streaks,
        initial: true,
      ),
      LyricVisualizerChoiceSpec(
        key: MonetBackgroundKeys.backgroundWashColorMode,
        label: () => t.music_visualizer_background_monet_wash_mode,
        options: <(String, String Function())>[
          ('theme', () => t.music_visualizer_background_monet_wash_theme),
          ('custom', () => t.music_visualizer_background_monet_wash_custom),
        ],
        initial: 'theme',
      ),
      LyricVisualizerColorSpec(
        key: MonetBackgroundKeys.backgroundWashCustomColor,
        label: () => t.music_visualizer_background_monet_wash_custom_color,
        initial: const Color(0xFF8FB7FF),
        visibleWhen: (LyricVisualizerTuning v) =>
            v.choice(MonetBackgroundKeys.backgroundWashColorMode, 'theme') ==
            'custom',
      ),
    ];

/// 注册项。
final LyricVisualizerBackgroundEntry monetBackgroundEntry =
    LyricVisualizerBackgroundEntry(
      id: kMonetBackgroundId,
      label: () => t.music_visualizer_background_monet,
      icon: FushiIcons.image,
      tunings: monetBackgroundTunings,
      builder: (LyricVisualizerContext c, LyricVisualizerTuning tu) =>
          LyricVisualizerBackgroundView(
            context: c,
            tuning: tu,
            create: MonetBackgroundScene.new,
          ),
    );

/// 封面后处理（会触发重新烘焙背景图的那几项）。
@immutable
class MonetBackgroundTreatment {
  const MonetBackgroundTreatment({
    required this.blurPx,
    required this.overlay,
    required this.grayscale,
    required this.saturation,
    required this.wash,
    required this.streaks,
    this.washColor,
  });

  final double blurPx;
  final double overlay;
  final double grayscale;
  final double saturation;
  final double wash;
  final bool streaks;

  /// 自定义水洗色（folia `backgroundWashColorMode: 'custom'`）；null = 用主题强调色。
  final Color? washColor;

  @override
  bool operator ==(Object other) =>
      other is MonetBackgroundTreatment &&
      other.blurPx == blurPx &&
      other.overlay == overlay &&
      other.grayscale == grayscale &&
      other.saturation == saturation &&
      other.wash == wash &&
      other.streaks == streaks &&
      other.washColor == washColor;

  @override
  int get hashCode => Object.hash(
    blurPx,
    overlay,
    grayscale,
    saturation,
    wash,
    streaks,
    washColor,
  );
}

/// 读出来的整套背景参数。
class MonetBackgroundConfig {
  MonetBackgroundConfig.from(LyricVisualizerTuning tu)
    : uploaded =
          tu.choice(
            MonetBackgroundKeys.backgroundSource,
            kLyricBgSourceCover,
          ) ==
          kLyricBgSourceUploaded,
      imagePack = tu.assetPack(MonetBackgroundKeys.imagePack, 'default'),
      halfPane = _isHalfPane(tu),
      halfPaneOffsetX = tu.number(
        MonetBackgroundKeys.backgroundHalfPaneOffsetX,
        0,
      ),
      driftEnabled = tu.flag(MonetBackgroundKeys.backgroundDriftEnabled, true),
      driftStrength = tu.number(
        MonetBackgroundKeys.backgroundDriftStrength,
        0.5,
      ),
      treatment = MonetBackgroundTreatment(
        blurPx: tu.number(MonetBackgroundKeys.backgroundBlurPx, 6),
        overlay: tu.number(MonetBackgroundKeys.backgroundOverlayOpacity, 0.74),
        grayscale: tu.number(MonetBackgroundKeys.backgroundGrayscale, 0),
        saturation: tu.number(MonetBackgroundKeys.backgroundSaturation, 1.05),
        wash: tu.number(MonetBackgroundKeys.backgroundWash, 0.34),
        streaks: tu.flag(MonetBackgroundKeys.backgroundStreaksEnabled, true),
        washColor:
            tu.choice(MonetBackgroundKeys.backgroundWashColorMode, 'theme') ==
                'custom'
            ? tu.color(
                MonetBackgroundKeys.backgroundWashCustomColor,
                const Color(0xFF8FB7FF),
              )
            : null,
      );

  final bool uploaded;
  final String imagePack;
  final bool halfPane;
  final double halfPaneOffsetX;
  final bool driftEnabled;
  final double driftStrength;
  final MonetBackgroundTreatment treatment;
}

// ---------------------------------------------------------------------------
// 纯算法：水洗重着色
// ---------------------------------------------------------------------------

/// 8 位 RGB。
typedef MonetRgb = ({double r, double g, double b});

double _lum(MonetRgb c) => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;

double _mix(double a, double b, double t) => a + (b - a) * t;

MonetRgb monetRgbOf(Color c) => (r: c.r * 255, g: c.g * 255, b: c.b * 255);

/// 背景色与主色里暗的当阴影端、亮的当高光端（folia `resolveWashEndpoints`）。
({MonetRgb shadow, MonetRgb highlight}) monetWashEndpoints(
  MonetRgb background,
  MonetRgb primary,
) => _lum(background) <= _lum(primary)
    ? (shadow: background, highlight: primary)
    : (shadow: primary, highlight: background);

/// 按亮度把像素映射到「阴影 → 强调色 → 高光」三段渐变（folia `resolveWashColor`）。
MonetRgb monetWashColor(
  double normalizedLuminance,
  MonetRgb background,
  MonetRgb accent,
  MonetRgb primary,
) {
  final ({MonetRgb shadow, MonetRgb highlight}) e = monetWashEndpoints(
    background,
    primary,
  );
  if (normalizedLuminance <= 0.55) {
    final double t = normalizedLuminance / 0.55;
    return (
      r: _mix(e.shadow.r, accent.r, t),
      g: _mix(e.shadow.g, accent.g, t),
      b: _mix(e.shadow.b, accent.b, t),
    );
  }
  final double t = (normalizedLuminance - 0.55) / 0.45;
  return (
    r: _mix(accent.r, e.highlight.r, t),
    g: _mix(accent.g, e.highlight.g, t),
    b: _mix(accent.b, e.highlight.b, t),
  );
}

/// 一次逐像素处理的输入（跨 isolate 传）。
class MonetPixelJob {
  const MonetPixelJob({
    required this.pixels,
    required this.grayscale,
    required this.saturation,
    required this.wash,
    required this.background,
    required this.accent,
    required this.primary,
  });

  /// RGBA8888。
  final Uint8List pixels;
  final double grayscale;
  final double saturation;
  final double wash;
  final MonetRgb background;
  final MonetRgb accent;
  final MonetRgb primary;

  bool get isIdentity =>
      grayscale <= 0 && (saturation - 1).abs() < 0.001 && wash <= 0;
}

/// 去色 → 饱和度 → 水洗，原地改 [MonetPixelJob.pixels] 并返回（folia
/// `applyBackgroundPostProcessing`）。
Uint8List monetProcessPixels(MonetPixelJob job) {
  final Uint8List d = job.pixels;
  if (job.isIdentity) return d;
  final double gs = job.grayscale.clamp(0.0, 1.0);
  final double sat = job.saturation.clamp(0.0, 2.0);
  final double wash = job.wash.clamp(0.0, 1.0);
  final bool doSat = (sat - 1).abs() >= 0.001;
  for (int i = 0; i + 3 < d.length; i += 4) {
    if (d[i + 3] == 0) continue;
    double r = d[i].toDouble();
    double g = d[i + 1].toDouble();
    double b = d[i + 2].toDouble();
    final double l = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    if (gs > 0) {
      r = _mix(r, l, gs);
      g = _mix(g, l, gs);
      b = _mix(b, l, gs);
    }
    if (doSat) {
      final double sl = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      r = sl + (r - sl) * sat;
      g = sl + (g - sl) * sat;
      b = sl + (b - sl) * sat;
    }
    if (wash > 0) {
      final MonetRgb w = monetWashColor(
        (l / 255).clamp(0.0, 1.0),
        job.background,
        job.accent,
        job.primary,
      );
      r = _mix(r, w.r, wash);
      g = _mix(g, w.g, wash);
      b = _mix(b, w.b, wash);
    }
    d[i] = r.round().clamp(0, 255);
    d[i + 1] = g.round().clamp(0, 255);
    d[i + 2] = b.round().clamp(0, 255);
  }
  return d;
}

// ---------------------------------------------------------------------------
// 纯算法：漂移（AE wiggle 式周期分形噪声）
// ---------------------------------------------------------------------------

const double _kDriftLoopSeconds = 240;
const int _kDriftLatticePoints = 76;
const int _kDriftSampleCount = 156;
const double _kDriftMaxTravelPercent = 3.4;
const double _kDriftBreathAmplitude = 0.035;
const double _kDriftOverscanMargin = 0.01;
const double _kSeedX = 12.9898;
const double _kSeedY = 78.233;
const double _kSeedScale = 39.425;

double _wrap(int v, int m) => ((v % m) + m) % m * 1.0;

double _hash(double lattice, double seed) {
  final double v = math.sin(lattice * 127.1 + seed * 311.7) * 43758.5453;
  return v - v.floorToDouble();
}

double _periodicNoise(double t, int points, double seed) {
  final int cell = t.floor();
  final double a = _hash(_wrap(cell, points), seed);
  final double b = _hash(_wrap(cell + 1, points), seed);
  final double f = t - cell;
  return a + (b - a) * (f * f * (3 - 2 * f));
}

double _periodicFbm(double t, double seed) {
  final double base = _periodicNoise(t, _kDriftLatticePoints, seed);
  final double detail = _periodicNoise(
    t * 2,
    _kDriftLatticePoints * 2,
    seed + 17.31,
  );
  return (base * 0.68 + detail * 0.32) * 2 - 1;
}

double _peakOf(double seed) {
  double peak = 0;
  for (int i = 0; i <= _kDriftSampleCount; i++) {
    final double t = _kDriftLatticePoints * i / _kDriftSampleCount;
    peak = math.max(peak, _periodicFbm(t, seed).abs());
  }
  return peak <= 0 ? 1 : peak;
}

final double _peakX = _peakOf(_kSeedX);
final double _peakY = _peakOf(_kSeedY);
final double _peakScale = _peakOf(_kSeedScale);

/// 漂移的一帧：平移（占自身盒子的百分比）与缩放。
typedef MonetDrift = ({double txPercent, double tyPercent, double scale});

/// folia `buildMonetDriftTrack` 的连续版：240 秒一圈，三条通道各自归一到 ±1，
/// 预先放大到超过两倍最大平移，平移时不会露边。
MonetDrift monetDriftAt(double seconds, double strength) {
  final double s = strength.clamp(0.0, 1.0);
  final double travel = _kDriftMaxTravelPercent * s;
  final double minScale = 1 + travel / 100 * 2 + _kDriftOverscanMargin;
  final double breath = _kDriftBreathAmplitude * s;
  final double lap = (seconds / _kDriftLoopSeconds) % 1;
  final double t = lap * _kDriftLatticePoints;
  final double x = (_periodicFbm(t, _kSeedX) / _peakX).clamp(-1.0, 1.0);
  final double y = (_periodicFbm(t, _kSeedY) / _peakY).clamp(-1.0, 1.0);
  final double k = (_periodicFbm(t, _kSeedScale) / _peakScale).clamp(-1.0, 1.0);
  return (
    txPercent: x * travel,
    tyPercent: y * travel,
    scale: minScale + breath * ((k + 1) / 2),
  );
}

/// 静止时的缩放（关了漂移也照样不放大，原版只在漂移时预放大）。
const MonetDrift kMonetNoDrift = (txPercent: 0, tyPercent: 0, scale: 1);

// ---------------------------------------------------------------------------
// 烘焙
// ---------------------------------------------------------------------------

/// 烘焙尺寸（folia 1920×1080 画布的 2/3，模糊半径同比例缩）。
const double kMonetBakeWidth = 1280;
const double kMonetBakeHeight = 720;
const double _kBakeScale = kMonetBakeWidth / 1920;

/// 封面解码的最长边（反正要模糊，没必要原尺寸）。
const int _kDecodeMaxSide = 960;

Rect _coverRect(Size src, Rect dst, {double alignX = 0.5}) {
  final double scale = math.max(dst.width / src.width, dst.height / src.height);
  final double w = src.width * scale;
  final double h = src.height * scale;
  return Rect.fromLTWH(
    dst.left + (dst.width - w) * alignX,
    dst.top + (dst.height - h) / 2,
    w,
    h,
  );
}

/// 叠在处理过的封面上的主题色（folia `paintMonetOverlay`）。
void paintMonetOverlay(
  Canvas canvas,
  Size size,
  LyricVisualizerPalette p,
  MonetBackgroundTreatment tr,
) {
  final double w = size.width;
  final double h = size.height;
  final double o = tr.overlay.clamp(0.0, 1.0);
  final Rect all = Offset.zero & size;
  canvas.drawRect(
    all,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(w, h),
        <Color>[
          p.accent.withValues(alpha: 0.08 + o * 0.62),
          p.background.withValues(alpha: 0.16 + o * 0.58),
          p.text.withValues(alpha: 0.06 + o * 0.36),
        ],
        <double>[0, 0.44, 1],
      ),
  );
  canvas.drawRect(
    all,
    Paint()
      ..shader = ui.Gradient.radial(
        Offset(w * 0.18, h * 0.34),
        w * 0.55,
        <Color>[
          p.accent.withValues(alpha: o * 0.42),
          p.background.withValues(alpha: 0),
        ],
      ),
  );
  canvas.drawRect(
    all,
    Paint()
      ..shader = ui.Gradient.linear(Offset(w * 0.45, 0), Offset(w, 0), <Color>[
        p.background.withValues(alpha: 0),
        p.background.withValues(alpha: 0.18 + o * 0.38),
      ]),
  );
  if (!tr.streaks) return;
  final Paint streak = Paint()
    ..color = p.background.withValues(alpha: 0.1 + o * 0.08);
  final double k = w / 1920;
  for (int i = 0; i < 18; i++) {
    final double x = ((i * 127) % 1920) * k;
    final double y = (((i * 211) % 1080) - 40) * k;
    canvas.drawRect(Rect.fromLTWH(x, y, math.max(k, 0.5), h * 0.28), streak);
  }
}

Future<Uint8List> _processInIsolate(MonetPixelJob job) =>
    Isolate.run(() => monetProcessPixels(job));

Future<ui.Image> _imageFromPixels(Uint8List pixels, int w, int h) {
  final Completer<ui.Image> done = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    pixels,
    w,
    h,
    ui.PixelFormat.rgba8888,
    done.complete,
  );
  return done.future;
}

/// 读封面 → 后台逐像素处理 → 模糊 + 叠色烘焙成 [kMonetBakeWidth]×[kMonetBakeHeight] 的图。
/// 源图缩到最长边 [_kDecodeMaxSide]（反正要模糊，没必要原尺寸）。
Future<ui.Image> _downscale(ui.Image source) {
  final double k = math.min(
    1,
    _kDecodeMaxSide / math.max(source.width, source.height),
  );
  final int w = math.max(1, (source.width * k).round());
  final int h = math.max(1, (source.height * k).round());
  final ui.PictureRecorder rec = ui.PictureRecorder();
  Canvas(rec).drawImageRect(
    source,
    Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  final ui.Picture picture = rec.endRecording();
  return picture.toImage(w, h).whenComplete(picture.dispose);
}

/// 源图 → 后台逐像素处理 → 模糊 + 叠色烘焙成 [kMonetBakeWidth]×[kMonetBakeHeight] 的图。
/// [source] 归调用方（不在这里释放）。
Future<ui.Image> bakeMonetBackground(
  ui.Image source,
  LyricVisualizerPalette palette,
  MonetBackgroundTreatment tr,
) async {
  final ui.Image cover = await _downscale(source);
  ui.Image processed = cover;
  try {
    final MonetPixelJob probe = MonetPixelJob(
      pixels: Uint8List(0),
      grayscale: tr.grayscale,
      saturation: tr.saturation,
      wash: tr.wash,
      background: monetRgbOf(palette.background),
      accent: monetRgbOf(tr.washColor ?? palette.accent),
      primary: monetRgbOf(palette.text),
    );
    if (!probe.isIdentity) {
      final ByteData? raw = await cover.toByteData();
      if (raw != null) {
        final MonetPixelJob job = MonetPixelJob(
          pixels: raw.buffer.asUint8List(),
          grayscale: probe.grayscale,
          saturation: probe.saturation,
          wash: probe.wash,
          background: probe.background,
          accent: probe.accent,
          primary: probe.primary,
        );
        final Uint8List out = await _processInIsolate(job);
        processed = await _imageFromPixels(out, cover.width, cover.height);
      }
    }
    final ui.PictureRecorder rec = ui.PictureRecorder();
    const Size size = Size(kMonetBakeWidth, kMonetBakeHeight);
    final Canvas canvas = Canvas(rec, Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = palette.background);
    final double sigma = tr.blurPx.clamp(0.0, 60.0) * _kBakeScale;
    final Rect src = Rect.fromLTWH(
      0,
      0,
      processed.width.toDouble(),
      processed.height.toDouble(),
    );
    final Paint img = Paint()..filterQuality = FilterQuality.medium;
    if (sigma > 0.01) {
      img.imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.decal,
      );
    }
    canvas.drawImageRect(
      processed,
      src,
      _coverRect(src.size, Offset.zero & size),
      img,
    );
    paintMonetOverlay(canvas, size, palette, tr);
    final ui.Picture picture = rec.endRecording();
    try {
      return await picture.toImage(
        kMonetBakeWidth.toInt(),
        kMonetBakeHeight.toInt(),
      );
    } finally {
      picture.dispose();
    }
  } finally {
    if (!identical(processed, cover)) processed.dispose();
    cover.dispose();
  }
}

// ---------------------------------------------------------------------------
// 场景
// ---------------------------------------------------------------------------

/// 换图淡入时长（folia 0.8s easeInOut）。
const double _kFadeSeconds = 0.8;

/// 同一张图换主题 / 参数后等多久才重新烘焙（folia `PIPELINE_DEBOUNCE_MS`，拖滑杆不每步都烘）。
const double _kDebounceSeconds = 0.18;

class MonetBackgroundScene extends LyricVisualizerBackgroundScene {
  MonetBackgroundScene() {
    _source.addListener(_onSource);
  }

  final LyricBgImageSource _source = LyricBgImageSource();
  late LyricVisualizerContext _c;
  late MonetBackgroundConfig _config;
  ui.Image? _current;
  ui.Image? _previous;
  double _wall = 0;
  double _fadeStart = 0;
  double _driftTime = 0;
  int _generation = 0;
  Object? _bakedKey;
  bool _pending = false;
  double _pendingSince = 0;
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
    _config = MonetBackgroundConfig.from(tuning);
    _configured = true;
    _source.select(
      coverPath: context.coverPath,
      pack: _config.uploaded ? _config.imagePack : null,
      preferPack: _config.uploaded,
    );
    _request(immediate: false);
  }

  Object? get _key {
    final ui.Image? img = _source.image;
    if (img == null) return null;
    return Object.hash(identityHashCode(img), _c.palette, _config.treatment);
  }

  /// 新图（换歌 / 换来源）、第一张、或不在动（不会有下一帧来做防抖）时立刻烘；
  /// 同一张图换主题 / 参数时等 [_kDebounceSeconds]。
  void _request({required bool immediate}) {
    if (!_configured) return;
    if (_key == _bakedKey) {
      _pending = false;
      return;
    }
    if (immediate || _current == null || !_c.motion) {
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
      _swap(null);
      return;
    }
    // 源图归加载器，烘焙期间可能被换掉释放：克隆一份。
    final ui.Image src = img.clone();
    unawaited(
      bakeMonetBackground(src, _c.palette, _config.treatment)
          .then<void>(
            (ui.Image baked) {
              if (_disposed || gen != _generation) {
                baked.dispose();
                return;
              }
              _swap(baked);
            },
            onError: (Object _) {
              // 坏图：留着正在显示的那张（folia 同样吞掉解码失败）。
            },
          )
          .whenComplete(src.dispose),
    );
  }

  void _swap(ui.Image? next) {
    _previous?.dispose();
    // 第一张直接显示（folia firstPicture），之后的交叉淡入。
    _previous = _current;
    _current = next;
    _fadeStart = _wall;
    notifyListeners();
  }

  @override
  void advance(LyricVisualizerTick tick) {
    _wall += tick.dt;
    if (_c.motion) _driftTime += tick.dt;
    if (_pending && _wall - _pendingSince >= _kDebounceSeconds) _bake();
  }

  @override
  void paint(Canvas canvas, Size size) {
    double fade = 1;
    if (_c.motion && _previous != null) {
      fade = ((_wall - _fadeStart) / _kFadeSeconds).clamp(0.0, 1.0);
    }
    MonetBackgroundPainter(
      current: _current,
      previous: fade < 1 ? _previous : null,
      fade: Curves.easeInOut.transform(fade),
      palette: _c.palette,
      config: _config,
      drift: _c.motion && _config.driftEnabled
          ? monetDriftAt(_driftTime, _config.driftStrength)
          : kMonetNoDrift,
    ).paint(canvas, size);
  }

  @override
  void dispose() {
    _disposed = true;
    _source.removeListener(_onSource);
    _source.dispose();
    _current?.dispose();
    _previous?.dispose();
    super.dispose();
  }
}

/// 背景的逐帧绘制（只铺已烘焙好的图 + 渐变，便宜）。
class MonetBackgroundPainter extends CustomPainter {
  MonetBackgroundPainter({
    required this.current,
    required this.previous,
    required this.fade,
    required this.palette,
    required this.config,
    required this.drift,
  });

  final ui.Image? current;
  final ui.Image? previous;
  final double fade;
  final LyricVisualizerPalette palette;
  final MonetBackgroundConfig config;
  final MonetDrift drift;

  void _applyDrift(Canvas canvas, Rect box) {
    canvas.translate(
      box.width * drift.txPercent / 100,
      box.height * drift.tyPercent / 100,
    );
    final Offset c = box.center;
    canvas.translate(c.dx, c.dy);
    canvas.scale(drift.scale);
    canvas.translate(-c.dx, -c.dy);
  }

  void _drawImage(
    Canvas canvas,
    ui.Image img,
    Rect box,
    double opacity, {
    double alignX = 0.5,
  }) {
    if (opacity <= 0) return;
    final Rect src = Rect.fromLTWH(
      0,
      0,
      img.width.toDouble(),
      img.height.toDouble(),
    );
    canvas.drawImageRect(
      img,
      src,
      _coverRect(src.size, box, alignX: alignX),
      Paint()
        ..filterQuality = FilterQuality.medium
        ..color = Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0)),
    );
  }

  Shader _fallback(Rect r) => ui.Gradient.linear(
    r.topLeft,
    r.bottomRight,
    <Color>[
      palette.accent.withValues(alpha: 0.22),
      palette.background.withValues(alpha: 0.96),
      palette.text.withValues(alpha: 0.18),
    ],
    <double>[0, 0.5, 1],
  );

  Shader _readability(Rect r) => ui.Gradient.linear(
    r.centerLeft,
    r.centerRight,
    <Color>[
      palette.background.withValues(alpha: 0.18),
      palette.background.withValues(alpha: 0.32),
      palette.background.withValues(alpha: 0.66),
      palette.background.withValues(alpha: 0.82),
    ],
    <double>[0, 0.34, 0.7, 1],
  );

  @override
  void paint(Canvas canvas, Size size) {
    final Rect all = Offset.zero & size;
    canvas.drawRect(all, Paint()..color = palette.background);
    if (config.halfPane) {
      _paintHalfPane(canvas, size, all);
    } else {
      _paintFull(canvas, all);
    }
  }

  void _paintFull(Canvas canvas, Rect all) {
    canvas.save();
    canvas.clipRect(all);
    _applyDrift(canvas, all);
    if (current == null && previous == null) {
      canvas.drawRect(all, Paint()..shader = _fallback(all));
    } else {
      if (previous != null) _drawImage(canvas, previous!, all, 1);
      if (current != null) {
        _drawImage(canvas, current!, all, previous != null ? fade : 1);
      } else {
        canvas.drawRect(
          all,
          Paint()
            ..shader = _fallback(all)
            ..color = Color.fromRGBO(0, 0, 0, fade),
        );
      }
    }
    canvas.restore();
    canvas.drawRect(all, Paint()..shader = _readability(all));
  }

  void _paintHalfPane(Canvas canvas, Size size, Rect all) {
    canvas.drawRect(all, Paint()..shader = _fallback(all));
    final double w = size.width;
    final double paneFrac = w >= 1024
        ? 0.6
        : w >= 640
        ? 0.68
        : 0.72;
    final Rect pane = Rect.fromLTWH(0, 0, w * paneFrac, size.height);
    if (current != null || previous != null) {
      final bool daylight = palette.brightness == Brightness.light;
      final double imageOpacity =
          (daylight ? 0.7 : 0.3) +
          config.treatment.overlay.clamp(0.0, 1.0) * 0.16;
      final double alignX =
          (50 + config.halfPaneOffsetX).clamp(10.0, 90.0) / 100;
      canvas.saveLayer(pane, Paint());
      canvas.clipRect(pane);
      canvas.save();
      _applyDrift(canvas, pane);
      if (previous != null) {
        _drawImage(canvas, previous!, pane, imageOpacity, alignX: alignX);
      }
      if (current != null) {
        _drawImage(
          canvas,
          current!,
          pane,
          imageOpacity * (previous != null ? fade : 1),
          alignX: alignX,
        );
      }
      canvas.restore();
      canvas.drawRect(
        pane,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = ui.Gradient.linear(
            pane.centerLeft,
            pane.centerRight,
            const <Color>[
              Color(0xFF000000),
              Color.fromRGBO(0, 0, 0, 0.94),
              Color.fromRGBO(0, 0, 0, 0.46),
              Color(0x00000000),
            ],
            <double>[0, 0.48, 0.74, 1],
          ),
      );
      canvas.restore();
    }
    canvas.drawRect(
      all,
      Paint()
        ..shader = ui.Gradient.linear(
          all.centerLeft,
          all.centerRight,
          <Color>[
            palette.background.withValues(alpha: 0.14),
            palette.background.withValues(alpha: 0.28),
            palette.background.withValues(alpha: 0.62),
            palette.background.withValues(alpha: 0.86),
          ],
          <double>[0, 0.28, 0.64, 1],
        ),
    );
    // `radial-gradient(circle at 18% 34%, accent .18, transparent 36%)`：半径按到最远角的距离算。
    final Offset c = Offset(size.width * 0.18, size.height * 0.34);
    final double far = math.sqrt(
      math.pow(math.max(c.dx, size.width - c.dx), 2) +
          math.pow(math.max(c.dy, size.height - c.dy), 2),
    );
    canvas.drawRect(
      all,
      Paint()
        ..shader = ui.Gradient.radial(c, far * 0.36, <Color>[
          palette.accent.withValues(alpha: 0.18),
          palette.accent.withValues(alpha: 0),
        ]),
    );
    canvas.drawRect(all, Paint()..shader = _readability(all));
  }

  @override
  bool shouldRepaint(covariant MonetBackgroundPainter old) =>
      old.current != current ||
      old.previous != previous ||
      old.fade != fade ||
      old.palette != palette ||
      old.drift != drift ||
      old.config.halfPane != config.halfPane ||
      old.config.halfPaneOffsetX != config.halfPaneOffsetX ||
      old.config.treatment != config.treatment;
}
