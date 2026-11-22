/// 镜台的可调参数（folia `diorama/tuning.ts` + `types.ts` 的 `DioramaTuning`，默认值与范围一致）。
///
/// 去掉的：分辨率 / 抗锯齿覆盖（Fushi 没有这层全局挡位）。运镜风格跟 folia 一样随主题强度
/// （`LyricVisualizerContext.intensity`：AI 主题指定的，否则全局偏好），不是本样式的参数。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_path.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_particles.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_scene_layout.dart';

/// 落库键（冻结）。
abstract final class DioramaTuningKeys {
  static const String keywordColoringEnabled = 'keywordColoringEnabled';
  static const String cameraSpeed = 'cameraSpeed';
  static const String motionAmount = 'motionAmount';
  static const String audioReactivity = 'audioReactivity';
  static const String geometryEnabled = 'geometryEnabled';
  static const String geometryMode = 'geometryMode';
  static const String geometryStrands = 'geometryStrands';
  static const String geometryBlobs = 'geometryBlobs';
  static const String geometryRibbons = 'geometryRibbons';
  static const String geometryRings = 'geometryRings';
  static const String particleDensity = 'particleDensity';
  static const String particleScale = 'particleScale';
  static const String particleGlowEnabled = 'particleGlowEnabled';
  static const String particleGlowIntensity = 'particleGlowIntensity';
  static const String showParticles = 'showParticles';
  static const String moteCircumference = 'backgroundParticleCircumference';
  static const String moteRadial = 'backgroundParticleRadial';
  static const String glowEnabled = 'glowEnabled';
  static const String glowIntensity = 'glowIntensity';
  static const String soulEnabled = 'soulEnabled';
  static const String soulIntensity = 'soulIntensity';
  static const String soulActiveEnabled = 'soulActiveEnabled';
  static const String gradientEnabled = 'gradientEnabled';
  static const String gradientIntensity = 'gradientIntensity';
}

String _int(double v) => v.round().toString();

final List<LyricVisualizerTuningSpec> dioramaTuningSpecs =
    <LyricVisualizerTuningSpec>[
      // folia：主题 wordColors 里的关键词，跟唱时染成自己的颜色（按对比度修正）。
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.keywordColoringEnabled,
        label: () => t.music_visualizer_diorama_keyword_coloring,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.cameraSpeed,
        label: () => t.music_visualizer_diorama_camera_speed,
        min: 0.55,
        max: 1.85,
        initial: 1,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.motionAmount,
        label: () => t.music_visualizer_diorama_motion_amount,
        min: 0.4,
        max: 1.6,
        initial: 1,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.audioReactivity,
        label: () => t.music_visualizer_diorama_audio_reactivity,
        min: 0,
        max: 1.5,
        initial: 1,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.geometryEnabled,
        label: () => t.music_visualizer_diorama_geometry,
        initial: true,
      ),
      LyricVisualizerChoiceSpec(
        key: DioramaTuningKeys.geometryMode,
        label: () => t.music_visualizer_diorama_geometry_mode,
        initial: 'clouds',
        options: <(String, String Function())>[
          ('clouds', () => t.music_visualizer_diorama_geometry_mode_clouds),
          ('corridor', () => t.music_visualizer_diorama_geometry_mode_corridor),
        ],
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.geometryStrands,
        label: () => t.music_visualizer_diorama_geometry_strands,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.geometryBlobs,
        label: () => t.music_visualizer_diorama_geometry_blobs,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.geometryRibbons,
        label: () => t.music_visualizer_diorama_geometry_ribbons,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.geometryRings,
        label: () => t.music_visualizer_diorama_geometry_rings,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.particleDensity,
        label: () => t.music_visualizer_diorama_particle_density,
        min: dioramaParticleDensityMin.toDouble(),
        max: dioramaParticleDensityMax.toDouble(),
        initial: 576,
        divisions:
            (dioramaParticleDensityMax - dioramaParticleDensityMin) ~/
            dioramaParticleDensityStep,
        format: _int,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.particleScale,
        label: () => t.music_visualizer_diorama_particle_scale,
        min: 0.65,
        max: 1.6,
        initial: 1,
        divisions: 19,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.particleGlowEnabled,
        label: () => t.music_visualizer_diorama_particle_glow,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.particleGlowIntensity,
        label: () => t.music_visualizer_diorama_particle_glow_intensity,
        min: 0.1,
        max: 1.5,
        initial: 0.65,
        divisions: 28,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.showParticles,
        label: () => t.music_visualizer_diorama_show_particles,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.moteCircumference,
        label: () => t.music_visualizer_diorama_mote_circumference,
        min: dioramaMoteCircumferenceMin.toDouble(),
        max: dioramaMoteCircumferenceMax.toDouble(),
        initial: 28,
        divisions:
            (dioramaMoteCircumferenceMax - dioramaMoteCircumferenceMin) ~/ 2,
        format: _int,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.moteRadial,
        label: () => t.music_visualizer_diorama_mote_radial,
        min: dioramaMoteRadialMin.toDouble(),
        max: dioramaMoteRadialMax.toDouble(),
        initial: 2,
        divisions: dioramaMoteRadialMax - dioramaMoteRadialMin,
        format: _int,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.glowEnabled,
        label: () => t.music_visualizer_diorama_glow,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.glowIntensity,
        label: () => t.music_visualizer_diorama_glow_intensity,
        min: 0.1,
        max: 1.5,
        initial: 1,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.soulEnabled,
        label: () => t.music_visualizer_diorama_soul,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.soulIntensity,
        label: () => t.music_visualizer_diorama_soul_intensity,
        min: 0.1,
        max: 1.5,
        initial: 1,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.soulActiveEnabled,
        label: () => t.music_visualizer_diorama_soul_active,
        initial: false,
      ),
      LyricVisualizerToggleSpec(
        key: DioramaTuningKeys.gradientEnabled,
        label: () => t.music_visualizer_diorama_gradient,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: DioramaTuningKeys.gradientIntensity,
        label: () => t.music_visualizer_diorama_gradient_intensity,
        min: 0.1,
        max: 1.5,
        initial: 1,
      ),
    ];

