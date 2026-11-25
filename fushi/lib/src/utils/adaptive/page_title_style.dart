/// 页面大标题样式（拍板台 DN2p82rNPg，方案 B）：设置 → 外观 →「页面标题」的
/// 字号（连续比例）/ 粗细 / 颜色三项。
///
/// 只是一份「用户偏好」值，随 [FushiShellTheme] 挂在主题扩展上下发（偏好键
/// `page_title_font_scale` / `page_title_weight` / `page_title_color`，随 Profile
/// 走）。字号是**比例**而不是写死的档位：两套设计系统、手机 / 宽窗的出厂字号各
/// 不相同（MD3 手机 46 → 滚动收到 28，宽窗 84；Apple iOS 大标题 34），同一个比例
/// 对所有档位等比生效，展开态与收起态一起缩放，收缩动效的比例不变。
library;

import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

/// 页面大标题的粗细。没选过（null）时各处沿用自己的出厂字重（MD3 模块页
/// w900、设置分类页 w700，Apple 大标题 w700）。
enum PageTitleWeight {
  regular('regular', FontWeight.w400),
  bold('bold', FontWeight.w700),
  heavy('heavy', FontWeight.w900);

  const PageTitleWeight(this.prefValue, this.fontWeight);

  final String prefValue;
  final FontWeight fontWeight;

  /// 没选过时设置页显示的选中项：MD3 模块页是 w900（特粗），Apple 大标题 w700（粗）。
  static PageTitleWeight defaultFor({required bool apple}) =>
      apple ? bold : heavy;

  /// 偏好值 → 档位；空串 / 未知值为 null（没选过，跟出厂走）。
  static PageTitleWeight? fromPref(String? value) {
    for (final PageTitleWeight weight in values) {
      if (weight.prefValue == value) return weight;
    }
    return null;
  }
}

/// 页面大标题的颜色：强调色（MD3 外壳强调色 / Apple 主题色）或正文色（页面底色
/// 上的文字色，两套设计系统的出厂值）。
enum PageTitleColor {
  accent('accent'),
  body('body');

  const PageTitleColor(this.prefValue);

  final String prefValue;

  static const PageTitleColor defaultColor = body;

  static PageTitleColor fromPref(String? value) {
    for (final PageTitleColor color in values) {
      if (color.prefValue == value) return color;
    }
    return defaultColor;
  }
}

/// 页面大标题样式（三项偏好的合体），挂在 [FushiShellTheme.pageTitle]。
@immutable
class FushiPageTitleStyle {
  const FushiPageTitleStyle({
    this.fontScale = defaultFontScale,
    this.weight,
    this.color = PageTitleColor.defaultColor,
  });

  /// 字号比例的取值范围与步进（滑条 60% – 120%，每档 5%）。上限 120%：Apple
  /// 大标题行高 52 的版面在 1.2 倍下仍放得下 34pt 大标题，再大要改版面高度。
  static const double minFontScale = 0.6;
  static const double maxFontScale = 1.2;
  static const double defaultFontScale = 1.0;
  static const int fontScaleDivisions = 12;

  /// 偏好原值 → 生效比例（非有限值回默认，越界夹到范围内）。
  static double normalizeFontScale(double value) {
    if (value.isNaN || !value.isFinite) return defaultFontScale;
    return value.clamp(minFontScale, maxFontScale).toDouble();
  }

  /// 字号比例：1 = 出厂字号。展开态 / 收起态 / 两行折行范围一起乘。
  final double fontScale;

  /// 用户选的粗细；null = 没选过，各处用自己的出厂字重。
  final PageTitleWeight? weight;

  final PageTitleColor color;

  /// 生效字重：选过用所选，没选过用 [fallback]（调用处的出厂字重）。
  FontWeight weightOr(FontWeight fallback) => weight?.fontWeight ?? fallback;

  /// 按比例缩放一个出厂字号。
  double scaleFont(double size) => size * fontScale;

  /// 主题插值（[ThemeData.lerp] 换主题时逐帧调用）：字号比例连续插值，页头
  /// 字号随之平滑过渡；粗细 / 颜色是档位，过半切换。
  FushiPageTitleStyle lerp(FushiPageTitleStyle other, double t) =>
      FushiPageTitleStyle(
        fontScale: lerpDouble(fontScale, other.fontScale, t) ?? other.fontScale,
        weight: t < 0.5 ? weight : other.weight,
        color: t < 0.5 ? color : other.color,
      );

  @override
  bool operator ==(Object other) =>
      other is FushiPageTitleStyle &&
      other.fontScale == fontScale &&
      other.weight == weight &&
      other.color == color;

  @override
  int get hashCode => Object.hash(fontScale, weight, color);
}
