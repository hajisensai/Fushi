import 'package:flutter/widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';

/// 同一行里并排的「行内控件」（搜索框、下拉 / 弹出按钮、筛选胶囊、行内输入）的
/// 统一高度——用户 2026-10-04：「搜索框和语言框不一样高」「搜索框文字没有垂直
/// 居中」。凡是会和别的控件排在同一行的输入类控件，都按这个高度定高，行内
/// 才对得齐、中线才一致。
///
/// - MD3：40（M3 紧凑文本框 / 搜索框；chip 默认 32 在这类行里会比搜索框矮一截，
///   所以行内统一抬到 40）。
/// - Apple：36（iOS 26 搜索胶囊 / macOS 26 大号控件；玻璃搜索胶囊的最小高度
///   就是 36，再矮会溢出）。
/// - 墨水屏随 MD3。
const double kFushiInlineControlHeightMd3 = 40;

/// Apple 设计系统下的行内控件高度，见 [kFushiInlineControlHeightMd3]。
const double kFushiInlineControlHeightApple = 36;

/// 当前设计系统下的行内控件高度，见 [kFushiInlineControlHeightMd3]。
double fushiInlineControlHeight(BuildContext context) => isGlassDesign(context)
    ? kFushiInlineControlHeightApple
    : kFushiInlineControlHeightMd3;
