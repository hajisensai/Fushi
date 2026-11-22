/// 町景的可调参数（folia `machi/types.ts` + `tuning.ts`）：场景 / 时间 / 天气（都可以“自动”）、
/// 视角（默认 / 自定义，自定义的五项滑块）、运镜与快慢、景深（光圈、强度、清晰范围、移轴、
/// 对焦）、模拟节拍、倒影、辉光。默认值与范围照 folia。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

const String machiKeyScene = 'scene';
const String machiKeyTimeOfDay = 'time_of_day';
const String machiKeyWeather = 'weather';
const String machiKeyCamera = 'camera';
const String machiKeyViewAzimuth = 'view_azimuth';
const String machiKeyViewElevation = 'view_elevation';
const String machiKeyViewZoom = 'view_zoom';
const String machiKeyViewPanX = 'view_pan_x';
const String machiKeyViewPanZ = 'view_pan_z';
const String machiKeyMotion = 'motion';
const String machiKeyMotionSpeed = 'motion_speed';
const String machiKeyAperture = 'aperture';
const String machiKeyDof = 'dof';
const String machiKeyDofRange = 'dof_range';
const String machiKeyTiltShift = 'tilt_shift';
const String machiKeyFocus = 'focus';
const String machiKeyFocusOffset = 'focus_offset';
const String machiKeySimulatedBeat = 'simulated_beat';
const String machiKeyReflections = 'reflections';
const String machiKeyGlow = 'glow';

String _deg(double v) => '${v.round()}°';
String _times(double v) => '${v.toStringAsFixed(2)}×';
String _meters(double v) => '${v.toStringAsFixed(1)} m';

final List<LyricVisualizerTuningSpec> machiTuningSpecs =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerChoiceSpec(
        key: machiKeyScene,
        label: () => t.music_visualizer_machi_scene,
        initial: 'auto',
        options: <(String, String Function())>[
          ('auto', () => t.music_visualizer_machi_scene_auto),
          ('konbini', () => t.music_visualizer_machi_scene_konbini),
          ('station', () => t.music_visualizer_machi_scene_station),
          ('kowloon', () => t.music_visualizer_machi_scene_kowloon),
        ],
      ),
      LyricVisualizerChoiceSpec(
        key: machiKeyTimeOfDay,
        label: () => t.music_visualizer_machi_time_of_day,
        initial: 'auto',
        options: <(String, String Function())>[
          ('auto', () => t.music_visualizer_machi_time_auto),
          ('day', () => t.music_visualizer_machi_time_day),
          ('dusk', () => t.music_visualizer_machi_time_dusk),
          ('night', () => t.music_visualizer_machi_time_night),
        ],
      ),
      LyricVisualizerChoiceSpec(
        key: machiKeyWeather,
        label: () => t.music_visualizer_machi_weather,
        initial: 'auto',
        options: <(String, String Function())>[
          ('auto', () => t.music_visualizer_machi_weather_auto),
          ('clear', () => t.music_visualizer_machi_weather_clear),
          ('rain', () => t.music_visualizer_machi_weather_rain),
          ('snow', () => t.music_visualizer_machi_weather_snow),
          ('fog', () => t.music_visualizer_machi_weather_fog),
        ],
      ),
      LyricVisualizerChoiceSpec(
        key: machiKeyCamera,
        label: () => t.music_visualizer_machi_camera,
        initial: 'default',
        options: <(String, String Function())>[
          ('default', () => t.music_visualizer_machi_camera_default),
          ('custom', () => t.music_visualizer_machi_camera_custom),
        ],
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyViewAzimuth,
        label: () => t.music_visualizer_machi_view_azimuth,
        min: -75,
        max: 75,
        initial: 0,
        divisions: 150,
        format: _deg,
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyViewElevation,
        label: () => t.music_visualizer_machi_view_elevation,
        min: -12,
        max: 40,
        initial: 0,
        divisions: 52,
        format: _deg,
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyViewZoom,
        label: () => t.music_visualizer_machi_view_zoom,
        min: 0.5,
        max: 2.8,
        initial: 1,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyViewPanX,
        label: () => t.music_visualizer_machi_view_pan_x,
        min: -5,
        max: 5,
        initial: 0,
        format: _meters,
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyViewPanZ,
        label: () => t.music_visualizer_machi_view_pan_z,
        min: -5,
        max: 5,
        initial: 0,
        format: _meters,
      ),
      LyricVisualizerToggleSpec(
        key: machiKeyMotion,
        label: () => t.music_visualizer_machi_motion,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyMotionSpeed,
        label: () => t.music_visualizer_machi_motion_speed,
        min: 0.25,
        max: 3,
        initial: 1,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyAperture,
        label: () => t.music_visualizer_machi_aperture,
        min: 1.4,
        max: 16,
        initial: 8,
        format: (double v) => 'f/${v < 4 ? v.toStringAsFixed(1) : v.round()}',
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyDof,
        label: () => t.music_visualizer_machi_dof,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyDofRange,
        label: () => t.music_visualizer_machi_dof_range,
        min: 0.3,
        max: 3,
        initial: 1,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyTiltShift,
        label: () => t.music_visualizer_machi_tilt_shift,
        min: 0,
        max: 1,
        initial: 0.3,
      ),
      LyricVisualizerChoiceSpec(
        key: machiKeyFocus,
        label: () => t.music_visualizer_machi_focus,
        initial: 'center',
        options: <(String, String Function())>[
          ('center', () => t.music_visualizer_machi_focus_center),
          ('lyrics', () => t.music_visualizer_machi_focus_lyrics),
          ('manual', () => t.music_visualizer_machi_focus_manual),
        ],
      ),
      LyricVisualizerSliderSpec(
        key: machiKeyFocusOffset,
        label: () => t.music_visualizer_machi_focus_offset,
        min: -10,
        max: 10,
        initial: 0,
        format: _meters,
      ),
      LyricVisualizerToggleSpec(
        key: machiKeySimulatedBeat,
        label: () => t.music_visualizer_machi_simulated_beat,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: machiKeyReflections,
        label: () => t.music_visualizer_machi_reflections,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: machiKeyGlow,
        label: () => t.music_visualizer_machi_glow,
        initial: true,
      ),
    ];

