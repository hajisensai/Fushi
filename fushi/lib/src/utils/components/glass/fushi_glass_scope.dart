import 'package:flutter/material.dart';
import 'package:fushi/src/models/theme_notifier.dart' show buildFushiThemeData;
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
  final FushiGlassMaterial effective = glassMaterialOf(context);
  // Skia 后端（Windows / Linux / 旧 Android）没有着色器 ImageFilter，
  // glassMaterialOf 会把 liquid 降成 frosted（表面颜色按磨砂档取）。但库的
  // standard 档是 LightweightLiquidGlass 片元着色器，Skia 上照样能跑——
  // 高光边、折射都在；只有 premium 需要 Impeller（AdaptiveGlass 自己回退）。
  // 用户选的是液态时，渲染档位按原始偏好给，别掉到 minimal 的纯模糊色块。
  final bool preferLiquid =
      Theme.of(context).extension<FushiGlassTheme>()?.material ==
      FushiGlassMaterial.liquid;
  if (effective == FushiGlassMaterial.frosted && preferLiquid) {
    return prominent ? GlassQuality.premium : GlassQuality.standard;
  }
  switch (effective) {
    case FushiGlassMaterial.liquid:
      return prominent ? GlassQuality.premium : GlassQuality.standard;
    case FushiGlassMaterial.frosted:
    case FushiGlassMaterial.off:
      return GlassQuality.minimal;
  }
}

/// 玻璃参数（填充色 / 模糊 / 主题变体）按哪一档取。与 [fushiGlassQuality]
/// 同口径：用户选液态、只因 Skia 后端被 [glassMaterialOf] 降成 frosted 时，
/// 渲染仍是 standard 着色器（高光边 + 折射），参数也按液态档给——磨砂档的
/// 72% 实底 + 20 模糊是给纯 BackdropFilter 的 minimal 档调的，叠在着色器
/// 玻璃上会又厚又闷，一眼就是一块不透明的色板。
FushiGlassMaterial _glassParamTier(BuildContext context) {
  final FushiGlassMaterial effective = glassMaterialOf(context);
  if (effective == FushiGlassMaterial.frosted &&
      Theme.of(context).extension<FushiGlassTheme>()?.material ==
          FushiGlassMaterial.liquid) {
    return FushiGlassMaterial.liquid;
  }
  return effective;
}

/// 玻璃填充色。液态档：深色 #262626 @65%（库 Messages / Music 演示对照
/// 真机）；浅色白 @55%（库 ios27Light 实测 53%——旧值白 @15% 压在 #F2F2F7
/// 分组底上控件几乎没有轮廓，Mac 实机反馈「日间可见度差」）——中性灰，
/// **不**拿 MD3 容器色阶去染，否则玻璃一眼就是「MD3 套了层半透明」。
/// 磨砂档对应 UIKit systemMaterial（更厚的实底 + 大模糊）；off 档实心。
/// [tint] 覆盖为有色玻璃（主按钮 / 选中态用强调色）。不透明的 [tint] 按档位
/// 重铺透明度（液态 0.82 / 磨砂 0.9）；调用方已给半透明色（例如 12% 前景色的
/// 轻着色）时保留调用方的透明度——一律拉到 0.82 会把轻着色压成近乎实心的色块。
Color fushiGlassFill(BuildContext context, {Color? tint}) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  final FushiGlassMaterial material = _glassParamTier(context);
  if (tint != null) {
    if (tint.a < 1.0 && material != FushiGlassMaterial.off) return tint;
    return switch (material) {
      FushiGlassMaterial.liquid => tint.withValues(alpha: 0.82),
      FushiGlassMaterial.frosted => tint.withValues(alpha: 0.9),
      FushiGlassMaterial.off => tint,
    };
  }
  return switch (material) {
    FushiGlassMaterial.liquid =>
      dark ? const Color(0xA6262626) : const Color(0x8CFFFFFF),
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
  final FushiGlassMaterial material = _glassParamTier(context);
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return LiquidGlassSettings(
    glassColor: fushiGlassFill(context, tint: tint),
    blur: switch (material) {
      FushiGlassMaterial.liquid => dark ? 1.8 : 8,
      FushiGlassMaterial.frosted => 20,
      FushiGlassMaterial.off => 0,
    },
    // 深色 bevel 收薄：轻量着色器的 rim 不透明度随厚度上涨，22 时深底上是
    // 一圈刺眼的灰白环。浅色库几乎不画 rim，轮廓靠 edgeAbsorption 暗边 + 投影。
    thickness: dark ? 14 : 18,
    lightIntensity: dark ? 0.18 : 0.45,
    ambientStrength: dark ? 0.0 : 0.12,
    fresnelStrength: dark ? 0.0 : 1.0,
    chromaticAberration: 0.01,
    saturation: 1.0,
    refractiveIndex: dark ? 1.12 : 1.2,
    edgeAbsorption: dark ? 0.0 : 0.03,
    shadowElevation: dark ? 0.0 : 1.6,
  );
}

