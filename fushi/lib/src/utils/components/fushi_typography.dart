import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';

/// M3 Expressive 字阶的统一入口（2026-10-05 排版统一为 M3E）：15 个基础角色 +
/// 15 个 Emphasized 变体 + 数字用的等宽数字（tabular figures）。
///
/// ```dart
/// final FushiTypography type = context.fushiType;
/// Text(title, style: type.titleLargeEmphasized);
/// Text('42%', style: type.displaySmallEmphasized.tabular);
/// ```
///
/// - 基础角色就是 `Theme.of(context).textTheme` 的同名槽位（字号 / 行高 / 字距
///   来自 [FushiTypeScale]，Apple 设计系统来自 [FushiAppleTypeScale]），带着
///   用户 UI 字体链与显示语言的 locale / 基线。
/// - Emphasized = 同字号同行高、加重字重（M3E：display / headline / titleLarge /
///   body → Medium，titleMedium / titleSmall / label → Bold；Apple = HIG
///   emphasized，升一档）。Windows / Linux 上 Medium 取整到 Semibold
///   （[fushiPlatformFontWeight]）。
/// - **只管 UI 字体排版**：阅读器正文、漫画 OCR 文字层、歌词、字幕等用户可配
///   字体的内容区各自有字体 / 字号设置，不从这里取。
@immutable
class FushiTypography {
  const FushiTypography._(this.textTheme, {required this.apple});

  /// 由主题字阶构建。[apple] 为 true 时 Emphasized 取 HIG 的加重档。
  factory FushiTypography.fromTextTheme(
    TextTheme textTheme, {
    required bool apple,
  }) => FushiTypography._(textTheme, apple: apple);

  /// 当前主题的字阶（按 TextTheme 身份缓存，主题不变时不重建）。
  static FushiTypography of(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool apple = theme.extension<FushiAppleColors>() != null;
    final FushiTypography? cached = _cached;
    if (cached != null &&
        identical(cached.textTheme, theme.textTheme) &&
        cached.apple == apple) {
      return cached;
    }
    return _cached = FushiTypography._(theme.textTheme, apple: apple);
  }

  static FushiTypography? _cached;

  final TextTheme textTheme;
  final bool apple;

  List<FushiTypeSpec> get _specs =>
      apple ? FushiAppleTypeScale.roles : FushiTypeScale.roles;

  TextStyle _role(TextStyle? style) => style ?? const TextStyle();

  TextStyle _emphasized(TextStyle? style, int index) => _role(style).copyWith(
    fontWeight: fushiPlatformFontWeight(_specs[index].emphasizedWeight),
  );

  TextStyle get displayLarge => _role(textTheme.displayLarge);
  TextStyle get displayMedium => _role(textTheme.displayMedium);
  TextStyle get displaySmall => _role(textTheme.displaySmall);
  TextStyle get headlineLarge => _role(textTheme.headlineLarge);
  TextStyle get headlineMedium => _role(textTheme.headlineMedium);
  TextStyle get headlineSmall => _role(textTheme.headlineSmall);
  TextStyle get titleLarge => _role(textTheme.titleLarge);
  TextStyle get titleMedium => _role(textTheme.titleMedium);
  TextStyle get titleSmall => _role(textTheme.titleSmall);
  TextStyle get bodyLarge => _role(textTheme.bodyLarge);
  TextStyle get bodyMedium => _role(textTheme.bodyMedium);
  TextStyle get bodySmall => _role(textTheme.bodySmall);
  TextStyle get labelLarge => _role(textTheme.labelLarge);
  TextStyle get labelMedium => _role(textTheme.labelMedium);
  TextStyle get labelSmall => _role(textTheme.labelSmall);

  TextStyle get displayLargeEmphasized =>
      _emphasized(textTheme.displayLarge, 0);
  TextStyle get displayMediumEmphasized =>
      _emphasized(textTheme.displayMedium, 1);
  TextStyle get displaySmallEmphasized =>
      _emphasized(textTheme.displaySmall, 2);
  TextStyle get headlineLargeEmphasized =>
      _emphasized(textTheme.headlineLarge, 3);
  TextStyle get headlineMediumEmphasized =>
      _emphasized(textTheme.headlineMedium, 4);
  TextStyle get headlineSmallEmphasized =>
      _emphasized(textTheme.headlineSmall, 5);
  TextStyle get titleLargeEmphasized => _emphasized(textTheme.titleLarge, 6);
  TextStyle get titleMediumEmphasized => _emphasized(textTheme.titleMedium, 7);
  TextStyle get titleSmallEmphasized => _emphasized(textTheme.titleSmall, 8);
  TextStyle get bodyLargeEmphasized => _emphasized(textTheme.bodyLarge, 9);
  TextStyle get bodyMediumEmphasized => _emphasized(textTheme.bodyMedium, 10);
  TextStyle get bodySmallEmphasized => _emphasized(textTheme.bodySmall, 11);
  TextStyle get labelLargeEmphasized => _emphasized(textTheme.labelLarge, 12);
  TextStyle get labelMediumEmphasized => _emphasized(textTheme.labelMedium, 13);
  TextStyle get labelSmallEmphasized => _emphasized(textTheme.labelSmall, 14);
}

/// `context.fushiType` 简写。
extension FushiTypographyContext on BuildContext {
  FushiTypography get fushiType => FushiTypography.of(this);
}

/// 数字排版。
extension FushiTextStyleFigures on TextStyle {
  /// 等宽数字（OpenType `tnum`）：时间、进度百分比、计数等会逐帧变化的数字用
  /// 它，变化时宽度不跳、列对齐。保留样式已有的其它 font feature（例如 UI 字体
  /// 关掉的 `liga`）。
  TextStyle get tabular {
    final List<FontFeature> features = <FontFeature>[
      for (final FontFeature f in fontFeatures ?? const <FontFeature>[])
        if (f.feature != 'tnum' && f.feature != 'pnum') f,
      const FontFeature.tabularFigures(),
    ];
    return copyWith(fontFeatures: features);
  }
}
