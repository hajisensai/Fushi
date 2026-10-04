import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 「玻璃」设计系统的根作用域：把 Fushi 的 [ColorScheme] 与材质档位映射成
/// `liquid_glass_widgets` 的 [GlassTheme]，让子树里所有玻璃组件（按钮、开关、
/// 列表、对话框……）默认就用 app 的配色与渲染档位，调用点不必逐个传 settings。
///
/// 材质档位 → 渲染档位：
/// - liquid：[GlassQuality.standard]（轻量着色器，可滚动，Skia / Impeller 都能跑）；
/// - frosted：[GlassQuality.minimal]（零自定义着色器，BackdropFilter 模糊）；
/// - off（系统降低透明度 / 增强对比度）：minimal + 不透明玻璃色 + 零模糊——
///   组件族不变，只是玻璃变实心。
///
/// 结构恒定：无论设计系统，[child] 永远挂在同一个 [GlassTheme] 下（MD3 时给
/// 库默认数据，反正 MD3 子树里没有玻璃组件）。按设计系统增删这一层会让整棵
/// Navigator（满是 GlobalKey）在 main 的 LayoutBuilder 重建中被重挂，触发
/// framework `_elements.contains(element)` 断言。
class FushiGlassScope extends StatelessWidget {
  const FushiGlassScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!isGlassDesign(context)) {
      return GlassTheme(data: GlassThemeData.fallback(), child: child);
    }
    final GlassThemeVariant variant = fushiGlassVariant(context);
    return GlassTheme(
      data: GlassThemeData(
        light: variant,
        dark: variant,
        brightness: Theme.of(context).colorScheme.brightness,
      ),
      child: child,
    );
  }
}

/// 当前上下文玻璃组件的渲染档位（见 [FushiGlassScope]）。[prominent] 为
/// true 的静态主表面（导航栏、顶栏、对话框）在液态档用 [GlassQuality.premium]。
GlassQuality fushiGlassQuality(
  BuildContext context, {
  bool prominent = false,
}) {
  switch (glassMaterialOf(context)) {
    case FushiGlassMaterial.liquid:
      return prominent ? GlassQuality.premium : GlassQuality.standard;
    case FushiGlassMaterial.frosted:
    case FushiGlassMaterial.off:
      return GlassQuality.minimal;
  }
}

/// 玻璃填充色：取 [ColorScheme] 的容器色阶按材质档位给不透明度。
/// [tint] 覆盖默认色阶（例如主按钮用 primary）。
Color fushiGlassFill(BuildContext context, {Color? tint}) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final Color base = tint ?? cs.surfaceContainerHigh;
  final bool dark = cs.brightness == Brightness.dark;
  switch (glassMaterialOf(context)) {
    case FushiGlassMaterial.liquid:
      return base.withValues(alpha: tint != null ? 0.55 : (dark ? 0.16 : 0.22));
    case FushiGlassMaterial.frosted:
      return base.withValues(alpha: tint != null ? 0.7 : (dark ? 0.55 : 0.62));
    case FushiGlassMaterial.off:
      return base.withValues(alpha: 1);
  }
}

/// 单个玻璃组件的完整 settings（需要覆盖主题默认，例如有色主按钮）。
LiquidGlassSettings fushiGlassSettings(BuildContext context, {Color? tint}) {
  final FushiGlassMaterial material = glassMaterialOf(context);
  final bool dark =
      Theme.of(context).colorScheme.brightness == Brightness.dark;
  return LiquidGlassSettings(
    glassColor: fushiGlassFill(context, tint: tint),
    blur: switch (material) {
      FushiGlassMaterial.liquid => dark ? 4 : 5,
      FushiGlassMaterial.frosted => 12,
      FushiGlassMaterial.off => 0,
    },
    thickness: dark ? 10 : 12,
    lightIntensity: dark ? 0.7 : 0.85,
    saturation: 1.2,
    refractiveIndex: 1.2,
  );
}

/// [FushiGlassScope] 用的主题变体（导出供测试断言）。
GlassThemeVariant fushiGlassVariant(BuildContext context) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final FushiGlassMaterial material = glassMaterialOf(context);
  final bool dark = cs.brightness == Brightness.dark;
  final GlassThemeVariant base = switch (material) {
    FushiGlassMaterial.liquid =>
      dark ? GlassThemeVariant.dark : GlassThemeVariant.light,
    FushiGlassMaterial.frosted ||
    FushiGlassMaterial.off =>
      GlassThemeVariant.minimal,
  };
  return base.copyWith(
    settings: (base.settings ?? const GlassThemeSettings()).copyWith(
      glassColor: fushiGlassFill(context),
      blur: switch (material) {
        FushiGlassMaterial.liquid => dark ? 4.0 : 5.0,
        FushiGlassMaterial.frosted => 12.0,
        FushiGlassMaterial.off => 0.0,
      },
    ),
    quality: fushiGlassQuality(context),
    glowColors: GlassGlowColors(
      secondary: cs.secondary,
      success: cs.tertiary,
      warning: cs.tertiary,
      danger: cs.error,
      info: cs.primary,
    ),
  );
}