/// 玻璃是否要走「压在原生平台视图上」的渲染路径。
///
/// 阅读器正文、漫画页图、视频画面在 iOS / macOS 上是原生 WebView / 平台视图，
/// 库的着色器路径采不到它们的像素（采样处会塌成黑底），必须改走 BackdropFilter
/// 回退（`platformViewBackdrop: true`）。其余平台（Windows / Android / Linux）
/// 的 WebView 以纹理合成进 Flutter 场景，着色器采得到，维持默认路径。
/// 判据读 [ThemeData.platform]（测试可经主题覆盖）。
bool fushiGlassOverPlatformView(BuildContext context) {
  final TargetPlatform platform = Theme.of(context).platform;
  return platform == TargetPlatform.iOS || platform == TargetPlatform.macOS;
}

/// 查词浮层背后的正文（阅读器 / 漫画 / 上一层查词卡，都是 WebView 平台视图）
/// 能否被 Flutter 采样做真模糊。
///
/// 只有 Windows / Linux 的 WebView 以纹理合成进 Flutter 场景，[BackdropFilter]
/// 采得到它的像素。iOS / macOS 是原生视图；Android 的 flutter_inappwebview
/// 走 Hybrid Composition（全仓未设 `useHybridComposition`，fork 默认 true →
/// `initExpensiveAndroidView`）：WebView 是真 Android View，画在它上面的
/// Flutter 层落在独立的 overlay surface 里，[BackdropFilter] / 玻璃着色器只能
/// 采到这块 overlay 里自己画过的东西，采不到下面的 WebView——半透明面板只会把
/// 正文原样（不模糊）透出来。这三端的查词面板一律不透明。
///
/// 与 [fushiGlassOverPlatformView] 分开：那个判据决定控件层玻璃走哪条渲染路径，
/// 改它会牵动 Android 上所有控件玻璃；这里只管查词面板「要不要半透明」。
/// 判据读 [ThemeData.platform]（测试可经主题覆盖）。
bool fushiPopupBackdropSampleable(BuildContext context) {
  final TargetPlatform platform = Theme.of(context).platform;
  return platform != TargetPlatform.iOS &&
      platform != TargetPlatform.macOS &&
      platform != TargetPlatform.android;
}

/// 浮在原生平台视图（阅读器 / 漫画 / 视频正文）上的玻璃 settings：在
/// [fushiGlassSettings] 之上补一份实色兜底填充——着色器真采不到背景的地方
/// 显示系统材质的实色（深 #1C1C1E / 浅 #F9F9F9），而不是一块黑。与
/// [fushiGlassOverPlatformView] 配套：
///
/// ```dart
/// GlassContainer(
///   settings: fushiGlassSettingsOverPlatformView(context),
///   platformViewBackdrop: fushiGlassOverPlatformView(context),
///   ...
/// )
/// ```
LiquidGlassSettings fushiGlassSettingsOverPlatformView(
  BuildContext context, {
  Color? tint,
}) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return fushiGlassSettings(context, tint: tint).copyWith(
    platformViewFallbackColor: dark
        ? const Color(0xFF1C1C1E)
        : const Color(0xFFF9F9F9),
  );
}

