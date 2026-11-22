/// 背景「隐现」（移植 folia `backgrounds/latent/`：`LatentBackground.tsx`、`tuning.ts`）：封面取色的
/// 流体渐变 + 有序抖动像素层（soft-light 叠合），速度、扭曲、旋涡、像素尺寸、图层透明度与缩放
/// 随音频（响度 / 低频 / 中频 / 宽频起音脉冲）实时变化；暂停时约一秒内减速到 12%。
///
/// 画法：`shaders/visualizer_bg_latent.frag`；着色器不可用（widget 测试）时同一套公式在粗网格上
/// 走 CPU 近似（流体用逐顶点着色的网格插值，像素层用粗格子）。
library;

import 'dart:async';
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
// 参数（folia `DEFAULT_LATENT_BACKGROUND_TUNING`，键名沿用字段名）
// ---------------------------------------------------------------------------

abstract final class LatentBackgroundKeys {
  static const String displayMode = 'displayMode';
  static const String colorSource = 'colorSource';
  static const String enhancedBeatResponse = 'enhancedBeatResponse';
  static const String ditheringSpeed = 'ditheringSpeed';
  static const String ditheringAudioSpeed = 'ditheringAudioSpeed';
  static const String ditheringSize = 'ditheringSize';
  static const String ditheringOpacity = 'ditheringOpacity';
  static const String meshSpeed = 'meshSpeed';
  static const String meshAudioSpeed = 'meshAudioSpeed';
  static const String meshDistortion = 'meshDistortion';
  static const String meshSwirl = 'meshSwirl';
  static const String overlayEnabled = 'overlayEnabled';
  static const String overlayOpacity = 'overlayOpacity';
}

String _times(double v) => '×${v.toStringAsFixed(2)}';
String _percent(double v) => '${(v * 100).round()}%';
String _px(double v) => '${v.toStringAsFixed(2)} px';

String _display(LyricVisualizerTuning v) =>
    v.choice(LatentBackgroundKeys.displayMode, 'both');

final LyricVisualizerTuningSection _ditherSection =
    LyricVisualizerTuningSection(
      key: 'latent_dithering',
      label: () => t.music_visualizer_background_latent_dithering_group,
      initiallyExpanded: true,
    );

final LyricVisualizerTuningSection _meshSection = LyricVisualizerTuningSection(
  key: 'latent_mesh',
  label: () => t.music_visualizer_background_latent_mesh_group,
  initiallyExpanded: true,
);

bool _showsDither(LyricVisualizerTuning v) => _display(v) != 'mesh';
bool _showsMesh(LyricVisualizerTuning v) => _display(v) != 'dithering';

