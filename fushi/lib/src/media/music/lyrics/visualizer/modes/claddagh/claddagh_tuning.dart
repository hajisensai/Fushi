/// 回环的可调参数（移植 folia `claddagh/tuning.ts` 与设置面板；默认值、范围、步长一致）。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

/// 圆环位置可挪的范围（画面宽 / 高的百分比）。
const double kCladdaghPositionLimitPercent = 40;

/// 主歌词默认放大倍率（folia `DEFAULT_CLADDAGH_TUNING.focusScaleRatio`）。
const double kCladdaghDefaultFocusScaleRatio = 0.65;

String _times(double v) => '${v.toStringAsFixed(2)}×';
String _signedPercent(double v) => '${v > 0 ? '+' : ''}${v.round()}%';
String _spacingPx(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)}px';

/// 参数声明（key 落库，冻结）。
final List<LyricVisualizerTuningSpec> claddaghTuningSpecs =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerSliderSpec(
        key: 'focusScaleRatio',
        label: () => t.music_visualizer_claddagh_focus_scale,
        min: 0,
        max: 1.5,
        initial: kCladdaghDefaultFocusScaleRatio,
        divisions: 30,
        format: (double v) => _times(v + 1),
      ),
      LyricVisualizerSliderSpec(
        key: 'radiusScale',
        label: () => t.music_visualizer_claddagh_radius_scale,
        min: 0.5,
        max: 1.5,
        initial: 1,
        divisions: 20,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: 'positionX',
        label: () => t.music_visualizer_claddagh_position_x,
        min: -kCladdaghPositionLimitPercent,
        max: kCladdaghPositionLimitPercent,
        initial: 0,
        divisions: 80,
        format: _signedPercent,
      ),
      LyricVisualizerSliderSpec(
        key: 'positionY',
        label: () => t.music_visualizer_claddagh_position_y,
        min: -kCladdaghPositionLimitPercent,
        max: kCladdaghPositionLimitPercent,
        initial: 0,
        divisions: 80,
        format: _signedPercent,
      ),
      LyricVisualizerSliderSpec(
        key: 'ellipseTiltDeg',
        label: () => t.music_visualizer_claddagh_tilt,
        min: 0,
        max: 60,
        initial: 45,
        divisions: 60,
        format: (double v) => '${v.round()}°',
      ),
      LyricVisualizerToggleSpec(
        key: 'showAxisLine',
        label: () => t.music_visualizer_claddagh_axis_line,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: 'letterSpacingOffset',
        label: () => t.music_visualizer_claddagh_letter_spacing,
        min: -5,
        max: 20,
        initial: 0,
        divisions: 50,
        format: _spacingPx,
      ),
      LyricVisualizerToggleSpec(
        key: 'showTranslation',
        label: () => t.music_visualizer_claddagh_show_translation,
        initial: false,
      ),
      LyricVisualizerSliderSpec(
        key: 'translationScale',
        label: () => t.music_visualizer_claddagh_translation_scale,
        min: 0.5,
        max: 2,
        initial: 1,
        divisions: 30,
        format: _times,
      ),
      LyricVisualizerSliderSpec(
        key: 'translationLetterSpacingOffset',
        label: () => t.music_visualizer_claddagh_translation_letter_spacing,
        min: -5,
        max: 20,
        initial: 0,
        divisions: 50,
        format: _spacingPx,
      ),
    ];

/// 读出来的参数。
class CladdaghTuning {
  CladdaghTuning.from(LyricVisualizerTuning t)
    : focusScaleRatio = t.number(
        'focusScaleRatio',
        kCladdaghDefaultFocusScaleRatio,
      ),
      radiusScale = t.number('radiusScale', 1),
      positionX = t.number('positionX', 0),
      positionY = t.number('positionY', 0),
      ellipseTiltDeg = t.number('ellipseTiltDeg', 45),
      showAxisLine = t.flag('showAxisLine', true),
      letterSpacingOffset = t.number('letterSpacingOffset', 0),
      showTranslation = t.flag('showTranslation', false),
      translationScale = t.number('translationScale', 1),
      translationLetterSpacingOffset = t.number(
        'translationLetterSpacingOffset',
        0,
      );

  final double focusScaleRatio;
  final double radiusScale;
  final double positionX;
  final double positionY;
  final double ellipseTiltDeg;
  final bool showAxisLine;
  final double letterSpacingOffset;
  final bool showTranslation;
  final double translationScale;
  final double translationLetterSpacingOffset;

  /// 主歌词字距随放大倍率等比放宽（默认倍率时为 1）。
  double get focusSpacingScale =>
      (1 + focusScaleRatio) / (1 + kCladdaghDefaultFocusScaleRatio);

  /// 中轴线的角度：与椭圆长轴垂直。
  double get centerNormalTiltDeg => 90 - ellipseTiltDeg;
}
