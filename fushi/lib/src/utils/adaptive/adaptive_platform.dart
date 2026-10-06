import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:material_ui/material_ui.dart';

enum FushiDesignSystem { auto, material, cupertino, macos }

/// macOS 标准标题栏高度（逻辑像素）。`main.dart` 无条件启用透明标题栏 +
/// full-size content view（macos_ui ToolBar 的硬性前提），Flutter 内容会整块
/// 延伸到红黄绿交通灯按钮下方；而 macOS full-size content view 下 embedder 不把
/// 交通灯上报为 `MediaQuery.padding.top`（上报 0），所以普通 `SafeArea` 挡不住。
/// Material 桌面壳需要用它给 `SafeArea.minimum` 预留顶部内边距，让交通灯落在这条
/// 保留带里、不再压住导航 rail / 返回按钮（BUG-869）。交通灯直径 12pt、约在
/// y=[6,18]，28pt 足以完全让位。macos_ui 原生壳由 MacosWindow 自处理让位，不用它。
const double kMacTitleBarHeight = 28.0;

@immutable
class FushiDesignSystemTheme extends ThemeExtension<FushiDesignSystemTheme> {
  const FushiDesignSystemTheme(this.designSystem);

  final FushiDesignSystem designSystem;

  @override
  FushiDesignSystemTheme copyWith({FushiDesignSystem? designSystem}) {
    return FushiDesignSystemTheme(designSystem ?? this.designSystem);
  }

  @override
  FushiDesignSystemTheme lerp(
    covariant ThemeExtension<FushiDesignSystemTheme>? other,
    double t,
  ) {
    return this;
  }
}

/// 墨水屏模式标志的 ThemeExtension 载体。挂在 ThemeNotifier._buildThemeData 的
/// extensions 里，使任意 widget 可经 `Theme.of(context)` 感知 eink（用于把入场
/// 淡入/滑出等 Flutter 侧动画时长归零），零新增数据流、随主题重建自动更新。
@immutable
class FushiEinkTheme extends ThemeExtension<FushiEinkTheme> {
  const FushiEinkTheme(this.einkMode);

  final bool einkMode;

  @override
  FushiEinkTheme copyWith({bool? einkMode}) {
    return FushiEinkTheme(einkMode ?? this.einkMode);
  }

  @override
  FushiEinkTheme lerp(
    covariant ThemeExtension<FushiEinkTheme>? other,
    double t,
  ) {
    return this;
  }
}

/// True 当墨水屏模式开启（读不到扩展时为 false，测试裸 ThemeData 零破坏）。
bool isEinkTheme(BuildContext context) {
  return Theme.of(context).extension<FushiEinkTheme>()?.einkMode ?? false;
}

/// 功能层表面（导航 / 底部弹层 / 对话框）的材质。与颜色主题正交：颜色仍由
/// ColorScheme 决定，这里只决定表面是实心还是半透明 + 背景模糊。
enum FushiGlassMaterial {
  /// 实心表面（默认）。
  off,

  /// 毛玻璃：半透明填充 + BackdropFilter 模糊。
  frosted,

  /// 液态玻璃：折射 / 色散 / 高光着色器（`liquid_glass_widgets`）。只在引擎
  /// 支持着色器 ImageFilter（Impeller）时生效，否则 [glassMaterialOf] 降级为
  /// [frosted]。
  liquid;

  /// 偏好值（`glass_material`）→ 枚举；未知值回落 [off]。
  static FushiGlassMaterial fromPrefValue(String? value) {
    for (final FushiGlassMaterial m in FushiGlassMaterial.values) {
      if (m.name == value) return m;
    }
    return FushiGlassMaterial.off;
  }
}

/// 玻璃材质的 ThemeExtension 载体，与 [FushiEinkTheme] 同一写法：挂在
/// `buildFushiThemeData` 的 extensions 里，随主题重建自动更新。
@immutable
class FushiGlassTheme extends ThemeExtension<FushiGlassTheme> {
  const FushiGlassTheme(this.material, {this.glassDesign = false});

  /// 表面材质（off / frosted / liquid），已扣除系统降低透明度。
  final FushiGlassMaterial material;

  /// 是否「玻璃」设计系统：为 true 时共享组件与控件包装渲染
  /// `liquid_glass_widgets` 组件族（与 MD3 并列的另一套组件），即使
  /// [material] 因降低透明度 / 高对比度回退为 off，组件族也不变——只是
  /// 玻璃变成实心。见 [isGlassDesign]。
  final bool glassDesign;

