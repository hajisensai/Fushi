/// Apple（Cupertino，iOS 27 / macOS 27）内容层的字样工具：去掉 MD3 字距、字号 /
/// 字重 / 颜色由调用方给，颜色默认 [appleColorsOf] 的 label。
///
/// 只被 Apple 布局（`isGlassDesign` 为真）的段头 / 货架 / 卡片使用；M3E 用
/// `context.fushiType` 的字阶，不经过这里。纯排版工具，不渲染控件，没有 M3E 分支。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';

/// 一段文字的 Apple 字样：去掉 MD3 字距，[size] / [weight] / [color] 由调用方给
/// （[size] 已乘 macOS 档缩放）。
TextStyle appleTextStyle(
  BuildContext context, {
  required double size,
  FontWeight weight = FontWeight.w400,
  Color? color,
  double height = 1.25,
}) => (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
  fontSize: size,
  fontWeight: weight,
  letterSpacing: 0,
  height: height,
  color: color ?? appleColorsOf(context).label,
);

/// 一行 [size] 号字（已乘 macOS 档缩放）在当前 textScaler 下占的高（行高倍数
/// [height] 与 [appleTextStyle] 默认值一致）。定高的行 / 货架按它推导，不写死像素。
double appleLineExtent(
  BuildContext context,
  double size, {
  double height = 1.25,
}) => (MediaQuery.textScalerOf(context).scale(size) * height).ceilToDouble();
