import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_icon_map.dart';

/// Material 图标在玻璃（Apple 26）设计系统下的 SF 风格替身。
///
/// 只认 `MaterialIcons` 字体（且无 fontPackage）的 IconData：自定义图标字体、
/// 已经是 CupertinoIcons 的、或映射表里没有语义对应的，一律原样返回。
IconData? fushiAppleIcon(IconData? icon) {
  if (icon == null) return null;
  if (icon.fontFamily != 'MaterialIcons' || icon.fontPackage != null) {
    return icon;
  }
  return kFushiAppleIconMap[icon.codePoint] ?? icon;
}

/// [Icon] 的设计系统分派版：构造器与 [Icon] 逐参一致（可 `const`），调用点
/// 把 `Icon(` 换成 `FushiIcon(` 即可。
///
/// MD3 下原样渲染一个参数全透传的 [Icon]（像素不变）；玻璃设计系统下只把
/// 字形换成 [fushiAppleIcon] 查到的 CupertinoIcons，尺寸 / 颜色 / 语义标签
/// 等全部沿用调用方给的值——这样几千个 `Icons.xxx` 调用点不用逐个改源码。
class FushiIcon extends StatelessWidget {
  const FushiIcon(
    this.icon, {
    super.key,
    this.size,
    this.fill,
    this.weight,
    this.grade,
    this.opticalSize,
    this.color,
    this.shadows,
    this.semanticLabel,
    this.textDirection,
    this.applyTextScaling,
    this.blendMode,
    this.fontWeight,
  }) : assert(fill == null || (0.0 <= fill && fill <= 1.0)),
       assert(weight == null || (0.0 < weight)),
       assert(opticalSize == null || (0.0 < opticalSize));

  /// 见 [Icon.icon]。
  final IconData? icon;

  /// 见 [Icon.size]。
  final double? size;

  /// 见 [Icon.fill]。
  final double? fill;

  /// 见 [Icon.weight]。
  final double? weight;

  /// 见 [Icon.grade]。
  final double? grade;

  /// 见 [Icon.opticalSize]。
  final double? opticalSize;

  /// 见 [Icon.color]。
  final Color? color;

  /// 见 [Icon.shadows]。
  final List<Shadow>? shadows;

  /// 见 [Icon.semanticLabel]。
  final String? semanticLabel;

  /// 见 [Icon.textDirection]。
  final TextDirection? textDirection;

  /// 见 [Icon.applyTextScaling]。
  final bool? applyTextScaling;

  /// 见 [Icon.blendMode]。
  final BlendMode? blendMode;

  /// 见 [Icon.fontWeight]。
  final FontWeight? fontWeight;

  @override
  Widget build(BuildContext context) {
    final IconData? glyph = isGlassDesign(context)
        ? fushiAppleIcon(icon)
        : icon;
    return Icon(
      glyph,
      size: size,
      fill: fill,
      weight: weight,
      grade: grade,
      opticalSize: opticalSize,
      color: color,
      shadows: shadows,
      semanticLabel: semanticLabel,
      textDirection: textDirection,
      applyTextScaling: applyTextScaling,
      blendMode: blendMode,
      fontWeight: fontWeight,
    );
  }
}