  @override
  FushiGlassTheme copyWith({FushiGlassMaterial? material, bool? glassDesign}) {
    return FushiGlassTheme(
      material ?? this.material,
      glassDesign: glassDesign ?? this.glassDesign,
    );
  }

  @override
  FushiGlassTheme lerp(
    covariant ThemeExtension<FushiGlassTheme>? other,
    double t,
  ) {
    return this;
  }
}

/// 引擎是否支持着色器 ImageFilter（液态玻璃的前提）。测试可覆盖。
@visibleForTesting
bool Function() debugShaderFilterSupported = () =>
    ImageFilter.isShaderFilterSupported;

/// 当前上下文实际生效的玻璃材质。墨水屏（半透明 = 灰阶抖动 + 残影）与系统
/// 「增强对比度」（[MediaQueryData.highContrast]）下一律回退 [FushiGlassMaterial.off]；
/// 读不到扩展（测试裸 ThemeData、查词弹窗主题）同样是 off。[FushiGlassMaterial.liquid]
/// 在不支持着色器 ImageFilter 的引擎（Skia 后端）上降级为 frosted。
FushiGlassMaterial glassMaterialOf(BuildContext context) {
  final FushiGlassMaterial material =
      Theme.of(context).extension<FushiGlassTheme>()?.material ??
          FushiGlassMaterial.off;
  if (material == FushiGlassMaterial.off) return material;
  if (isEinkTheme(context)) return FushiGlassMaterial.off;
  if (MediaQuery.maybeHighContrastOf(context) ?? false) {
    return FushiGlassMaterial.off;
  }
  if (material == FushiGlassMaterial.liquid && !debugShaderFilterSupported()) {
    return FushiGlassMaterial.frosted;
  }
  return material;
}

/// 当前上下文是否走「玻璃」设计系统的组件族（`liquid_glass_widgets`）。
/// 与 [glassMaterialOf] 正交：后者决定表面透不透明，这里决定渲染 MD3 还是
/// 玻璃组件。墨水屏下恒 false（墨水屏的可读性调校全建在 MD3 组件上）；
/// 读不到扩展（测试裸 ThemeData、查词弹窗主题）同样 false。
bool isGlassDesign(BuildContext context) {
  if (isEinkTheme(context)) return false;
  return Theme.of(context).extension<FushiGlassTheme>()?.glassDesign ?? false;
}

/// eink 下把动画时长归零（墨水屏连续重绘=残影），否则原样返回。
/// 共享组件与页面级 Animated* 统一走这里，别再手写三元。
Duration einkSafeDuration(BuildContext context, Duration duration) {
  return isEinkTheme(context) ? Duration.zero : duration;
}

/// eink 下把不定态进度（`value == null`）钉成 0：不定态是一条永不停歇的往复
/// 动画，墨水屏上等于整条进度带持续局部刷新（残影 + 闪烁）；旁边的文案已经在
/// 说「正在下载 / 同步中」，静止的空轨道足够表达。非 eink 原样返回。
double? einkSafeProgressValue(BuildContext context, double? value) {
  return isEinkTheme(context) ? (value ?? 0) : value;
}

bool isCupertinoPlatform(BuildContext context) {
  final FushiDesignSystem designSystem =
      Theme.of(context).extension<FushiDesignSystemTheme>()?.designSystem ??
          FushiDesignSystem.auto;
  switch (designSystem) {
    case FushiDesignSystem.material:
      return false;
    case FushiDesignSystem.cupertino:
      return true;
    case FushiDesignSystem.macos:
      // Explicit macOS-native design system is NOT Cupertino. The macos_ui shell
      // and converted pages route via [isMacosPlatform]; this keeps the two
      // skins from both claiming the same surface.
      return false;
    case FushiDesignSystem.auto:
      return false;
  }
}

/// True when the macOS-native (macos_ui) design system should drive this
/// subtree. Converted shells/pages branch on this BEFORE
/// [isCupertinoPlatform].
bool isMacosPlatform(BuildContext context) {
  final FushiDesignSystem designSystem =
      Theme.of(context).extension<FushiDesignSystemTheme>()?.designSystem ??
          FushiDesignSystem.auto;
  switch (designSystem) {
    case FushiDesignSystem.material:
    case FushiDesignSystem.cupertino:
      return false;
    case FushiDesignSystem.macos:
      // Explicitly selecting the macOS-native design system only routes into the
      // macos_ui / MacosWindow shell when actually running on macOS; on other
      // hosts WindowManipulator is unavailable, so fall back to the platform
      // default rather than crash. (Quality point ②)
      return Platform.isMacOS;
    case FushiDesignSystem.auto:
      return false;
  }
}
