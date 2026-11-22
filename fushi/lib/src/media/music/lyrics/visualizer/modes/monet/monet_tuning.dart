/// 莫奈的可调参数（folia `monet/tuning.ts`）：键名沿用 folia 字段名（落库冻结），默认值与范围照搬。
/// 背景参数在共享背景「莫奈」（`backgrounds/monet_background.dart`）里，样式请求那个背景。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

/// 落库键（冻结）。
abstract final class MonetTuningKeys {
  static const String fontScale = 'fontScale';
  static const String descriptionVisibility = 'descriptionVisibility';
  static const String showAudioVisualization = 'showAudioVisualization';
  static const String audioStyle = 'audioStyle';
  static const String portraitSource = 'portraitSource';
  static const String portraitStyle = 'portraitStyle';
  static const String portraitOffsetX = 'portraitOffsetX';
  static const String mirrorLayout = 'mirrorLayout';
}

String _px(double v) => '${v.round()} px';
String _times(double v) => '×${v.toStringAsFixed(2)}';

/// 参数声明（宿主据此画参数面板）。
final List<LyricVisualizerTuningSpec> monetTuningSpecs =
    <LyricVisualizerTuningSpec>[
      LyricVisualizerSliderSpec(
        key: MonetTuningKeys.fontScale,
        label: () => t.music_visualizer_monet_font_scale,
        min: 0.7,
        max: 1.5,
        initial: 1.2,
        divisions: 16,
        format: _times,
      ),
      LyricVisualizerChoiceSpec(
        key: MonetTuningKeys.descriptionVisibility,
        label: () => t.music_visualizer_monet_show_description,
        options: <(String, String Function())>[
          ('auto', () => t.music_visualizer_monet_visibility_auto),
          ('always', () => t.music_visualizer_monet_visibility_always),
          ('hidden', () => t.music_visualizer_monet_visibility_hidden),
        ],
        initial: 'auto',
      ),
      LyricVisualizerToggleSpec(
        key: MonetTuningKeys.showAudioVisualization,
        label: () => t.music_visualizer_monet_show_audio,
        initial: true,
      ),
      LyricVisualizerChoiceSpec(
        key: MonetTuningKeys.audioStyle,
        label: () => t.music_visualizer_monet_audio_style,
        options: <(String, String Function())>[
          ('bar', () => t.music_visualizer_monet_audio_bar),
          ('line', () => t.music_visualizer_monet_audio_line),
        ],
        initial: 'bar',
      ),
      LyricVisualizerChoiceSpec(
        key: MonetTuningKeys.portraitSource,
        label: () => t.music_visualizer_monet_portrait_source,
        options: <(String, String Function())>[
          ('cover', () => t.music_visualizer_monet_portrait_cover),
          ('none', () => t.music_visualizer_monet_portrait_none),
        ],
        initial: 'cover',
      ),
      LyricVisualizerChoiceSpec(
        key: MonetTuningKeys.portraitStyle,
        label: () => t.music_visualizer_monet_portrait_style,
        options: <(String, String Function())>[
          ('square', () => t.music_visualizer_monet_portrait_square),
          ('rectangular', () => t.music_visualizer_monet_portrait_rectangular),
        ],
        initial: 'square',
      ),
      // folia 在画面上拖动封面得到这个值（负数 = 朝屏幕中间）；这里没有拖拽，改成滑杆。
      LyricVisualizerSliderSpec(
        key: MonetTuningKeys.portraitOffsetX,
        label: () => t.music_visualizer_monet_portrait_offset,
        min: -150,
        max: 0,
        initial: 0,
        divisions: 30,
        format: _px,
      ),
      LyricVisualizerToggleSpec(
        key: MonetTuningKeys.mirrorLayout,
        label: () => t.music_visualizer_monet_mirror,
        initial: false,
      ),
    ];

/// 读出来的整套参数。
class MonetConfig {
  MonetConfig.from(LyricVisualizerTuning tu)
    : fontScale = tu.number(MonetTuningKeys.fontScale, 1.2),
      descriptionVisibility = tu.choice(
        MonetTuningKeys.descriptionVisibility,
        'auto',
      ),
      showAudio = tu.flag(MonetTuningKeys.showAudioVisualization, true),
      audioLine = tu.choice(MonetTuningKeys.audioStyle, 'bar') == 'line',
      showPortrait =
          tu.choice(MonetTuningKeys.portraitSource, 'cover') != 'none',
      squarePortrait =
          tu.choice(MonetTuningKeys.portraitStyle, 'square') == 'square',
      portraitOffsetX = tu.number(MonetTuningKeys.portraitOffsetX, 0),
      mirrored = tu.flag(MonetTuningKeys.mirrorLayout, false);

  final double fontScale;

  /// auto / always / hidden。
  final String descriptionVisibility;
  final bool showAudio;
  final bool audioLine;
  final bool showPortrait;
  final bool squarePortrait;

  /// ≤ 0：朝屏幕中间挪的 px（按原版方向记，镜像时翻过来）。
  final double portraitOffsetX;
  final bool mirrored;
}
