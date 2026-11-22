/// 时计（folia `pendolo/tuning.ts`）的可调参数：键名、默认值与范围照 folia，落库键冻结。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

/// 倾斜角度上限（度，folia `PENDOLO_TILT_LIMIT_DEG`）。
const double kPendoloTiltLimitDeg = 70;

/// 轮心视角相机高度 / 后退距离范围（轮盘半径的倍数）。
const double kPendoloHubViewHeightMin = 0.4;
const double kPendoloHubViewHeightMax = 3;
const double kPendoloHubViewBackMin = 0.2;
const double kPendoloHubViewBackMax = 3;

/// 机械饰线强度（folia `showGearDecor`）。
enum PendoloGearDecor {
  none('none'),
  subtle('subtle'),
  full('full');

  const PendoloGearDecor(this.value);

  final String value;

  static PendoloGearDecor of(String raw) {
    for (final PendoloGearDecor d in values) {
      if (d.value == raw) return d;
    }
    return subtle;
  }
}

/// 落库键（冻结，与 folia 字段名一致）。
abstract final class PendoloTuningKeys {
  static const String arcRadius = 'arcRadius';
  static const String arcAngleDeg = 'arcAngleDeg';
  static const String wheelCenterX = 'wheelCenterX';
  static const String wheelCenterY = 'wheelCenterY';
  static const String tickSnappiness = 'tickSnappiness';
  static const String activeScale = 'activeScale';
  static const String showGearDecor = 'showGearDecor';
  static const String showCenterGradient = 'showCenterGradient';
  static const String showCoverOnWatchFace = 'showCoverOnWatchFace';
  static const String enableLineGlow = 'enableLineGlow';
  static const String mirrorLayout = 'mirrorLayout';
  static const String tiltDeg = 'tiltDeg';
  static const String tiltAxisDeg = 'tiltAxisDeg';
  static const String parallaxDepth = 'parallaxDepth';
  static const String hubView = 'hubView';
  static const String hubViewHeight = 'hubViewHeight';
  static const String hubViewBack = 'hubViewBack';

  /// folia 智能动感模式里「仿真鼓面」的强度（0 = 关）。
  static const String drumheadStrength = 'drumheadStrength';
}

int _divisions(double min, double max, double step) =>
    ((max - min) / step).round();

