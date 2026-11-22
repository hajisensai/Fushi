/// 莫奈的可调参数（folia `monet/tuning.ts`）：键名沿用 folia 字段名（落库冻结），默认值与范围照搬。
/// 背景参数在共享背景「莫奈」（`backgrounds/monet_background.dart`）里，样式请求那个背景。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

/// 落库键（冻结）。
abstract final class MonetTuningKeys {
  static const String keywordColoringEnabled = 'keywordColoringEnabled';
  static const String fontScale = 'fontScale';
  static const String customDescription = 'customDescription';
  static const String portraitPack = 'portraitPack';
  static const String descriptionVisibility = 'descriptionVisibility';
  static const String showAudioVisualization = 'showAudioVisualization';
  static const String audioStyle = 'audioStyle';
  static const String portraitSource = 'portraitSource';
  static const String portraitStyle = 'portraitStyle';
  static const String portraitOffsetX = 'portraitOffsetX';
  static const String mirrorLayout = 'mirrorLayout';
}

/// 素材目录名（`visualizer_assets/monet/<包>/`）。
const String kMonetAssetStyle = 'monet';

/// folia `MONET_CUSTOM_DESCRIPTION_MAX_LENGTH`。
const int kMonetCustomDescriptionMaxLength = 120;

String _px(double v) => '${v.round()} px';
String _times(double v) => '×${v.toStringAsFixed(2)}';

/// 参数声明（宿主据此画参数面板）。
final List<LyricVisualizerTuningSpec> monetTuningSpecs =
    <LyricVisualizerTuningSpec>[
      // folia：AI 主题的 wordColors 给计时词着色；关掉就统一用主色。
      LyricVisualizerToggleSpec(
        key: MonetTuningKeys.keywordColoringEnabled,
        label: () => t.music_visualizer_monet_keyword_coloring,
        initial: true,
      ),
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
      // folia `customDescription`：空着就显示主题描述 / 名字，再没有显示「莫奈」。
      LyricVisualizerTextSpec(
        key: MonetTuningKeys.customDescription,
        label: () => t.music_visualizer_monet_custom_description,
        hint: () => t.music_visualizer_monet_custom_description_hint,
        maxLength: kMonetCustomDescriptionMaxLength,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.choice(MonetTuningKeys.descriptionVisibility, 'auto') != 'hidden',
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
          ('custom', () => t.music_visualizer_monet_portrait_custom),
          ('none', () => t.music_visualizer_monet_portrait_none),
        ],
        initial: 'cover',
      ),
      // folia 的自定义立绘：这里是素材包，用最后导入的那张（再导一张就换掉）。
      LyricVisualizerAssetPackSpec(
        key: MonetTuningKeys.portraitPack,
        label: () => t.music_visualizer_monet_portrait_pack,
        style: kMonetAssetStyle,
        maxFiles: 16,
        visibleWhen: (LyricVisualizerTuning v) =>
            v.choice(MonetTuningKeys.portraitSource, 'cover') == 'custom',
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
    : keywordColoring = tu.flag(MonetTuningKeys.keywordColoringEnabled, true),
      customDescription = tu.text(MonetTuningKeys.customDescription, '').trim(),
      portraitSource = tu.choice(MonetTuningKeys.portraitSource, 'cover'),
      portraitPack = tu.assetPack(MonetTuningKeys.portraitPack, 'default'),
      fontScale = tu.number(MonetTuningKeys.fontScale, 1.2),
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

  /// 主题按词着色（folia `keywordColoringEnabled`）。
  final bool keywordColoring;

  /// 用户写的描述（已去首尾空白；空 = 用主题描述 / 样式名）。
  final String customDescription;

  /// cover / custom / none。
  final String portraitSource;

  /// 自定义肖像的素材包名。
  final String portraitPack;

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