final List<LyricVisualizerTuningSpec> latentBackgroundTunings =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerChoiceSpec(
        key: LatentBackgroundKeys.displayMode,
        label: () => t.music_visualizer_background_latent_display,
        options: <(String, String Function())>[
          (
            'dithering',
            () => t.music_visualizer_background_latent_display_dithering,
          ),
          ('mesh', () => t.music_visualizer_background_latent_display_mesh),
          ('both', () => t.music_visualizer_background_latent_display_both),
        ],
        initial: 'both',
      ),
      LyricVisualizerChoiceSpec(
        key: LatentBackgroundKeys.colorSource,
        label: () => t.music_visualizer_background_latent_color_source,
        options: <(String, String Function())>[
          (
            'cover-theme',
            () => t.music_visualizer_background_latent_color_cover_theme,
          ),
          (
            'cover-only',
            () => t.music_visualizer_background_latent_color_cover_only,
          ),
        ],
        initial: 'cover-theme',
      ),
      LyricVisualizerToggleSpec(
        key: LatentBackgroundKeys.enhancedBeatResponse,
        label: () => t.music_visualizer_background_latent_beat_response,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: LatentBackgroundKeys.overlayEnabled,
        label: () => t.music_visualizer_background_overlay,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: LatentBackgroundKeys.overlayOpacity,
        label: () => t.music_visualizer_background_overlay_opacity,
        min: 0,
        max: 1,
        initial: 0.35,
        divisions: 20,
        format: _percent,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.flag(LatentBackgroundKeys.overlayEnabled, true),
      ),
      LyricVisualizerSliderSpec(
        key: LatentBackgroundKeys.ditheringSpeed,
        label: () => t.music_visualizer_background_latent_base_speed,
        section: _ditherSection,
        min: 0,
        max: 2,
        initial: 0.1,
        divisions: 20,
        format: _times,
        visibleWhen: _showsDither,
      ),
      LyricVisualizerSliderSpec(
        key: LatentBackgroundKeys.ditheringAudioSpeed,
        label: () => t.music_visualizer_background_latent_audio_speed,
        section: _ditherSection,
        min: 0,
        max: 2,
        initial: 1.2,
        divisions: 20,
        format: _times,
        visibleWhen: _showsDither,
      ),
      LyricVisualizerSliderSpec(
        key: LatentBackgroundKeys.ditheringSize,
        label: () => t.music_visualizer_background_latent_dithering_size,
        section: _ditherSection,
        min: 0.5,
        max: 8,
        initial: 2.5,
        divisions: 30,
        format: _px,
        visibleWhen: _showsDither,
      ),
      LyricVisualizerSliderSpec(
        key: LatentBackgroundKeys.ditheringOpacity,
        label: () => t.music_visualizer_background_latent_dithering_opacity,
        section: _ditherSection,
        min: 0,
        max: 1,
        initial: 0.55,
        divisions: 20,
        format: _percent,
        visibleWhen: _showsDither,
      ),
      LyricVisualizerSliderSpec(
        key: LatentBackgroundKeys.meshSpeed,
        label: () => t.music_visualizer_background_latent_base_speed,
        section: _meshSection,
        min: 0,
        max: 2,
        initial: 0.3,
        divisions: 20,
        format: _times,
        visibleWhen: _showsMesh,
      ),
      LyricVisualizerSliderSpec(
        key: LatentBackgroundKeys.meshAudioSpeed,
        label: () => t.music_visualizer_background_latent_audio_speed,
        section: _meshSection,
        min: 0,
        max: 2,
        initial: 2,
        divisions: 20,
        format: _times,
        visibleWhen: _showsMesh,
      ),
      LyricVisualizerSliderSpec(
        key: LatentBackgroundKeys.meshDistortion,
        label: () => t.music_visualizer_background_latent_mesh_distortion,
        section: _meshSection,
        min: 0,
        max: 2,
        initial: 0.8,
        divisions: 40,
        format: _times,
        visibleWhen: _showsMesh,
      ),
      LyricVisualizerSliderSpec(
        key: LatentBackgroundKeys.meshSwirl,
        label: () => t.music_visualizer_background_latent_mesh_swirl,
        section: _meshSection,
        min: 0,
        max: 1,
        initial: 0.1,
        divisions: 20,
        format: _times,
        visibleWhen: _showsMesh,
      ),
    ];

final LyricVisualizerBackgroundEntry latentBackgroundEntry =
    LyricVisualizerBackgroundEntry(
      id: 'latent',
      label: () => t.music_visualizer_background_latent,
      icon: FushiIcons.blur,
      tunings: latentBackgroundTunings,
      builder: (LyricVisualizerContext c, LyricVisualizerTuning tu) =>
          LyricVisualizerBackgroundView(
            context: c,
            tuning: tu,
            create: LatentBackgroundScene.new,
          ),
    );

// ---------------------------------------------------------------------------
// 纯函数（folia `LatentBackground.tsx` 导出的那几个，0–1 刻度）
// ---------------------------------------------------------------------------

/// 暂停时的速度比例（folia `PAUSED_SPEED_SCALE`）。
const double kLatentPausedSpeedScale = 0.12;