/// 参数声明（面板顺序照 folia `PendoloSettingsPanel`）。
final List<LyricVisualizerTuningSpec> pendoloTuningSpecs =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerToggleSpec(
        key: PendoloTuningKeys.mirrorLayout,
        label: () => t.music_visualizer_pendolo_mirror_layout,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.wheelCenterX,
        label: () => t.music_visualizer_pendolo_wheel_center_x,
        min: -0.3,
        max: 0.5,
        initial: 0,
        divisions: _divisions(-0.3, 0.5, 0.01),
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.wheelCenterY,
        label: () => t.music_visualizer_pendolo_wheel_center_y,
        min: 0.2,
        max: 0.8,
        initial: 0.5,
        divisions: _divisions(0.2, 0.8, 0.01),
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.arcRadius,
        label: () => t.music_visualizer_pendolo_arc_radius,
        min: 0.25,
        max: 0.8,
        initial: 0.42,
        divisions: _divisions(0.25, 0.8, 0.01),
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.arcAngleDeg,
        label: () => t.music_visualizer_pendolo_arc_angle,
        min: 40,
        max: 160,
        initial: 100,
        divisions: _divisions(40, 160, 5),
        format: (double v) => '${v.round()}°',
      ),
      LyricVisualizerToggleSpec(
        key: PendoloTuningKeys.hubView,
        label: () => t.music_visualizer_pendolo_hub_view,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.hubViewHeight,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.flag(PendoloTuningKeys.hubView, false),
        label: () => t.music_visualizer_pendolo_hub_view_height,
        min: kPendoloHubViewHeightMin,
        max: kPendoloHubViewHeightMax,
        initial: 1.4,
        divisions: _divisions(
          kPendoloHubViewHeightMin,
          kPendoloHubViewHeightMax,
          0.05,
        ),
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.hubViewBack,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.flag(PendoloTuningKeys.hubView, false),
        label: () => t.music_visualizer_pendolo_hub_view_back,
        min: kPendoloHubViewBackMin,
        max: kPendoloHubViewBackMax,
        initial: 1.2,
        divisions: _divisions(
          kPendoloHubViewBackMin,
          kPendoloHubViewBackMax,
          0.05,
        ),
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.tiltDeg,
        visibleWhen: (LyricVisualizerTuning v) =>
            !v.flag(PendoloTuningKeys.hubView, false),
        label: () => t.music_visualizer_pendolo_tilt,
        min: -kPendoloTiltLimitDeg,
        max: kPendoloTiltLimitDeg,
        initial: 0,
        divisions: _divisions(-kPendoloTiltLimitDeg, kPendoloTiltLimitDeg, 1),
        format: (double v) => '${v.round()}°',
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.tiltAxisDeg,
        visibleWhen: (LyricVisualizerTuning v) =>
            !v.flag(PendoloTuningKeys.hubView, false),
        label: () => t.music_visualizer_pendolo_tilt_axis,
        min: -90,
        max: 90,
        initial: 0,
        divisions: 180,
        format: (double v) => '${v.round()}°',
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.parallaxDepth,
        label: () => t.music_visualizer_pendolo_parallax_depth,
        min: 0,
        max: 2,
        initial: 1,
        divisions: _divisions(0, 2, 0.05),
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.tickSnappiness,
        label: () => t.music_visualizer_pendolo_tick_snappiness,
        min: 0.5,
        max: 2,
        initial: 2,
        divisions: _divisions(0.5, 2, 0.1),
      ),
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.activeScale,
        label: () => t.music_visualizer_pendolo_active_scale,
        min: 1,
        max: 1.6,
        initial: 1.25,
        divisions: _divisions(1, 1.6, 0.05),
      ),
      LyricVisualizerChoiceSpec(
        key: PendoloTuningKeys.showGearDecor,
        label: () => t.music_visualizer_pendolo_gear_decor,
        initial: PendoloGearDecor.subtle.value,
        options: <(String, String Function())>[
          (
            PendoloGearDecor.none.value,
            () => t.music_visualizer_pendolo_decor_none,
          ),
          (
            PendoloGearDecor.subtle.value,
            () => t.music_visualizer_pendolo_decor_subtle,
          ),
          (
            PendoloGearDecor.full.value,
            () => t.music_visualizer_pendolo_decor_full,
          ),
        ],
      ),
      LyricVisualizerToggleSpec(
        key: PendoloTuningKeys.showCenterGradient,
        label: () => t.music_visualizer_pendolo_center_gradient,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: PendoloTuningKeys.showCoverOnWatchFace,
        label: () => t.music_visualizer_pendolo_cover,
        initial: false,
      ),
      LyricVisualizerToggleSpec(
        key: PendoloTuningKeys.enableLineGlow,
        label: () => t.music_visualizer_pendolo_line_glow,
        initial: false,
      ),
      // folia 把它放在全局「智能动感模式」的每样式效果里（强度 0–2）；Fushi 没有那层全局开关，
      // 做成本样式的参数。
      LyricVisualizerSliderSpec(
        key: PendoloTuningKeys.drumheadStrength,
        label: () => t.music_visualizer_pendolo_drumhead_strength,
        min: 0,
        max: 2,
        initial: 1,
        divisions: _divisions(0, 2, 0.1),
      ),
    ];

/// folia `PendoloSettingsPanel` 的三个预设：都在默认值上只改各自那几项。folia 套预设时保留用户
/// 当前的左右镜像；这里的预设是整组值，镜像回到默认（不镜像）。
final List<LyricVisualizerTuningPreset> pendoloTuningPresets =
    <LyricVisualizerTuningPreset>[
      // 预设 1：表盘往前倾、分层视差拉满，轮盘放大、往右挪。
      LyricVisualizerTuningPreset(
        id: 'tiltForward',
        label: () => t.music_visualizer_pendolo_preset_tilt_forward,
        values: const <String, Object>{
          PendoloTuningKeys.arcRadius: 0.5,
          PendoloTuningKeys.wheelCenterX: 0.3,
          PendoloTuningKeys.tickSnappiness: 1.8,
          PendoloTuningKeys.tiltDeg: 40.0,
          PendoloTuningKeys.tiltAxisDeg: -10.0,
          PendoloTuningKeys.parallaxDepth: 2.0,
        },
      ),
      // 预设 2：表盘往后倾、侧向转开，加分层视差，轮盘放大、往右挪。
      LyricVisualizerTuningPreset(
        id: 'tilt',
        label: () => t.music_visualizer_pendolo_preset_tilt_side,
        values: const <String, Object>{
          PendoloTuningKeys.arcRadius: 0.5,
          PendoloTuningKeys.wheelCenterX: 0.3,
          PendoloTuningKeys.tiltDeg: -53.0,
          PendoloTuningKeys.tiltAxisDeg: 66.0,
          PendoloTuningKeys.parallaxDepth: 1.65,
        },
      ),
      // 预设 3：轮心视角，相机在轮心后上方顺着刻度针看，歌词立起来。
      LyricVisualizerTuningPreset(
        id: 'hubView',
        label: () => t.music_visualizer_pendolo_hub_view,
        values: const <String, Object>{
          PendoloTuningKeys.hubView: true,
          PendoloTuningKeys.hubViewHeight: 1.4,
          PendoloTuningKeys.hubViewBack: 1.2,
          PendoloTuningKeys.parallaxDepth: 1.0,
        },
      ),
    ];

