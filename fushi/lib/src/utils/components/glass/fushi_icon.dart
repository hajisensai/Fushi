import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_icon_map.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// Material 图标在玻璃（Apple 26）设计系统下的 SF 风格替身。
///
/// 认两类 IconData：M3E 语义图标（[FushiIcons]，按 [kFushiSymbolAppleMap] 换成同一
/// 语义的 SF 字形，实心字族或 `fill >= 0.5` 取 `_fill` 版），以及旧 `MaterialIcons`
/// 字体（且无 fontPackage）的 `Icons.*`。其它自定义图标字体、已经是 CupertinoIcons
/// 的、或映射表里没有语义对应的，一律原样返回。
IconData? fushiAppleIcon(IconData? icon, {double? fill}) {
  if (icon == null) return null;
  if (isFushiSymbol(icon)) {
    return fushiSymbolAppleIcon(icon, fill: fill) ?? icon;
  }
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
    final bool glass = isGlassDesign(context);
    final IconData? glyph = glass ? fushiAppleIcon(icon, fill: fill) : icon;
    // M3E 语义图标（Material Symbols 可变字体）：没显式给轴值时按实际字号配 opsz /
    // 字重、深色背景降 GRAD。Apple 下字形已换成 CupertinoIcons，轴值无意义，不加。
    if (!glass && isFushiSymbol(glyph)) {
      final double resolvedSize = size ?? IconTheme.of(context).size ?? 24;
      return Icon(
        glyph,
        size: size,
        fill: fill,
        weight: weight ?? fushiSymbolWeight(resolvedSize),
        grade: grade ?? fushiSymbolGrade(_backdropBrightness(context, color)),
        opticalSize: opticalSize ?? fushiSymbolOpticalSize(resolvedSize),
        color: color,
        shadows: shadows,
        semanticLabel: semanticLabel,
        textDirection: textDirection,
        applyTextScaling: applyTextScaling,
        blendMode: blendMode,
        fontWeight: fontWeight,
      );
    }
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

/// 图标所在背景的明暗：优先图标颜色本身（浅色图标 ≈ 深色背景），否则看平台明暗。
Brightness _backdropBrightness(BuildContext context, Color? explicit) {
  final Color? color = explicit ?? IconTheme.of(context).color;
  if (color != null) {
    return color.computeLuminance() > 0.5 ? Brightness.dark : Brightness.light;
  }
  return MediaQuery.maybePlatformBrightnessOf(context) ?? Brightness.light;
}