/// 宽频能量（folia `resolveLatentBroadbandEnergy`；输入已是 0–1）。folia 的 lowMid / mid 两段
/// 这里都取中频。
double latentBroadbandEnergy(LyricVisualizerAudioFrame f) {
  final double e =
      f.low * 0.22 +
      f.mid * 0.18 +
      f.mid * 0.22 +
      f.vocal * 0.28 +
      f.high * 0.1;
  return math.pow(e.clamp(0.0, 1.0), 0.55).toDouble();
}

/// 起音脉冲（folia `resolveLatentOnsetPulse`；[decay] 是这一帧的衰减系数，60 fps 时 0.84）。
double latentOnsetPulse(
  double current,
  double previous,
  double previousPulse, {
  double decay = 0.84,
}) =>
    math.max(previousPulse * decay, ((current - previous) * 7).clamp(0.0, 1.0));

/// 拍点速度目标（folia `resolveLatentBeatSpeedTarget`）。
double latentBeatSpeedTarget(double energy, double pulse) =>
    (energy * 0.42 + pulse * 0.85).clamp(0.0, 1.0);

/// 音频速度目标（folia `resolveLatentAudioSpeedTarget`）。
double latentAudioSpeedTarget(double energy, double pulse, bool enhanced) =>
    enhanced ? latentBeatSpeedTarget(energy, pulse) : energy.clamp(0.0, 1.0);

/// 着色器速度（folia `resolveLatentShaderSpeed`）。
double latentShaderSpeed(
  double base,
  double audio,
  double amount,
  bool paused,
) => (paused ? base * kLatentPausedSpeedScale : base + (audio - base) * amount)
    .clamp(0.0, 2.0);

/// 各层颜色（folia `resolveLatentShaderColors`）。
({Color ditheringBack, Color ditheringFront, List<Color> mesh})
latentShaderColors(
  List<Color> cover,
  LyricVisualizerPalette p,
  String colorSource,
) {
  Color at(int i, Color fallback) => i < cover.length ? cover[i] : fallback;
  final Color primary = at(0, p.secondary);
  if (colorSource == 'cover-only') {
    final Color secondary = at(1, primary);
    final Color tertiary = at(2, secondary);
    return (
      ditheringBack: tertiary,
      ditheringFront: primary,
      mesh: <Color>[
        primary,
        secondary,
        tertiary,
        at(3, primary),
        at(4, secondary),
        at(5, tertiary),
      ],
    );
  }
  final Color secondary = at(1, p.primary);
  final Color tertiary = at(2, primary);
  return (
    ditheringBack: p.background,
    ditheringFront: primary,
    mesh: <Color>[
      primary,
      secondary,
      tertiary,
      at(3, secondary),
      p.background,
      p.accent,
    ],
  );
}

/// 一帧的着色器输入（GPU / CPU 两条路共用）。
@immutable
class LatentFrame {
  const LatentFrame({
    required this.meshTime,
    required this.ditherTime,
    required this.distortion,
    required this.swirl,
    required this.pxSize,
    required this.ditherOpacity,
    required this.showMesh,
    required this.showDither,
    required this.meshScale,
    required this.ditherScale,
    required this.meshSaturate,
    required this.meshBrightness,
    required this.overlay,
    required this.mesh,
    required this.ditherBack,
    required this.ditherFront,
    required this.background,
  });

  final double meshTime;
  final double ditherTime;
  final double distortion;
  final double swirl;

  /// 像素尺寸（逻辑像素）。
  final double pxSize;
  final double ditherOpacity;
  final bool showMesh;
  final bool showDither;
  final double meshScale;
  final double ditherScale;
  final double meshSaturate;
  final double meshBrightness;
  final double overlay;
  final List<Color> mesh;
  final Color ditherBack;
  final Color ditherFront;
  final Color background;
}

// ----- CPU 版公式（与着色器逐行对应） -----

Offset _meshPoint(int i, double t, double aspect) {
  final double a = t * 0.4 * (1 + 0.13 * i) + i * 1.7;
  final double b = t * 0.33 * (1 + 0.11 * i) + i * 2.3;
  return Offset(0.36 * aspect * math.cos(a), 0.36 * math.sin(b));
}