/// 读好的一组参数（folia `PendoloTuning`）。
class PendoloTuning {
  const PendoloTuning({
    this.arcRadius = 0.42,
    this.arcAngleDeg = 100,
    this.wheelCenterX = 0,
    this.wheelCenterY = 0.5,
    this.tickSnappiness = 2,
    this.activeScale = 1.25,
    this.gearDecor = PendoloGearDecor.subtle,
    this.showCenterGradient = true,
    this.showCover = false,
    this.lineGlow = false,
    this.mirrored = false,
    this.tiltDeg = 0,
    this.tiltAxisDeg = 0,
    this.parallaxDepth = 1,
    this.hubView = false,
    this.hubViewHeight = 1.4,
    this.hubViewBack = 1.2,
    this.drumheadStrength = 1,
  });

  factory PendoloTuning.read(LyricVisualizerTuning tuning) => PendoloTuning(
    arcRadius: tuning.number(PendoloTuningKeys.arcRadius, 0.42),
    arcAngleDeg: tuning.number(PendoloTuningKeys.arcAngleDeg, 100),
    wheelCenterX: tuning.number(PendoloTuningKeys.wheelCenterX, 0),
    wheelCenterY: tuning.number(PendoloTuningKeys.wheelCenterY, 0.5),
    tickSnappiness: tuning.number(PendoloTuningKeys.tickSnappiness, 2),
    activeScale: tuning.number(PendoloTuningKeys.activeScale, 1.25),
    gearDecor: PendoloGearDecor.of(
      tuning.choice(PendoloTuningKeys.showGearDecor, 'subtle'),
    ),
    showCenterGradient: tuning.flag(PendoloTuningKeys.showCenterGradient, true),
    showCover: tuning.flag(PendoloTuningKeys.showCoverOnWatchFace, false),
    lineGlow: tuning.flag(PendoloTuningKeys.enableLineGlow, false),
    mirrored: tuning.flag(PendoloTuningKeys.mirrorLayout, false),
    tiltDeg: tuning.number(PendoloTuningKeys.tiltDeg, 0),
    tiltAxisDeg: tuning.number(PendoloTuningKeys.tiltAxisDeg, 0),
    parallaxDepth: tuning.number(PendoloTuningKeys.parallaxDepth, 1),
    hubView: tuning.flag(PendoloTuningKeys.hubView, false),
    hubViewHeight: tuning.number(PendoloTuningKeys.hubViewHeight, 1.4),
    hubViewBack: tuning.number(PendoloTuningKeys.hubViewBack, 1.2),
    drumheadStrength: tuning.number(PendoloTuningKeys.drumheadStrength, 1),
  );

  final double arcRadius;
  final double arcAngleDeg;
  final double wheelCenterX;
  final double wheelCenterY;
  final double tickSnappiness;
  final double activeScale;
  final PendoloGearDecor gearDecor;
  final bool showCenterGradient;
  final bool showCover;
  final bool lineGlow;
  final bool mirrored;
  final double tiltDeg;
  final double tiltAxisDeg;
  final double parallaxDepth;
  final bool hubView;
  final double hubViewHeight;
  final double hubViewBack;
  final double drumheadStrength;

  /// 1 = 歌词在右、表盘在左；镜像时 -1。
  double get sideSign => mirrored ? -1 : 1;
}
