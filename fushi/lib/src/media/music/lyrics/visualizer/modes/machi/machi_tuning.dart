/// 町景的可调参数（folia `machi/types.ts` + `tuning.ts`）：场景 / 时间 / 天气（都可以“自动”）、
/// 视角（默认 / 自定义；自定义视角按场景各存一份五项滑块，folia `views`）、运镜与快慢、景深（光圈、强度、
/// 清晰范围、移轴、对焦）、模拟节拍、霓虹随拍强度、倒影、辉光。默认值与范围照 folia。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_director.dart';

const String machiKeyScene = 'scene';
const String machiKeyTimeOfDay = 'time_of_day';
const String machiKeyWeather = 'weather';
const String machiKeyCamera = 'camera';

/// 自定义视角的五项（每个场景各一份，键 `view_<场景>_<项>`）。
const String machiViewAzimuth = 'azimuth';
const String machiViewElevation = 'elevation';
const String machiViewZoom = 'zoom';
const String machiViewPanX = 'pan_x';
const String machiViewPanZ = 'pan_z';

/// 场景 [scene] 的视角项 [field] 的落库键。
String machiViewKey(MachiSceneId scene, String field) =>
    'view_${scene.name}_$field';
const String machiKeyMotion = 'motion';
const String machiKeyMotionSpeed = 'motion_speed';
const String machiKeyAperture = 'aperture';
const String machiKeyDof = 'dof';
const String machiKeyDofRange = 'dof_range';
const String machiKeyTiltShift = 'tilt_shift';
const String machiKeyFocus = 'focus';
const String machiKeyFocusOffset = 'focus_offset';
const String machiKeySimulatedBeat = 'simulated_beat';
const String machiKeyNeonPulse = 'neon_pulse';
const String machiKeyDrumRipple = 'drum_ripple';
const String machiKeyScreenFlash = 'screen_flash';
const String machiKeyReflections = 'reflections';
const String machiKeyGlow = 'glow';

String _deg(double v) => '${v.round()}°';
String _times(double v) => '${v.toStringAsFixed(2)}×';
String _meters(double v) => '${v.toStringAsFixed(1)} m';

bool _customView(LyricVisualizerTuning v) =>
    v.choice(machiKeyCamera, 'default') == 'custom';

const LyricVisualizerTuningSection _viewSection = LyricVisualizerTuningSection(
  key: 'machi_view',
  label: _viewSectionLabel,
);

String _viewSectionLabel() => t.music_visualizer_machi_view_group;

String Function() _sceneLabel(MachiSceneId id) => switch (id) {
  MachiSceneId.konbini => () => t.music_visualizer_machi_scene_konbini,
  MachiSceneId.station => () => t.music_visualizer_machi_scene_station,
  MachiSceneId.kowloon => () => t.music_visualizer_machi_scene_kowloon,
};

