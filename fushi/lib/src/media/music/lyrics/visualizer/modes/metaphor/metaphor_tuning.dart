/// 隐喻的可调参数（folia `metaphor/types.ts` + `tuning.ts`）：同样的默认值和范围。
/// 不移植的：分辨率倍数（Flutter 按设备像素比画）。「湮灭对撞」节拍特效的强度在 folia 是全局的
/// 智能动感设置，这里收成本样式的一项（0 = 关）。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

/// 落库键（冻结）。
abstract final class MetaphorTuningKeys {
  static const String cutPace = 'cutPace';
  static const String cameraMotion = 'cameraMotion';
  static const String flow = 'flow';
  static const String blobs = 'blobs';
  static const String halftone = 'halftone';
  static const String grain = 'grain';
  static const String negative = 'negative';
  static const String flip = 'flip';
  static const String transitions = 'transitions';
  static const String keywordColors = 'keywordColors';
  static const String beatAnnihilation = 'beatAnnihilation';
}

String _times(double v) => '×${v.toStringAsFixed(2)}';

/// 参数声明（面板与落库）。
final List<LyricVisualizerTuningSpec> metaphorTuningSpecs =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerSliderSpec(
        key: MetaphorTuningKeys.cutPace,
        label: () => t.music_visualizer_metaphor_cut_pace,
        min: 0.4,
        max: 2,
        initial: 1,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: MetaphorTuningKeys.cameraMotion,
        label: () => t.music_visualizer_metaphor_camera_motion,
        min: 0,
        max: 2,
        initial: 1,
        format: _times,
      ),
      LyricVisualizerToggleSpec(
        key: MetaphorTuningKeys.negative,
        label: () => t.music_visualizer_metaphor_negative,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: MetaphorTuningKeys.transitions,
        label: () => t.music_visualizer_metaphor_transitions,
        initial: true,
      ),
      LyricVisualizerToggleSpec(
        key: MetaphorTuningKeys.flip,
        label: () => t.music_visualizer_metaphor_flip,
        initial: false,
      ),
      LyricVisualizerToggleSpec(
        key: MetaphorTuningKeys.keywordColors,
        label: () => t.music_visualizer_metaphor_keyword_colors,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: MetaphorTuningKeys.beatAnnihilation,
        label: () => t.music_visualizer_metaphor_beat_annihilation,
        min: 0,
        max: 2,
        initial: 1,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: MetaphorTuningKeys.flow,
        label: () => t.music_visualizer_metaphor_flow,
        min: 0,
        max: 2,
        initial: 1,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: MetaphorTuningKeys.blobs,
        label: () => t.music_visualizer_metaphor_blobs,
        min: 0,
        max: 2,
        initial: 1,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: MetaphorTuningKeys.halftone,
        label: () => t.music_visualizer_metaphor_halftone,
        min: 0.5,
        max: 2.5,
        initial: 1,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: MetaphorTuningKeys.grain,
        label: () => t.music_visualizer_metaphor_grain,
        min: 0,
        max: 2,
        initial: 1,
        format: _times,
      ),
    ];

/// 读好的一份参数。
class MetaphorSettings {
  const MetaphorSettings({
    this.cutPace = 1,
    this.cameraMotion = 1,
    this.flow = 1,
    this.blobs = 1,
    this.halftone = 1,
    this.grain = 1,
    this.negative = true,
    this.flip = false,
    this.transitions = true,
    this.keywordColors = false,
    this.beatAnnihilation = 1,
  });

  factory MetaphorSettings.of(LyricVisualizerTuning t) => MetaphorSettings(
    cutPace: t.number(MetaphorTuningKeys.cutPace, 1),
    cameraMotion: t.number(MetaphorTuningKeys.cameraMotion, 1),
    flow: t.number(MetaphorTuningKeys.flow, 1),
    blobs: t.number(MetaphorTuningKeys.blobs, 1),
    halftone: t.number(MetaphorTuningKeys.halftone, 1),
    grain: t.number(MetaphorTuningKeys.grain, 1),
    negative: t.flag(MetaphorTuningKeys.negative, true),
    flip: t.flag(MetaphorTuningKeys.flip, false),
    transitions: t.flag(MetaphorTuningKeys.transitions, true),
    keywordColors: t.flag(MetaphorTuningKeys.keywordColors, false),
    beatAnnihilation: t.number(MetaphorTuningKeys.beatAnnihilation, 1),
  );

  final double cutPace;
  final double cameraMotion;
  final double flow;
  final double blobs;
  final double halftone;
  final double grain;
  final bool negative;
  final bool flip;
  final bool transitions;

  /// 主题关键字（wordColors）各用自己的颜色；关着时和别的字一样是墨色。
  final bool keywordColors;

  /// 「湮灭对撞」强度（0..2）：对撞挪到拍上、平常的拍放小环；0 = 关。
  final double beatAnnihilation;
}
