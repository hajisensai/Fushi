/// 莫奈的可调参数（folia `monet/tuning.ts` + `backgrounds/monet/tuning.ts`）：键名沿用 folia
/// 字段名（落库冻结），默认值与范围照搬。folia 里背景是另一套可选背景，这里并进样式自己画。
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
  static const String backgroundLayout = 'backgroundLayout';
  static const String backgroundBlurPx = 'backgroundBlurPx';
  static const String backgroundOverlayOpacity = 'backgroundOverlayOpacity';
  static const String backgroundGrayscale = 'backgroundGrayscale';
  static const String backgroundSaturation = 'backgroundSaturation';
  static const String backgroundWash = 'backgroundWash';
  static const String backgroundHalfPaneOffsetX = 'backgroundHalfPaneOffsetX';
  static const String backgroundDriftEnabled = 'backgroundDriftEnabled';
  static const String backgroundDriftStrength = 'backgroundDriftStrength';
  static const String backgroundStreaksEnabled = 'backgroundStreaksEnabled';
}

String _percent(double v) => '${(v * 100).round()}%';
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
      LyricVisualizerChoiceSpec(
        key: MonetTuningKeys.backgroundLayout,
        label: () => t.music_visualizer_monet_background_layout,
        options: <(String, String Function())>[
          ('full-overlay', () => t.music_visualizer_monet_layout_full),
          ('half-pane-gradient', () => t.music_visualizer_monet_layout_half),
        ],
        initial: 'full-overlay',
      ),
      LyricVisualizerSliderSpec(
        key: MonetTuningKeys.backgroundBlurPx,
        label: () => t.music_visualizer_monet_background_blur,
        min: 0,
        max: 60,
        initial: 6,
        divisions: 60,
        format: _px,
      ),
      LyricVisualizerSliderSpec(
        key: MonetTuningKeys.backgroundOverlayOpacity,
        label: () => t.music_visualizer_monet_background_overlay,
        min: 0,
        max: 1,
        initial: 0.74,
        divisions: 100,
        format: _percent,
      ),
      LyricVisualizerSliderSpec(
        key: MonetTuningKeys.backgroundGrayscale,
        label: () => t.music_visualizer_monet_background_grayscale,
        min: 0,
        max: 1,
        initial: 0,
        divisions: 100,
        format: _percent,
      ),
      LyricVisualizerSliderSpec(
        key: MonetTuningKeys.backgroundSaturation,
        label: () => t.music_visualizer_monet_background_saturation,
        min: 0,
        max: 2,
        initial: 1.05,
        divisions: 40,
        format: _percent,
      ),
      LyricVisualizerSliderSpec(
        key: MonetTuningKeys.backgroundWash,
        label: () => t.music_visualizer_monet_background_wash,
        min: 0,
        max: 1,
        initial: 0.34,
        divisions: 100,
        format: _percent,
      ),
      LyricVisualizerSliderSpec(
        key: MonetTuningKeys.backgroundHalfPaneOffsetX,
        label: () => t.music_visualizer_monet_background_offset,
        min: -40,
        max: 40,
        initial: 0,
        divisions: 80,
        format: (double v) => '${v.round()}%',
      ),
      LyricVisualizerToggleSpec(
        key: MonetTuningKeys.backgroundDriftEnabled,
        label: () => t.music_visualizer_monet_background_drift,
        initial: true,
      ),
      LyricVisualizerSliderSpec(
        key: MonetTuningKeys.backgroundDriftStrength,
        label: () => t.music_visualizer_monet_background_drift_strength,
        min: 0,
        max: 1,
        initial: 0.5,
        divisions: 20,
        format: _percent,
      ),
      LyricVisualizerToggleSpec(
        key: MonetTuningKeys.backgroundStreaksEnabled,
        label: () => t.music_visualizer_monet_background_streaks,
        initial: true,
      ),
    ];

/// 封面后处理（会触发重新烘焙背景图的那几项）。
class MonetBackgroundTreatment {
  const MonetBackgroundTreatment({
    required this.blurPx,
    required this.overlay,
    required this.grayscale,
    required this.saturation,
    required this.wash,
    required this.streaks,
  });

  final double blurPx;
  final double overlay;
  final double grayscale;
  final double saturation;
  final double wash;
  final bool streaks;

  @override
  bool operator ==(Object other) =>
      other is MonetBackgroundTreatment &&
      other.blurPx == blurPx &&
      other.overlay == overlay &&
      other.grayscale == grayscale &&
      other.saturation == saturation &&
      other.wash == wash &&
      other.streaks == streaks;

  @override
  int get hashCode =>
      Object.hash(blurPx, overlay, grayscale, saturation, wash, streaks);
}

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
      mirrored = tu.flag(MonetTuningKeys.mirrorLayout, false),
      halfPane =
          tu.choice(MonetTuningKeys.backgroundLayout, 'full-overlay') ==
          'half-pane-gradient',
      halfPaneOffsetX = tu.number(MonetTuningKeys.backgroundHalfPaneOffsetX, 0),
      driftEnabled = tu.flag(MonetTuningKeys.backgroundDriftEnabled, true),
      driftStrength = tu.number(MonetTuningKeys.backgroundDriftStrength, 0.5),
      treatment = MonetBackgroundTreatment(
        blurPx: tu.number(MonetTuningKeys.backgroundBlurPx, 6),
        overlay: tu.number(MonetTuningKeys.backgroundOverlayOpacity, 0.74),
        grayscale: tu.number(MonetTuningKeys.backgroundGrayscale, 0),
        saturation: tu.number(MonetTuningKeys.backgroundSaturation, 1.05),
        wash: tu.number(MonetTuningKeys.backgroundWash, 0.34),
        streaks: tu.flag(MonetTuningKeys.backgroundStreaksEnabled, true),
      );

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
  final bool halfPane;
  final double halfPaneOffsetX;
  final bool driftEnabled;
  final double driftStrength;
  final MonetBackgroundTreatment treatment;
}