/// 流体层在画布点 [frag]（逻辑像素）的颜色。
Color latentMeshAt(LatentFrame f, Offset frag, Size size) {
  final double aspect = size.width / math.max(size.height, 1);
  double px =
      (frag.dx - size.width / 2) / math.max(size.height, 1) / f.meshScale;
  double py =
      (frag.dy - size.height / 2) / math.max(size.height, 1) / f.meshScale;
  final double t = f.meshTime;
  final double wx = f.distortion * 0.08 * math.sin(py * 4 + t * 0.6);
  final double wy = f.distortion * 0.08 * math.cos(px * 4 - t * 0.5);
  px += wx;
  py += wy;
  final double r = math.sqrt(px * px + py * py);
  final double ang = f.swirl * 3 * (1 - lyricBgSmoothstep(0, 0.9, r));
  final double cs = math.cos(ang);
  final double sn = math.sin(ang);
  final double rx = cs * px - sn * py;
  final double ry = sn * px + cs * py;
  double sr = 0;
  double sg = 0;
  double sb = 0;
  double sw = 0;
  for (int i = 0; i < 6; i++) {
    final Offset c = _meshPoint(i, t, aspect);
    final double d = math.sqrt(
      (rx - c.dx) * (rx - c.dx) + (ry - c.dy) * (ry - c.dy),
    );
    final double w = 1 / (math.pow(d, 2.5) + 0.0005);
    final Color col = f.mesh[i];
    sr += col.r * w;
    sg += col.g * w;
    sb += col.b * w;
    sw += w;
  }
  double r0 = sr / sw;
  double g0 = sg / sw;
  double b0 = sb / sw;
  final double lum = 0.2126 * r0 + 0.7152 * g0 + 0.0722 * b0;
  r0 = (lum + (r0 - lum) * f.meshSaturate) * f.meshBrightness;
  g0 = (lum + (g0 - lum) * f.meshSaturate) * f.meshBrightness;
  b0 = (lum + (b0 - lum) * f.meshSaturate) * f.meshBrightness;
  return Color.from(
    alpha: 1,
    red: r0.clamp(0.0, 1.0),
    green: g0.clamp(0.0, 1.0),
    blue: b0.clamp(0.0, 1.0),
  );
}

double _fract(double v) => v - v.floorToDouble();

double _bayer2(double x, double y) {
  x = x.floorToDouble();
  y = y.floorToDouble();
  return _fract(x * 0.5 + y * (y * 0.75));
}

/// 4×4 Bayer 阈值（0–1），与着色器 `bayer4` 相同。
double latentBayer4(double x, double y) =>
    _bayer2(0.5 * x, 0.5 * y) * 0.25 + _bayer2(x, y);

/// 翘曲噪声图案（0–1）。
double latentWarpPattern(double qx, double qy, double t) {
  for (int k = 0; k < 4; k++) {
    final double nx = qx + 0.4 * math.sin(qy * 1.7 + t + k);
    final double ny = qy + 0.4 * math.cos(qx * 1.3 - t * 0.8 + k * 1.3);
    qx = nx;
    qy = ny;
  }
  return 0.5 + 0.5 * math.sin(qx + qy * 0.7 + t * 0.5);
}

/// 像素格 ([cx], [cy])（格子尺寸 [cell] 逻辑像素）是否点亮前景色。
bool latentDitherOn(
  LatentFrame f,
  double cx,
  double cy,
  double cell,
  Size size,
) {
  final double qx = cx * cell / math.max(size.height, 1) * 3;
  final double qy = cy * cell / math.max(size.height, 1) * 3;
  return latentWarpPattern(qx, qy, f.ditherTime) >= latentBayer4(cx, cy);
}

// ---------------------------------------------------------------------------
// 着色器
// ---------------------------------------------------------------------------

Future<ui.FragmentProgram?>? _programLoad;
ui.FragmentProgram? _program;