/// 一个场景的五项视角滑块：收在「自定义视角」下按场景分组；只在选了自定义、且场景是「自动」或就是这个
/// 场景时显示。
List<LyricVisualizerTuningSpec> _viewSpecs(MachiSceneId id) {
  final LyricVisualizerTuningSection section = LyricVisualizerTuningSection(
    key: 'machi_view_${id.name}',
    label: _sceneLabel(id),
    parent: _viewSection,
  );
  bool visible(LyricVisualizerTuning v) {
    if (!_customView(v)) return false;
    final String scene = v.choice(machiKeyScene, 'auto');
    return scene == 'auto' || scene == id.name;
  }

  return <LyricVisualizerTuningSpec>[
    LyricVisualizerSliderSpec(
      key: machiViewKey(id, machiViewAzimuth),
      label: () => t.music_visualizer_machi_view_azimuth,
      section: section,
      visibleWhen: visible,
      min: -75,
      max: 75,
      initial: 0,
      divisions: 150,
      format: _deg,
    ),
    LyricVisualizerSliderSpec(
      key: machiViewKey(id, machiViewElevation),
      label: () => t.music_visualizer_machi_view_elevation,
      section: section,
      visibleWhen: visible,
      min: -12,
      max: 40,
      initial: 0,
      divisions: 52,
      format: _deg,
    ),
    LyricVisualizerSliderSpec(
      key: machiViewKey(id, machiViewZoom),
      label: () => t.music_visualizer_machi_view_zoom,
      section: section,
      visibleWhen: visible,
      min: 0.5,
      max: 2.8,
      initial: 1,
      format: _times,
    ),
    LyricVisualizerSliderSpec(
      key: machiViewKey(id, machiViewPanX),
      label: () => t.music_visualizer_machi_view_pan_x,
      section: section,
      visibleWhen: visible,
      min: -5,
      max: 5,
      initial: 0,
      format: _meters,
    ),
    LyricVisualizerSliderSpec(
      key: machiViewKey(id, machiViewPanZ),
      label: () => t.music_visualizer_machi_view_pan_z,
      section: section,
      visibleWhen: visible,
      min: -5,
      max: 5,
      initial: 0,
      format: _meters,
    ),
  ];
}

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
      for (final MachiSceneId id in MachiSceneId.values) ..._viewSpecs(id),
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
      // folia 智能动感「霓虹随拍」的强度（folia 是全局设置，这里收成本样式的一项）：有节拍网格时霓虹跟真拍子；
      // 0 = 关（关了以后有「模拟节拍」时仍按固定节拍）。
      LyricVisualizerSliderSpec(
        key: machiKeyNeonPulse,
        label: () => t.music_visualizer_machi_neon_pulse,
        min: 0,
        max: 2,
        initial: 1,
        format: _times,
      ),
      // folia 智能动感「鼓点涟漪」：每下底鼓从歌词屏脚下在湿地面上荡开一圈（地面干时光斑跳一下）；0 = 关。
      LyricVisualizerSliderSpec(
        key: machiKeyDrumRipple,
        label: () => t.music_visualizer_machi_drum_ripple,
        min: 0,
        max: 2,
        initial: 1,
        format: _times,
      ),
      // folia 智能动感「大屏闪拍」：每下军鼓在歌词屏一处慢慢亮起再暗下；0 = 关（有「模拟节拍」时仍按固定节拍）。
      LyricVisualizerSliderSpec(
        key: machiKeyScreenFlash,
        label: () => t.music_visualizer_machi_screen_flash,
        min: 0,
        max: 2,
        initial: 1,
        format: _times,
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
      views = <MachiSceneId, MachiCustomView>{
        for (final MachiSceneId id in MachiSceneId.values)
          id: MachiCustomView(
            azimuth: tuning.number(machiViewKey(id, machiViewAzimuth), 0),
            elevation: tuning.number(machiViewKey(id, machiViewElevation), 0),
            zoom: tuning.number(machiViewKey(id, machiViewZoom), 1),
            panX: tuning.number(machiViewKey(id, machiViewPanX), 0),
            panZ: tuning.number(machiViewKey(id, machiViewPanZ), 0),
          ),
      },
      motion = tuning.flag(machiKeyMotion, false),
      motionSpeed = tuning.number(machiKeyMotionSpeed, 1),
      aperture = tuning.number(machiKeyAperture, 8),
      dof = tuning.number(machiKeyDof, 1),
      dofRange = tuning.number(machiKeyDofRange, 1),
      tiltShift = tuning.number(machiKeyTiltShift, 0.3),
      focus = tuning.choice(machiKeyFocus, 'center'),
      focusOffset = tuning.number(machiKeyFocusOffset, 0),
      simulatedBeat = tuning.flag(machiKeySimulatedBeat, true),
      neonPulse = tuning.number(machiKeyNeonPulse, 1),
      drumRipple = tuning.number(machiKeyDrumRipple, 1),
      screenFlash = tuning.number(machiKeyScreenFlash, 1),
      reflections = tuning.flag(machiKeyReflections, true),
      glow = tuning.flag(machiKeyGlow, true);

  final String scene;
  final String timeOfDay;
  final String weather;
  final bool customView;

  /// 每个场景自己的自定义视角。
  final Map<MachiSceneId, MachiCustomView> views;

  /// 场景 [id] 的自定义视角。
  MachiCustomView viewOf(MachiSceneId id) => views[id]!;
  final bool motion;
  final double motionSpeed;
  final double aperture;
  final double dof;
  final double dofRange;
  final double tiltShift;
  final String focus;
  final double focusOffset;
  final bool simulatedBeat;

  /// 霓虹随拍强度（0..2）。
  final double neonPulse;

  /// 鼓点涟漪强度（0..2）。
  final double drumRipple;

  /// 大屏闪拍强度（0..2）。
  final double screenFlash;
  final bool reflections;
  final bool glow;
}

/// 一个场景的自定义视角（folia `MachiCameraView`）。
class MachiCustomView {
  const MachiCustomView({
    this.azimuth = 0,
    this.elevation = 0,
    this.zoom = 1,
    this.panX = 0,
    this.panZ = 0,
  });

  final double azimuth;
  final double elevation;
  final double zoom;
  final double panX;
  final double panZ;
}
