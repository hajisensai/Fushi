import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;

/// 同一行里并排的「行内控件」（搜索框、下拉 / 弹出按钮、筛选胶囊、行内输入）的
/// 统一高度——用户 2026-10-04：「搜索框和语言框不一样高」「搜索框文字没有垂直
/// 居中」。凡是会和别的控件排在同一行的输入类控件，都按这个高度定高，行内
/// 才对得齐、中线才一致。
///
/// - MD3：40（M3 紧凑文本框 / 搜索框；chip 默认 32 在这类行里会比搜索框矮一截，
///   所以行内统一抬到 40）。
/// - Apple iOS 档（触屏 / 桌面窄窗）：36（iOS 27 搜索胶囊 / 筛选 pop-up 胶囊）。
/// - Apple macOS 档（桌面宽窗，[FushiAppleMetrics.desktop]）：28（macOS 27
///   搜索框 / large 尺寸 pop-up button），乘 [FushiAppleMetrics.scale]。
/// - 墨水屏随 MD3。
const double kFushiInlineControlHeightMd3 = 40;

/// Apple 设计系统 iOS 档的行内控件高度，见 [kFushiInlineControlHeightMd3]。
const double kFushiInlineControlHeightApple = 36;

/// Apple 设计系统 macOS 档（桌面宽窗）的行内控件高度。
const double kFushiInlineControlHeightAppleDesktop = 28;

/// 当前设计系统下的行内控件高度，见 [kFushiInlineControlHeightMd3]。
double fushiInlineControlHeight(BuildContext context) {
  if (!isGlassDesign(context)) return kFushiInlineControlHeightMd3;
  final FushiAppleMetrics apple = FushiAppleMetrics.of(context);
  return apple.desktop
      ? kFushiInlineControlHeightAppleDesktop * apple.scale
      : kFushiInlineControlHeightApple;
}