void _ensureProgram() {
  _programLoad ??=
      ui.FragmentProgram.fromAsset(
        'shaders/visualizer_bg_latent.frag',
      ).then<ui.FragmentProgram?>(
        (ui.FragmentProgram p) => _program = p,
        onError: (Object e) {
          debugPrint('[latent] shader unavailable: $e');
          return null;
        },
      );
}

// ---------------------------------------------------------------------------
// 场景
// ---------------------------------------------------------------------------

/// 播放 / 暂停之间切换速度的时间常数（folia `PAUSE_EASE_MS`）。
const double _kPauseEaseSeconds = 0.3;

class LatentBackgroundScene extends LyricVisualizerBackgroundScene {
  /// [useShader] 为 false 时始终走 CPU 路径；[program] 指定着色器（测试在真实异步区里自己加载后传进来）。
  /// 着色器没编进包时自动退到 CPU。
  LatentBackgroundScene({this.useShader = true, ui.FragmentProgram? program})
    : _programOverride = program {
    _ensureProgram();
    _cover.addListener(_onCover);
  }

  final bool useShader;
  final ui.FragmentProgram? _programOverride;
  final LyricBgImageSource _cover = LyricBgImageSource();
  late LyricVisualizerContext _c;
  late LyricVisualizerTuning _tu;
  List<Color> _coverColors = const <Color>[];
  int _colorGeneration = 0;
  bool _disposed = false;
  List<LyricBgColorBlend>? _blends;
  double _playing = 1;
  bool _playingInit = false;
  double _power = 0;
  double _bass = 0;
  double _mid = 0;
  double _beatSpeed = 0;
  double _prevEnergy = 0;
  double _pulse = 0;
  double _meshTime = 0;
  double _ditherTime = 0;

  void _onCover() {
    final ui.Image? img = _cover.image;
    final int gen = ++_colorGeneration;
    if (img == null) {
      _coverColors = const <Color>[];
      _retarget();
      return;
    }
    final ui.Image copy = img.clone();
    unawaited(
      lyricBgRepresentativeColorsOf(copy, 6)
          .then<void>((List<Color> colors) {
            if (_disposed || gen != _colorGeneration) return;
            _coverColors = colors;
            _retarget();
          }, onError: (Object _) {})
          .whenComplete(copy.dispose),
    );
  }

  List<Color> _targets() {
    final ({Color ditheringBack, Color ditheringFront, List<Color> mesh}) r =
        latentShaderColors(
          _coverColors,
          _c.palette,
          _tu.choice(LatentBackgroundKeys.colorSource, 'cover-theme'),
        );
    return <Color>[
      _c.palette.background,
      r.ditheringBack,
      r.ditheringFront,
      ...r.mesh,
    ];
  }

  void _retarget() {
    final List<Color> targets = _targets();
    final List<LyricBgColorBlend> blends = _blends ??= <LyricBgColorBlend>[
      for (final Color c in targets) LyricBgColorBlend(c),
    ];
    for (int i = 0; i < targets.length; i++) {
      blends[i].target(targets[i], immediate: !_c.motion);
    }
    notifyListeners();
  }

  @override
  void configure(
    LyricVisualizerContext context,
    LyricVisualizerTuning tuning,
    double devicePixelRatio,
  ) {
    _c = context;
    _tu = tuning;
    if (!_playingInit) {
      _playing = context.playing ? 1 : 0;
      _playingInit = true;
    }
    _cover.select(coverPath: context.coverPath);
    _retarget();
  }

  double _speedOf(double base, double audio) {
    final double paused = latentShaderSpeed(base, audio, _beatSpeed, true);
    final double playing = latentShaderSpeed(base, audio, _beatSpeed, false);
    return paused + (playing - paused) * _playing;
  }