/// 恒深色的控件层作用域：漫画阅读器 chrome、视频控件、页图上的空状态这类
/// 永远压在黑底 / 画面上的子树，Apple 设计系统下即使 app 是浅色也要用深色档
/// （白字、深色玻璃、强调色按深色档重建，见 [appleDarkColorsOf]），否则浅色
/// 档的黑色强调色主按钮压在黑底上直接隐形。
///
/// 结构恒定：无论设计系统 / 亮暗，[child] 永远挂在同一个 [Theme] +
/// [FushiGlassScope] 下；MD3、墨水屏与本就是深色的 app 直接沿用当前主题。
/// 深色主题按当前主题的设计系统 / 材质 / 字阶经 [buildFushiThemeData] 重建
/// （与主 app 的深色主题同一工厂），按源主题缓存，不随每帧重建。
class FushiAppleDarkTier extends StatelessWidget {
  const FushiAppleDarkTier({super.key, required this.child});

  final Widget child;

  static final Expando<ThemeData> _cache = Expando<ThemeData>(
    'FushiAppleDarkTier',
  );

  /// [theme] 的 Apple 深色档主题；非 Apple 设计系统或本就是深色时原样返回。
  static ThemeData darkTierOf(ThemeData theme) {
    final bool apple =
        theme.extension<FushiGlassTheme>()?.glassDesign == true &&
        theme.extension<FushiEinkTheme>()?.einkMode != true;
    if (!apple || theme.colorScheme.brightness == Brightness.dark) {
      return theme;
    }
    final ThemeData? cached = _cache[theme];
    if (cached != null) return cached;
    final Color accent =
        theme.extension<FushiAppleColors>()?.accent ??
        theme.colorScheme.primary;
    final int argb = accent.toARGB32();
    final bool monochrome = argb == 0xFF000000 || argb == 0xFFFFFFFF;
    // 浅色主题的字阶把黑色字色烤进了每一档；ThemeData 工厂里显式传入的字色
    // 优先于按亮度合并的默认字色，所以先换成深色档的 label 白。
    const Color label = Color(0xFFFFFFFF);
    final ThemeData dark = buildFushiThemeData(
      scheme: theme.colorScheme.copyWith(
        brightness: Brightness.dark,
        primary: monochrome ? accent : appleDarkTierAccent(accent),
      ),
      textTheme: theme.textTheme.apply(bodyColor: label, displayColor: label),
      designSystem:
          theme.extension<FushiDesignSystemTheme>()?.designSystem ??
          FushiDesignSystem.auto,
      glass:
          theme.extension<FushiGlassTheme>()?.material ??
          FushiGlassMaterial.off,
      glassDesign: true,
      monochromeAccent: monochrome,
    ).copyWith(platform: theme.platform);
    _cache[theme] = dark;
    return dark;
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: darkTierOf(Theme.of(context)),
      child: FushiGlassScope(child: child),
    );
  }
}

/// [FushiGlassScope] 用的主题变体（导出供测试断言）。
GlassThemeVariant fushiGlassVariant(BuildContext context) {
  final ColorScheme cs = Theme.of(context).colorScheme;
  final FushiGlassMaterial material = _glassParamTier(context);
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
      thickness: dark ? 14.0 : 18.0,
      lightIntensity: dark ? 0.18 : 0.45,
      ambientStrength: dark ? 0.0 : 0.12,
      fresnelStrength: dark ? 0.0 : 1.0,
      chromaticAberration: 0.01,
      saturation: 1.0,
      refractiveIndex: dark ? 1.12 : 1.2,
      edgeAbsorption: dark ? 0.0 : 0.03,
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
