import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 毛玻璃表面的模糊半径（sigma）。比阅读器顶部进度条（12）更重：弹层 / 对话框
/// 下面是整页内容，需要更强的模糊才能让文字不和表面内容打架。
const double kFushiGlassBlurSigma = 20;

/// 毛玻璃填充色在 [base] 上的不透明度。暗色更透（暗底上的模糊本身就够压住
/// 背景），亮色更实（亮底上透得多会显脏、正文对比度掉得快）。
double fushiGlassFillOpacity(Brightness brightness) =>
    brightness == Brightness.dark ? 0.62 : 0.72;

/// 主题层「无模糊」玻璃表面的不透明度：菜单、下拉、提示条、tooltip 这些浮层
/// 由 Flutter 自己构建 Material、拿不到 BackdropFilter 挂点，只能半透明着色；
/// 没有模糊压背景，所以比 [fushiGlassFillOpacity] 实得多，保证文字可读。
double fushiGlassOverlayOpacity(Brightness brightness) =>
    brightness == Brightness.dark ? 0.86 : 0.9;

/// 卡片 / 分组面板这类常驻内容容器在玻璃下的不透明度：背后多是页面底色或
/// （Windows 11 / macOS）系统窗口材质，比浮层透、比弹层实。
double fushiGlassContainerOpacity(Brightness brightness) =>
    brightness == Brightness.dark ? 0.7 : 0.78;

/// 对话框背后整屏的模糊半径。对话框的 Material 由主题染成半透明，模糊放在
/// 路由层（[FushiGlassDialogBackdrop]）而不是对话框形状里：对话框尺寸与位置
/// 由 AlertDialog 自己决定，路由层拿不到它的形状。
const double kFushiGlassDialogBackdropSigma = 10;

/// 对话框路由内容的玻璃包装：玻璃开启时在对话框背后铺一层整屏模糊（随路由
/// 转场一起淡入淡出），关闭时原样返回 [child]。[showAppDialog] 统一套用。
class FushiGlassDialogBackdrop extends StatelessWidget {
  const FushiGlassDialogBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (glassMaterialOf(context) == FushiGlassMaterial.off) return child;
    // passthrough：对话框内容拿到的约束与不包时一字不差（路由给的是整屏紧约束）。
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: kFushiGlassDialogBackdropSigma,
                sigmaY: kFushiGlassDialogBackdropSigma,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 液态玻璃档的背景模糊。着色器本身还叠折射与高光，模糊比 frosted 轻一些
/// 才看得出折射，但仍要压住背后的文字。
const double kFushiLiquidGlassBlur = 12;

/// 悬浮按钮的玻璃包装：主题在玻璃下把 FAB 底色设为透明，这里补上
/// primaryContainer 色阶的玻璃（液态档折射、毛玻璃档模糊）。玻璃关闭或
/// [glassMaterialOf] 判 off（高对比度 / 降低透明度）时是一块同形状的实心底，
/// 与 FAB 原本的底色一致。所有 FloatingActionButton 都必须包这一层。
class FushiGlassFab extends StatelessWidget {
  const FushiGlassFab({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool themedTransparent =
        theme.floatingActionButtonTheme.backgroundColor == Colors.transparent;
    if (!themedTransparent) return child;
    // Apple 设计系统：iOS 26 的悬浮按钮是中性玻璃胶囊（标准 56 高 → 半径 28，
    // 圆钮 / 扩展胶囊同一个半径），着色交给强调色图标，不铺 primaryContainer。
    final bool apple = isGlassDesign(context);
    return FushiGlassSurface(
      baseColor: apple
          ? appleColorsOf(context).secondaryGroupedBackground
          : theme.colorScheme.primaryContainer,
      borderRadius: apple
          ? const BorderRadius.all(Radius.circular(28))
          : FushiBorderRadius.control,
      child: child,
    );
  }
}

/// 功能层表面的统一材质包装：[glassMaterialOf] 为 off 时就是一块 [baseColor]
/// 实心底（与改造前像素一致），frosted 时是 ClipRRect + BackdropFilter 模糊 +
/// 半透明 [baseColor] + 一圈细高光描边，liquid 时换成 `liquid_glass_widgets`
/// 的折射着色器（[glassMaterialOf] 已保证此时引擎支持着色器 ImageFilter）。
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
    this.grouped = false,
  });

  final Widget child;

  /// 裁剪 / 描边的圆角；须与外层 Material 的 shape 一致，否则角上漏模糊。
  final BorderRadius borderRadius;

  /// 表面底色；缺省取 [FushiSurfaceColors.search]（M3 对话框色阶）。
  final Color? baseColor;

  /// frosted 下是否画细描边（贴屏幕边的底栏 / 侧栏不需要整圈描边）。
  final bool showBorder;

  /// frosted 下是否走 [BackdropFilter.grouped]：同一页面里并排的导航栏 / 侧栏
  /// / 顶栏挂在同一个 [BackdropGroup] 下共用一次背景采样。叠在别的玻璃之上的
  /// 弹层 / 对话框必须为 false，否则采样不到下面那层玻璃。没有 [BackdropGroup]
  /// 祖先时等同普通 BackdropFilter。
  final bool grouped;

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
    final Color fill =
        base.withValues(alpha: fushiGlassFillOpacity(brightness));
    if (glassMaterialOf(context) == FushiGlassMaterial.liquid) {
      return _buildLiquid(fill);
    }
    final ImageFilter blur = ImageFilter.blur(
      sigmaX: kFushiGlassBlurSigma,
      sigmaY: kFushiGlassBlurSigma,
    );
    final Widget surface = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
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
    );
    return ClipRRect(
      borderRadius: borderRadius,
      child: grouped
          ? BackdropFilter.grouped(filter: blur, child: surface)
          : BackdropFilter(filter: blur, child: surface),
    );
  }

  /// 液态玻璃只支持四角同半径的形状；底部弹层这种只有上圆角的表面，着色器用
  /// 直角矩形、外面再按真实圆角裁一次。
  Widget _buildLiquid(Color fill) {
    final double radius = borderRadius.topLeft.x;
    final bool uniform =
        borderRadius == BorderRadius.all(Radius.circular(radius));
    final Widget glass = GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.premium,
      shape: uniform && radius > 0
          ? LiquidRoundedSuperellipse(borderRadius: radius)
          : const LiquidRoundedRectangle(borderRadius: 0),
      settings: LiquidGlassSettings(
        glassColor: fill,
        blur: kFushiLiquidGlassBlur,
      ),
      child: child,
    );
    if (uniform && radius > 0) return glass;
    return ClipRRect(borderRadius: borderRadius, child: glass);
  }
}