  @override
  void advance(LyricVisualizerTick tick) {
    final double dt = tick.dt;
    for (final LyricBgColorBlend b in _blends!) {
      b.advance(dt);
    }
    if (!_c.motion) return;
    final bool paused = !_c.playing;
    _playing +=
        ((paused ? 0 : 1) - _playing) *
        (1 - math.exp(-dt / _kPauseEaseSeconds));
    final LyricVisualizerAudioFrame f = _c.audioFrameAt(tick.timeMs);
    final double energy = paused ? 0 : latentBroadbandEnergy(f);
    final double tPower = paused ? 0 : f.power;
    final double tBass = paused ? 0 : f.low;
    final double tMid = paused ? 0 : math.max(f.mid, f.vocal);
    _power = lyricBgEase(_power, tPower, 0.12, dt);
    _bass = lyricBgEase(_bass, tBass, 0.16, dt);
    _mid = lyricBgEase(_mid, tMid, 0.13, dt);
    final bool enhanced = _tu.flag(
      LatentBackgroundKeys.enhancedBeatResponse,
      true,
    );
    if (dt > 0) {
      _pulse = enhanced
          ? latentOnsetPulse(
              energy,
              _prevEnergy,
              _pulse,
              decay: math.pow(0.84, dt * 60).toDouble(),
            )
          : 0;
      _prevEnergy = energy;
    }
    final double target = latentAudioSpeedTarget(energy, _pulse, enhanced);
    _beatSpeed = lyricBgEase(
      _beatSpeed,
      target,
      target > _beatSpeed ? 0.42 : 0.14,
      dt,
    );
    _ditherTime +=
        dt *
        _speedOf(
          _tu.number(LatentBackgroundKeys.ditheringSpeed, 0.1),
          _tu.number(LatentBackgroundKeys.ditheringAudioSpeed, 1.2),
        );
    _meshTime +=
        dt *
        _speedOf(
          _tu.number(LatentBackgroundKeys.meshSpeed, 0.3),
          _tu.number(LatentBackgroundKeys.meshAudioSpeed, 2),
        );
  }

