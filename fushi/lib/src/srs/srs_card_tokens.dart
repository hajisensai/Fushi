/// 复习卡面（Fushi 卡片）的设计系统令牌：原生卡面（srs_fushi_card_view.dart）与卡面 WebView
/// 的注入变量（srs_card_appearance.dart）共用这一份，切换设计系统时两边一起变。
///
/// - MD3：M3E 形状分级（卡 20 / 小件 12）、M3E 字阶、M3 表面色阶（surfaceContainer 三档）。
/// - Apple：inset grouped 圆角（iOS 24 / 桌面 12）、内嵌块圆角、Apple HIG 字阶、Apple 26
///   分组背景色阶（实色）。
///
/// 卡面模板（packages/fushi_anki/templates/fushi_card/styling.css）按 M3E 字阶设计（正文 16）；
/// 注入给模板的字号倍率 = 用户倍率 × 当前设计系统正文 / M3E 正文，模板正文因此落在当前设计
/// 系统的正文字号上。模板本身不改（原生渲染按「笔记类型 CSS 与内置模板逐字一致」判定）。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_card_appearance.dart' show SrsCardDensity;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart'
    show FushiM3eShape;
import 'package:fushi/src/utils/components/fushi_neutral_decor.dart'
    show fushiNeutralBlockRadiusValue;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;

@immutable
class SrsCardTokens {
  const SrsCardTokens({
    required this.apple,
    required this.applePalette,
    required this.textTheme,
    required this.radius,
    required this.radiusSmall,
    required this.radiusInner,
    this.spacing = const FushiSpacingTokens(),
  });

  /// 从主题解析（没有 BuildContext 的装配点用；与 [SrsCardTokens.of] 同一判据）。
  factory SrsCardTokens.fromTheme(ThemeData theme) {
    final bool apple = isGlassDesignTheme(theme);
    return SrsCardTokens(
      apple: apple,
      applePalette: apple ? theme.extension<FushiAppleColors>() : null,
      textTheme: theme.textTheme,
      radius: apple
          ? FushiAppleMetrics.forPlatform(theme.platform).groupRadius
          : FushiM3eShape.card,
      radiusSmall: fushiNeutralBlockRadiusValue(apple: apple),
      radiusInner: FushiRadii.chipValue,
    );
  }

  static SrsCardTokens of(BuildContext context) =>
      SrsCardTokens.fromTheme(Theme.of(context));

  /// Apple（Cupertino）设计系统。
  final bool apple;

  /// Apple 色板（Apple 设计系统且主题挂了色板时非空）。
  final FushiAppleColors? applePalette;

  /// 当前设计系统的字阶（MD3 = M3E 字阶，Apple = HIG 字阶）。
  final TextTheme textTheme;

  /// 卡面外层块（例句卡、释义分组）圆角：MD3 卡档 / Apple inset grouped。
  final double radius;

  /// 卡内小块（图片、标签底、释义内嵌块）圆角：MD3 小件档 / Apple 内嵌块。
  final double radiusSmall;

  /// 释义里的行内小底块圆角。
  final double radiusInner;

  final FushiSpacingTokens spacing;

  /// 卡面配色 [scheme]（跟随 app 或自定义强调色）在当前设计系统下的表面色阶（实色，
  /// 卡面是内容层，不随玻璃材质半透明）。
  FushiSurfaceColors surfacesFor(ColorScheme scheme) =>
      FushiSurfaceColors.fromScheme(scheme, apple: applePalette);

  /// 表面三档（模板 `--fc-surface-1/2/3`）：MD3 = surfaceContainer / High / Highest；
  /// Apple = 分组背景二 / 三级 / systemGray5 档。
  Color surface1(ColorScheme scheme) {
    final FushiSurfaceColors s = surfacesFor(scheme);
    return apple ? s.group : s.card;
  }

  Color surface2(ColorScheme scheme) {
    final FushiSurfaceColors s = surfacesFor(scheme);
    return apple ? s.card : s.search;
  }

  Color surface3(ColorScheme scheme) {
    final FushiSurfaceColors s = surfacesFor(scheme);
    return apple ? s.search : s.overlay;
  }

  TextStyle _role(TextStyle? role, FushiTypeSpec md3) =>
      role ?? md3.applyTo(const TextStyle());

  /// 正文（模板 `--fc-size-body`）。
  TextStyle get body => _role(textTheme.bodyLarge, FushiTypeScale.bodyLarge);

  /// 次要正文：提示、例句翻译。
  TextStyle get bodySecondary =>
      _role(textTheme.bodyMedium, FushiTypeScale.bodyMedium);

  /// 读音 / 音调、背面例句。
  TextStyle get emphasisLine =>
      _role(textTheme.titleLarge, FushiTypeScale.titleLarge);

  /// 来源等说明文字。
  TextStyle get caption => _role(textTheme.bodySmall, FushiTypeScale.bodySmall);

  /// 标签 / 词频底块与元信息标题。
  TextStyle get label =>
      _role(textTheme.labelMedium, FushiTypeScale.labelMedium);

  /// 例句注音。
  TextStyle get ruby => _role(textTheme.labelSmall, FushiTypeScale.labelSmall);

  /// 正面例句的字号区间（随卡面宽度在两档之间取）。
  TextStyle get frontSentenceMin =>
      _role(textTheme.headlineSmall, FushiTypeScale.headlineSmall);
  TextStyle get frontSentenceMax =>
      _role(textTheme.displaySmall, FushiTypeScale.displaySmall);

  /// 背面词条的字号区间。
  TextStyle get termMin =>
      _role(textTheme.displaySmall, FushiTypeScale.displaySmall);
  TextStyle get termMax =>
      _role(textTheme.displayMedium, FushiTypeScale.displayMedium);

  /// 正面大字词条的下限（上限是它的两倍）。
  TextStyle get hero =>
      _role(textTheme.displayLarge, FushiTypeScale.displayLarge);

  static double _size(TextStyle s, FushiTypeSpec md3) => s.fontSize ?? md3.size;

  /// 注入模板的正文倍率因子：当前设计系统正文 / M3E 正文（MD3 = 1）。
  double get templateTextRatio =>
      _size(body, FushiTypeScale.bodyLarge) / FushiTypeScale.bodyLarge.size;

  /// 注入模板的词条倍率因子：当前设计系统 display-small / M3E display-small。
  double get templateTermRatio =>
      _size(termMin, FushiTypeScale.displaySmall) /
      FushiTypeScale.displaySmall.size;

  /// 区块间距：标准档 = 两个间距单位；紧凑 / 宽松按模板密度档的比例缩放。
  double gap(SrsCardDensity density) =>
      spacing.gap * 2 * _densityGapFactor(density);

  /// 区块内边距：标准档 = 行水平内边距。
  double pad(SrsCardDensity density) =>
      spacing.rowHorizontal * _densityPadFactor(density);

  static double _densityGapFactor(SrsCardDensity d) => switch (d) {
    SrsCardDensity.compact => 0.625,
    SrsCardDensity.standard => 1,
    SrsCardDensity.comfortable => 1.375,
  };

  static double _densityPadFactor(SrsCardDensity d) => switch (d) {
    SrsCardDensity.compact => 0.75,
    SrsCardDensity.standard => 1,
    SrsCardDensity.comfortable => 1.25,
  };
}
