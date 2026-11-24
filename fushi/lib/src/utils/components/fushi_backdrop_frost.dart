import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show isEinkTheme;
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';
import 'package:fushi/src/utils/system_transparency.dart';

/// 毛玻璃底的模糊强度（逻辑像素 sigma）。
const double kFushiBackdropFrostBlurSigma = 14;

/// 开模糊时毛玻璃底的填充不透明度（页面底色）。
const double kFushiBackdropFrostFillOpacity = 0.55;

/// 系统「降低透明度」/「增强对比度」下不开模糊，退成的近实心底不透明度。
const double kFushiBackdropFrostSolidOpacity = 0.9;

/// 直接压在**用户自定义背景图**上的文字垫一层毛玻璃底（2026-11-24 用户：「自定义了
/// 背景，文字后面没有描边或毛玻璃，看不清」，拍板「统一处理、毛玻璃底」）。
///
/// 图片明暗、花纹不可控，压在上面的文字对比度忽高忽低；形状 / 纯色预设是低对比的
/// 大色块，不需要。所以只在 [FushiPageBackdrop.imageOf] 为真时画，其余情况原样返回
/// [child]，墨水屏也不画（墨水屏本来不画背景图）。
///
/// **不改版面**：底板按 [outset] 向 [child] 四周外扩、只画不占位（[StackFit.passthrough]
/// 把约束原样传给 [child]），切换背景预设时文字位置、列表高度一像素不动。
///
/// 公共组件（分区标题 [FushiSectionTitle]、空状态、书架书名、设置分组标题等）在
/// 内部接好；页面里手写的、直接压在页底上的文字也包这一层，不另写底色。
class FushiBackdropFrost extends StatelessWidget {
  const FushiBackdropFrost({
    required this.child,
    this.outset = const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    this.borderRadius,
    super.key,
  });

  final Widget child;

  /// 底板比 [child] 四周多出的那圈（文字到底板边的留白）。
  final EdgeInsets outset;

  /// 底板圆角；null 画胶囊（单行标题），多行文字块传圆角矩形。
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    if (!FushiPageBackdrop.imageOf(context) || isEinkTheme(context)) {
      return child;
    }
    return Stack(
      fit: StackFit.passthrough,
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned(
          left: -outset.left,
          top: -outset.top,
          right: -outset.right,
          bottom: -outset.bottom,
          child: IgnorePointer(
            child: FushiBackdropFrostPlate(borderRadius: borderRadius),
          ),
        ),
        child,
      ],
    );
  }
}

/// [FushiBackdropFrost] 画的那块底板本身：页面底色半透明填充 + 背后高斯模糊，
/// 裁成胶囊 / 圆角矩形。需要自己决定底板范围的地方（整块空状态卡）直接用它。
///
/// 页面底色取主题的 `colorScheme.surface`（背景层在画时脚手架底色已被换成透明），
/// MD3 / Apple 各自的主题给各自的底色。走 [BackdropFilter.grouped]：同页多个标题
/// 在外壳的 [BackdropGroup] 里共用一次背景采样，没有组时等同普通模糊。
class FushiBackdropFrostPlate extends StatelessWidget {
  const FushiBackdropFrostPlate({this.borderRadius, this.child, super.key});

  /// null 画胶囊。
  final BorderRadius? borderRadius;

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final ShapeBorder shape = borderRadius == null
        ? const StadiumBorder()
        : RoundedRectangleBorder(borderRadius: borderRadius!);
    final Color page = Theme.of(context).colorScheme.surface;
    return ValueListenableBuilder<bool>(
      valueListenable: SystemTransparency.reduceTransparency,
      builder: (BuildContext context, bool reduce, Widget? _) {
        final bool blur =
            !reduce && !(MediaQuery.maybeHighContrastOf(context) ?? false);
        final Widget fill = DecoratedBox(
          decoration: ShapeDecoration(
            color: page.withValues(
              alpha: blur
                  ? kFushiBackdropFrostFillOpacity
                  : kFushiBackdropFrostSolidOpacity,
            ),
            shape: shape,
          ),
          child: child,
        );
        if (!blur) return fill;
        return ClipPath(
          clipper: ShapeBorderClipper(shape: shape),
          child: BackdropFilter.grouped(
            filter: ImageFilter.blur(
              sigmaX: kFushiBackdropFrostBlurSigma,
              sigmaY: kFushiBackdropFrostBlurSigma,
            ),
            child: fill,
          ),
        );
      },
    );
  }
}