/// 读出来的一份设置。
class MachiSettings {
  MachiSettings(LyricVisualizerTuning tuning)
    : scene = tuning.choice(machiKeyScene, 'auto'),
      timeOfDay = tuning.choice(machiKeyTimeOfDay, 'auto'),
      weather = tuning.choice(machiKeyWeather, 'auto'),
      customView = tuning.choice(machiKeyCamera, 'default') == 'custom',
      azimuth = tuning.number(machiKeyViewAzimuth, 0),
      elevation = tuning.number(machiKeyViewElevation, 0),
      zoom = tuning.number(machiKeyViewZoom, 1),
      panX = tuning.number(machiKeyViewPanX, 0),
      panZ = tuning.number(machiKeyViewPanZ, 0),
      motion = tuning.flag(machiKeyMotion, false),
      motionSpeed = tuning.number(machiKeyMotionSpeed, 1),
      aperture = tuning.number(machiKeyAperture, 8),
      dof = tuning.number(machiKeyDof, 1),
      dofRange = tuning.number(machiKeyDofRange, 1),
      tiltShift = tuning.number(machiKeyTiltShift, 0.3),
      focus = tuning.choice(machiKeyFocus, 'center'),
      focusOffset = tuning.number(machiKeyFocusOffset, 0),
      simulatedBeat = tuning.flag(machiKeySimulatedBeat, true),
      reflections = tuning.flag(machiKeyReflections, true),
      glow = tuning.flag(machiKeyGlow, true);

  final String scene;
  final String timeOfDay;
  final String weather;
  final bool customView;
  final double azimuth;
  final double elevation;
  final double zoom;
  final double panX;
  final double panZ;
  final bool motion;
  final double motionSpeed;
  final double aperture;
  final double dof;
  final double dofRange;
  final double tiltShift;
  final String focus;
  final double focusOffset;
  final bool simulatedBeat;
  final bool reflections;
  final bool glow;
}
