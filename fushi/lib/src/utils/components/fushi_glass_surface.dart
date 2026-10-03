import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';

/// 毛玻璃表面的模糊半径（sigma）。比阅读器顶部进度条（12）更重：弹层 / 对话框
/// 下面是整页内容，需要更强的模糊才能让文字不和表面内容打架。
const double kFushiGlassBlurSigma = 20;

/// 毛玻璃填充色在 [base] 上的不透明度。暗色更透（暗底上的模糊本身就够压住
/// 背景），亮色更实（亮底上透得多会显脏、正文对比度掉得快）。
double fushiGlassFillOpacity(Brightness brightness) =>
    brightness == Brightness.dark ? 0.62 : 0.72;

/// 功能层表面的统一材质包装：[glassMaterialOf] 为 off 时就是一块 [baseColor]
/// 实心底（与改造前像素一致），frosted 时是 ClipRRect + BackdropFilter 模糊 +
/// 半透明 [baseColor] + 一圈细高光描边。
///
/// 只用于导航 / 底部弹层 / 对话框这类「浮在内容之上」的功能层；阅读器正文、
/// 视频画面与查词弹窗不用（查词弹窗的主题根本不挂 [FushiGlassTheme]）。
///
/// 不挂全局 BackdropGroup：叠起来的玻璃（对话框压在弹层上）各自采样，才能
/// 模糊到下面那层玻璃本身，而不是共享同一份背景快照。
class FushiGlassSurface extends StatelessWidget {
  const FushiGlassSurface({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.baseColor,
    this.showBorder = true,
  });

  final Widget child;

  /// 裁剪 / 描边的圆角；须与外层 Material 的 shape 一致，否则角上漏模糊。
  final BorderRadius borderRadius;

  /// 表面底色；缺省取 [FushiSurfaceColors.search]（M3 对话框色阶）。
  final Color? baseColor;

  /// frosted 下是否画细描边（贴屏幕边的底栏 / 侧栏不需要整圈描边）。
  final bool showBorder;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color base =
        baseColor ?? FushiDesignTokens.of(context).surfaces.search;
    if (glassMaterialOf(context) == FushiGlassMaterial.off) {
      return DecoratedBox(
        decoration: BoxDecoration(color: base, borderRadius: borderRadius),
        child: child,
      );
    }
    final Brightness brightness = theme.brightness;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: kFushiGlassBlurSigma,
          sigmaY: kFushiGlassBlurSigma,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: base.withValues(alpha: fushiGlassFillOpacity(brightness)),
            borderRadius: borderRadius,
            border: showBorder
                ? Border.all(
                    color: (brightness == Brightness.dark
                            ? Colors.white
                            : Colors.black)
                        .withValues(alpha: 0.08),
                  )
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}