/// 读出来的一组设置（开关关掉的效果解析成强度 0，场景只看有效强度）。
class DioramaSettings {
  const DioramaSettings({
    required this.motion,
    required this.geometry,
    required this.particleDensity,
    required this.particleScale,
    required this.particleGlowIntensity,
    required this.showParticles,
    required this.moteCircumference,
    required this.moteRadial,
    required this.glowIntensity,
    required this.soulIntensity,
    required this.soulActiveEnabled,
    required this.gradientIntensity,
    this.keywordColoring = true,
  });

  /// [intensity] 是生效的动画强度（folia `theme.animationIntensity`），决定运镜风格。
  factory DioramaSettings.read(
    LyricVisualizerTuning tu, [
    LyricVisualizerIntensity intensity = LyricVisualizerIntensity.normal,
  ]) {
    final DioramaSubMode sub = switch (intensity) {
      LyricVisualizerIntensity.calm => DioramaSubMode.calm,
      LyricVisualizerIntensity.chaotic => DioramaSubMode.chaotic,
      LyricVisualizerIntensity.normal => DioramaSubMode.normal,
    };
    final bool soulOn = tu.flag(DioramaTuningKeys.soulEnabled, true);
    return DioramaSettings(
      keywordColoring: tu.flag(DioramaTuningKeys.keywordColoringEnabled, true),
      motion: resolveDioramaMotionParams(
        cameraSpeed: tu.number(DioramaTuningKeys.cameraSpeed, 1),
        motionAmount: tu.number(DioramaTuningKeys.motionAmount, 1),
        audioReactivity: tu.number(DioramaTuningKeys.audioReactivity, 1),
        subMode: sub,
      ),
      geometry: DioramaGeometryVisibility(
        enabled: tu.flag(DioramaTuningKeys.geometryEnabled, true),
        corridor:
            tu.choice(DioramaTuningKeys.geometryMode, 'clouds') == 'corridor',
        strands: tu.flag(DioramaTuningKeys.geometryStrands, true),
        blobs: tu.flag(DioramaTuningKeys.geometryBlobs, true),
        ribbons: tu.flag(DioramaTuningKeys.geometryRibbons, true),
        rings: tu.flag(DioramaTuningKeys.geometryRings, true),
      ),
      particleDensity: dioramaNormalizeDensity(
        tu.number(DioramaTuningKeys.particleDensity, 576),
      ).toDouble(),
      particleScale: tu.number(DioramaTuningKeys.particleScale, 1),
      particleGlowIntensity:
          tu.flag(DioramaTuningKeys.particleGlowEnabled, true)
          ? tu.number(DioramaTuningKeys.particleGlowIntensity, 0.65)
          : 0,
      showParticles: tu.flag(DioramaTuningKeys.showParticles, true),
      moteCircumference: tu
          .number(DioramaTuningKeys.moteCircumference, 28)
          .round()
          .clamp(dioramaMoteCircumferenceMin, dioramaMoteCircumferenceMax),
      moteRadial: tu
          .number(DioramaTuningKeys.moteRadial, 2)
          .round()
          .clamp(dioramaMoteRadialMin, dioramaMoteRadialMax),
      glowIntensity: tu.flag(DioramaTuningKeys.glowEnabled, true)
          ? tu.number(DioramaTuningKeys.glowIntensity, 1)
          : 0,
      soulIntensity: soulOn ? tu.number(DioramaTuningKeys.soulIntensity, 1) : 0,
      soulActiveEnabled:
          soulOn && tu.flag(DioramaTuningKeys.soulActiveEnabled, false),
      gradientIntensity: tu.flag(DioramaTuningKeys.gradientEnabled, false)
          ? tu.number(DioramaTuningKeys.gradientIntensity, 1)
          : 0,
    );
  }

  final DioramaMotionParams motion;
  final DioramaGeometryVisibility geometry;
  final double particleDensity;
  final double particleScale;

  /// 点云整体辉光强度（开关关 = 0）。
  final double particleGlowIntensity;
  final bool showParticles;
  final int moteCircumference;
  final int moteRadial;
  final double glowIntensity;
  final double soulIntensity;
  final bool soulActiveEnabled;
  final double gradientIntensity;

  /// folia `keywordColoringEnabled`。
  final bool keywordColoring;
}
