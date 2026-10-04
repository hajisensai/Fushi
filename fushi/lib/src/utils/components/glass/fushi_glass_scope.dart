import 'package:flutter/material.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
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
GlassQuality fushiGlassQuality(BuildContext context, {bool prominent = false}) {
  switch (glassMaterialOf(context)) {
    case FushiGlassMaterial.liquid:
      return prominent ? GlassQuality.premium : GlassQuality.standard;
    case FushiGlassMaterial.frosted:
    case FushiGlassMaterial.off:
      return GlassQuality.minimal;
  }
}

/// 玻璃填充色。液态档用 iOS 26 系统玻璃的实测值（库自带 Messages /
/// Music 演示对照真机调出：深色 #262626 @65%、浅色白 @15%）——中性灰，
/// **不**拿 MD3 容器色阶去染，否则玻璃一眼就是「MD3 套了层半透明」。
/// 磨砂档对应 UIKit systemMaterial（更厚的实底 + 大模糊）；off 档实心。
/// [tint] 覆盖为有色玻璃（主按钮 / 选中态用强调色）。
Color fushiGlassFill(BuildContext context, {Color? tint}) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  final FushiGlassMaterial material = glassMaterialOf(context);
  if (tint != null) {
    return switch (material) {
      FushiGlassMaterial.liquid => tint.withValues(alpha: 0.82),
      FushiGlassMaterial.frosted => tint.withValues(alpha: 0.9),
      FushiGlassMaterial.off => tint,
    };
  }
  return switch (material) {
    FushiGlassMaterial.liquid =>
      dark ? const Color(0xA6262626) : const Color(0x26FFFFFF),
    FushiGlassMaterial.frosted =>
      dark ? const Color(0xB81C1C1E) : const Color(0xB8F9F9F9),
    FushiGlassMaterial.off =>
      dark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9),
  };
}

/// 单个玻璃组件的完整 settings（需要覆盖主题默认，例如有色主按钮）。
/// 光照参数同 iOS 26 实测：深色下关掉 fresnel / 环境光、只留柔和高光
/// （UIVisualEffectView 的平面材质），浅色下保留斜面高光与 fresnel。
LiquidGlassSettings fushiGlassSettings(BuildContext context, {Color? tint}) {
  final FushiGlassMaterial material = glassMaterialOf(context);
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return LiquidGlassSettings(
    glassColor: fushiGlassFill(context, tint: tint),
    blur: switch (material) {
      FushiGlassMaterial.liquid => dark ? 1.8 : 8,
      FushiGlassMaterial.frosted => 20,
      FushiGlassMaterial.off => 0,
    },
    thickness: dark ? 22 : 18,
    lightIntensity: dark ? 0.18 : 0.45,
    ambientStrength: dark ? 0.0 : 0.12,
    fresnelStrength: dark ? 0.0 : 1.0,
    chromaticAberration: 0.01,
    saturation: 1.0,
    refractiveIndex: 1.2,
    shadowElevation: dark ? 0.0 : 1.0,
  );
}

/// [FushiGlassScope] 用的主题变体（导出供测试断言）。
GlassThemeVariant fushiGlassVariant(BuildContext context) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final FushiGlassMaterial material = glassMaterialOf(context);
  final bool dark = cs.brightness == Brightness.dark;
  final FushiAppleColors apple = appleColorsOf(context);
  final GlassThemeVariant base = switch (material) {
    FushiGlassMaterial.liquid =>
      dark ? GlassThemeVariant.dark : GlassThemeVariant.light,
    FushiGlassMaterial.frosted ||
    FushiGlassMaterial.off => GlassThemeVariant.minimal,
  };
  return base.copyWith(
    settings: (base.settings ?? const GlassThemeSettings()).copyWith(
      glassColor: fushiGlassFill(context),
      blur: switch (material) {
        FushiGlassMaterial.liquid => dark ? 1.8 : 8.0,
        FushiGlassMaterial.frosted => 20.0,
        FushiGlassMaterial.off => 0.0,
      },
      thickness: dark ? 22.0 : 18.0,
      lightIntensity: dark ? 0.18 : 0.45,
      ambientStrength: dark ? 0.0 : 0.12,
      fresnelStrength: dark ? 0.0 : 1.0,
      chromaticAberration: 0.01,
      saturation: 1.0,
      refractiveIndex: 1.2,
    ),
    quality: fushiGlassQuality(context),
    glowColors: GlassGlowColors(
      secondary: cs.primary,
      success: apple.success,
      warning: apple.warning,
      danger: apple.destructive,
      info: cs.primary,
    ),
  );
}