  /// 这一帧的着色器输入。
  LatentFrame frame() {
    final String mode = _tu.choice(LatentBackgroundKeys.displayMode, 'both');
    final bool showMesh = mode != 'dithering';
    final bool showDither = mode != 'mesh';
    final List<LyricBgColorBlend> b = _blends!;
    final double size = _tu.number(LatentBackgroundKeys.ditheringSize, 2.5);
    return LatentFrame(
      meshTime: _meshTime,
      ditherTime: _ditherTime,
      distortion:
          _tu.number(LatentBackgroundKeys.meshDistortion, 0.8) + _power * 0.62,
      swirl: _tu.number(LatentBackgroundKeys.meshSwirl, 0.1) + _mid * 0.38,
      pxSize: math.max(0.5, size - _bass * size * 0.34),
      ditherOpacity: showMesh
          ? math.min(
              1,
              _tu.number(LatentBackgroundKeys.ditheringOpacity, 0.55) +
                  _bass * 0.25,
            )
          : 1,
      showMesh: showMesh,
      showDither: showDither,
      meshScale: 1.025 + _power * 0.018,
      ditherScale: 1.015 + _bass * 0.025,
      meshSaturate: 1.04 + _mid * 0.34,
      meshBrightness: 0.94 + _power * 0.16,
      overlay: _tu.flag(LatentBackgroundKeys.overlayEnabled, true)
          ? _tu.number(LatentBackgroundKeys.overlayOpacity, 0.35)
          : 0,
      background: b[0].value,
      ditherBack: b[1].value,
      ditherFront: b[2].value,
      mesh: <Color>[for (int i = 3; i < 9; i++) b[i].value],
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final LatentFrame f = frame();
    final ui.FragmentProgram? program = useShader
        ? (_programOverride ?? _program)
        : null;
    if (program != null) {
      _paintShader(canvas, size, f, program);
    } else {
      paintLatentCpu(canvas, size, f);
    }
  }

  void _paintShader(
    Canvas canvas,
    Size size,
    LatentFrame f,
    ui.FragmentProgram program,
  ) {
    final ui.FragmentShader shader = program.fragmentShader();
    int i = 0;
    void put(double v) => shader.setFloat(i++, v);
    void putColor(Color c) {
      put(c.r);
      put(c.g);
      put(c.b);
    }

    // FlutterFragCoord 是画布本地（逻辑）坐标，尺寸 / 像素大小都按逻辑像素给。
    put(size.width);
    put(size.height);
    put(f.meshTime);
    put(f.ditherTime);
    put(f.distortion);
    put(f.swirl);
    put(f.pxSize);
    put(f.ditherOpacity);
    put(f.showMesh ? 1 : 0);
    put(f.showDither ? 1 : 0);
    put(f.meshScale);
    put(f.ditherScale);
    put(f.meshSaturate);
    put(f.meshBrightness);
    put(f.overlay);
    for (final Color c in f.mesh) {
      putColor(c);
    }
    putColor(f.ditherBack);
    putColor(f.ditherFront);
    putColor(f.background);
    canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    shader.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _cover.removeListener(_onCover);
    _cover.dispose();
    super.dispose();
  }
}

/// CPU 近似：流体层在 32 px 网格顶点上取色、三角形内插值；像素层在 ≥ 6 px 的粗格子上按同一
/// Bayer 阈值点亮，soft-light 叠上去；最后叠底色。
void paintLatentCpu(Canvas canvas, Size size, LatentFrame f) {
  final Rect all = Offset.zero & size;
  canvas.drawRect(all, Paint()..color = f.background);
  if (f.showMesh) {
    const double step = 32;
    final int cols = (size.width / step).ceil();
    final int rows = (size.height / step).ceil();
    final List<Color> grid = <Color>[
      for (int y = 0; y <= rows; y++)
        for (int x = 0; x <= cols; x++)
          latentMeshAt(
            f,
            Offset(
              math.min(x * step, size.width),
              math.min(y * step, size.height),
            ),
            size,
          ),
    ];
    final Float32List pos = Float32List(cols * rows * 12);
    final Int32List colors = Int32List(cols * rows * 6);
    int pi = 0;
    int ci = 0;
    void vert(int x, int y) {
      pos[pi++] = math.min(x * step, size.width);
      pos[pi++] = math.min(y * step, size.height);
      colors[ci++] = grid[y * (cols + 1) + x].toARGB32();
    }

    for (int y = 0; y < rows; y++) {
      for (int x = 0; x < cols; x++) {
        vert(x, y);
        vert(x + 1, y);
        vert(x, y + 1);
        vert(x + 1, y);
        vert(x + 1, y + 1);
        vert(x, y + 1);
      }
    }
    canvas.drawVertices(
      ui.Vertices.raw(VertexMode.triangles, pos, colors: colors),
      BlendMode.dst,
      Paint(),
    );
  }
  if (f.showDither) {
    final double cell = math.max(f.pxSize, 6);
    final Path front = Path();
    final int cols = (size.width / cell).ceil();
    final int rows = (size.height / cell).ceil();
    for (int y = 0; y < rows; y++) {
      for (int x = 0; x < cols; x++) {
        if (latentDitherOn(f, x.toDouble(), y.toDouble(), cell, size)) {
          front.addRect(Rect.fromLTWH(x * cell, y * cell, cell, cell));
        }
      }
    }
    final Paint layer = Paint();
    if (f.showMesh) {
      layer
        ..blendMode = BlendMode.softLight
        ..color = Color.fromRGBO(0, 0, 0, f.ditherOpacity.clamp(0.0, 1.0));
    }
    canvas.saveLayer(all, layer);
    canvas.drawRect(all, Paint()..color = f.ditherBack);
    canvas.drawPath(front, Paint()..color = f.ditherFront);
    canvas.restore();
  }
  if (f.overlay > 0) {
    canvas.drawRect(
      all,
      Paint()
        ..color = f.background.withValues(alpha: f.overlay.clamp(0.0, 1.0)),
    );
  }
}
