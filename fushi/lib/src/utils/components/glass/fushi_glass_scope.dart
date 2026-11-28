import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/theme_notifier.dart' show buildFushiThemeData;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart' show FushiShellTheme;
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// 「玻璃」设计系统的根作用域：把 Fushi 的 [ColorScheme] 与玻璃画质档位映射成
/// `liquid_glass_widgets` 的 [GlassTheme]（[GlassStyle.ios27]），让子树里所有
/// 玻璃组件（按钮、开关、列表、对话框……）默认就用 app 的配色与渲染档位，
/// 调用点不必逐个传 settings。
///
/// 画质档位（[glassMaterialOf]）→ 主题：
/// - premium：库 iOS 27 变体，quality 留空——库按组件类别取默认（栏 / 浮层 /
///   开关滑块分段等英雄控件 premium，其余 standard）；
/// - standard：库 iOS 27 变体，quality 钉 [GlassQuality.standard]；
/// - minimal：库 `minimalLight` / `minimalDark`（iOS 27 中性色调，零着色器）；
/// - off（实色；系统降低透明度 / 增强对比度 / 墨水屏）：minimal + 不透明玻璃色
///   + 零模糊——组件族不变，只是玻璃变实心。
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
        style: GlassStyle.ios27,
        brightness: Theme.of(context).colorScheme.brightness,
      ),
      child: child,
    );
  }
}

/// 当前上下文玻璃组件的渲染档位（见 [FushiGlassScope]）。[prominent] 为
/// true 的静态主表面（导航栏、顶栏、对话框）只在「高级」档用
/// [GlassQuality.premium]。
///
/// **premium 只能交给 `useOwnLayer: true` 的 [GlassContainer]**（或已在某个
/// `LiquidGlassLayer` 里的分组玻璃）：引擎支持着色器 ImageFilter（Impeller，
/// 任何平台）时，premium 的分组路径要从祖先层取几何渲染链接，找不到就在构建期
/// 抛错——调试版红块，发布版是一块灰色矩形（BUG-2957：Android 选 Apple + 液态
/// 底栏「直接炸了」）。守卫：`test/widgets/glass/glass_premium_own_layer_guard_test.dart`。
GlassQuality fushiGlassQuality(BuildContext context, {bool prominent = false}) {
  return switch (glassMaterialOf(context)) {
    FushiGlassMaterial.off ||
    FushiGlassMaterial.minimal => GlassQuality.minimal,
    FushiGlassMaterial.standard => GlassQuality.standard,
    FushiGlassMaterial.premium =>
      prominent ? GlassQuality.premium : GlassQuality.standard,
  };
}

/// 玻璃填充色。着色器档（standard / premium）与精简档都取库 iOS 27 的中性色调
/// （浅 #F8F8F8 @53%、深 白 @12%，`GlassThemeSettings.ios27Light` /
/// `ios27Dark`、`GlassThemeVariant.minimalLight` / `minimalDark` 同值），
/// **不**拿 MD3 容器色阶去染。off（实色）档是系统材质实色（深 #1C1C1E /
/// 浅 #F9F9F9）。[tint] 覆盖为有色玻璃（主按钮 / 选中态用强调色）。不透明的
/// [tint] 按档位重铺透明度（着色器 0.82 / 精简 0.9）；调用方已给半透明色（例如
/// 12% 前景色的轻着色）时保留调用方的透明度——一律拉到 0.82 会把轻着色压成近乎
/// 实心的色块。
Color fushiGlassFill(BuildContext context, {Color? tint}) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  final FushiGlassMaterial material = glassMaterialOf(context);
  if (tint != null) {
    if (tint.a < 1.0 && material != FushiGlassMaterial.off) return tint;
    return switch (material) {
      FushiGlassMaterial.standard ||
      FushiGlassMaterial.premium => tint.withValues(alpha: 0.82),
      FushiGlassMaterial.minimal => tint.withValues(alpha: 0.9),
      FushiGlassMaterial.off => tint,
    };
  }
  return switch (material) {
    FushiGlassMaterial.off =>
      dark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9),
    _ => dark ? kFushiGlassIos27DarkTint : kFushiGlassIos27LightTint,
  };
}

/// 库 iOS 27 浅色玻璃色调（`GlassThemeSettings.ios27Light.glassColor`）。
const Color kFushiGlassIos27LightTint = Color(0x87F8F8F8);

/// 库 iOS 27 深色玻璃色调（`GlassThemeSettings.ios27Dark.glassColor`）。
const Color kFushiGlassIos27DarkTint = Color(0x1FFFFFFF);

/// 单个玻璃组件的完整 settings（需要覆盖主题默认，例如有色主按钮）。
/// 着色器档取库 iOS 27 预设（[LiquidGlassSettings.ios27Light] /
/// [LiquidGlassSettings.ios27Dark]），精简档同 `GlassThemeVariant.minimalLight`
/// / `minimalDark`（模糊 8），只换填充色；实色档零模糊不透明。
LiquidGlassSettings fushiGlassSettings(BuildContext context, {Color? tint}) {
  final FushiGlassMaterial material = glassMaterialOf(context);
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  final Color fill = fushiGlassFill(context, tint: tint);
  switch (material) {
    case FushiGlassMaterial.standard:
    case FushiGlassMaterial.premium:
      return (dark
              ? LiquidGlassSettings.ios27Dark
              : LiquidGlassSettings.ios27Light)
          .copyWith(glassColor: fill);
    case FushiGlassMaterial.minimal:
      return LiquidGlassSettings(glassColor: fill, blur: 8, thickness: 10);
    case FushiGlassMaterial.off:
      // 实色档（2026-10-12 起的观感）参数原样保留。
      return LiquidGlassSettings(
        glassColor: fill,
        blur: 0,
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
  return fushiGlassSettings(context, tint: tint).copyWith(
    platformViewFallbackColor: fushiGlassPlatformViewFallback(context),
  );
}

/// Apple 悬浮胶囊（悬浮工具栏 / 动作组 / 迷你播放条 / 悬浮圆钮）的实色面：
/// 系统材质实色（深 #1C1C1E / 浅 #F9F9F9，[tint] 覆盖，如强调色圆钮）+ 0.5 px
/// 发丝描边 + 一层柔和投影。
///
/// 不用玻璃：悬浮胶囊常压在滚动列表、阅读器 / 视频画面上，每颗各开一层实时
/// 模糊（`useOwnLayer`）逐帧重采样，桌面与 Android 上明显掉帧，玻璃的亮边在
/// 浅色底上也是一圈刺眼的白边（用户 2026-10-12）。结构（分组胶囊、bar button
/// 尺寸、选中强调色字形）仍按 iOS 26，只是材质取实色。
ShapeDecoration fushiAppleSolidFloatingDecoration(
  BuildContext context, {
  required ShapeBorder shape,
  Color? tint,
}) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  final Color hairline = dark
      ? Colors.white.withValues(alpha: 0.10)
      : Colors.black.withValues(alpha: 0.08);
  final ShapeBorder outlined = shape is OutlinedBorder
      ? shape.copyWith(side: BorderSide(color: hairline, width: 0.5))
      : shape;
  return ShapeDecoration(
    color: tint ?? fushiGlassPlatformViewFallback(context),
    shape: outlined,
    shadows: <BoxShadow>[
      BoxShadow(
        color: Colors.black.withValues(alpha: dark ? 0.30 : 0.10),
        blurRadius: 16,
        offset: const Offset(0, 4),
      ),
    ],
  );
}

/// Apple 悬浮面（悬浮工具栏 / 动作组胶囊 / 迷你播放条 / 悬浮圆钮 / 侧栏浮板 /
/// 浮层菜单）：按玻璃画质档位（[glassMaterialOf]）在实色面与库玻璃之间切换。
///
/// - off（实色）：[fushiAppleSolidFloatingDecoration]，与 2026-10-12 起的观感
///   一致；
/// - 其余档：自带一层（`useOwnLayer`）的 [GlassContainer]，静态主表面按
///   [fushiGlassQuality] 的 prominent 口径取档（高级档 premium），参数取
///   [fushiGlassSettingsOverPlatformView]（压在阅读器 / 视频平台视图上时采不到
///   背景处显示系统材质实色）。
///
/// [shape] 支持 [CircleBorder]、[StadiumBorder] 与带 [BorderRadius] 的圆角矩形
/// / 平滑圆角（见 [fushiLiquidShapeOf]）。
///
/// [thick] = 承载成片正文的内容面板（视频设置 / 选集 / 章节 / 字幕面板、面板切换
/// 竖条）：取厚材质 [fushiThickMaterialSettings]，而不是控件级的薄玻璃。null =
/// 读祖先 [FushiThickMaterialScope]（默认薄）。
class FushiAppleFloatingSurface extends StatelessWidget {
  const FushiAppleFloatingSurface({
    super.key,
    required this.shape,
    this.tint,
    this.thick,
    this.child,
  });

  final OutlinedBorder shape;
  final Color? tint;
  final bool? thick;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (glassMaterialOf(context) == FushiGlassMaterial.off) {
      return DecoratedBox(
        decoration: fushiAppleSolidFloatingDecoration(
          context,
          shape: shape,
          tint: tint,
        ),
        child: child,
      );
    }
    final bool useThick = thick ?? FushiThickMaterialScope.of(context);
    return GlassContainer(
      useOwnLayer: true,
      quality: fushiGlassQuality(context, prominent: true),
      shape: fushiLiquidShapeOf(shape),
      settings: useThick
          ? fushiThickMaterialSettings(context, tint: tint)
          : fushiGlassSettingsOverPlatformView(context, tint: tint),
      platformViewBackdrop: fushiGlassOverPlatformView(context),
      child: child,
    );
  }
}

/// 厚材质的填充不透明度：深色 86%、浅色 90%（实色档 100%）。
///
/// 下限按「任何背景下正文对比度 ≥ WCAG AA 4.5:1」反推：最坏背景是与面板反色的
/// 纯白 / 纯黑画面（模糊后仍是纯色）。深色 #1C1C1E @86% 压在纯白上合成 ≈ #3C3C3D
/// （相对亮度 0.045）：白色正文 11:1，深色 secondaryLabel（#EBEBF5 @60%）4.5:1；
/// 浅色 #F9F9F9 @90% 压在纯黑上合成 ≈ #E0E0E0（0.75）：黑色正文 16:1。
const double kFushiThickMaterialDarkAlpha = 0.86;
const double kFushiThickMaterialLightAlpha = 0.90;

/// 厚材质（macOS `.regularMaterial` / `.thickMaterial`、iOS systemThickMaterial）
/// 的填充色：系统材质实色（深 #1C1C1E / 浅 #F9F9F9，[tint] 覆盖色相）按
/// [kFushiThickMaterialDarkAlpha] / [kFushiThickMaterialLightAlpha] 铺不透明度；
/// 实色档（[FushiGlassMaterial.off]）不透明。
Color fushiThickMaterialFill(BuildContext context, {Color? tint}) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  final Color base = tint ?? fushiGlassPlatformViewFallback(context);
  if (glassMaterialOf(context) == FushiGlassMaterial.off) {
    return base.withValues(alpha: 1);
  }
  return base.withValues(
    alpha: dark ? kFushiThickMaterialDarkAlpha : kFushiThickMaterialLightAlpha,
  );
}

/// 厚材质的玻璃 settings：大面积承载正文的面板（视频设置 / 选集 / 章节 / 字幕
/// 面板、tooltip 气泡）用。Apple 的分工是小控件（按钮、胶囊条）用清透液态玻璃，
/// 内容面板用厚材质——强模糊 + 高不透明底色，画面只透出很淡的色彩氛围，正文在
/// 任何画面下都可读（不透明度下限见 [kFushiThickMaterialDarkAlpha]）。
///
/// 不叠折射 / 高光边 / 色散：厚材质是磨砂板，不是透镜。实色档直接不透明、零模糊。
/// 带 [LiquidGlassSettings.platformViewFallbackColor]，压在 iOS / macOS 原生视图
/// 上采不到背景处是系统材质实色。
LiquidGlassSettings fushiThickMaterialSettings(
  BuildContext context, {
  Color? tint,
}) {
  final bool off = glassMaterialOf(context) == FushiGlassMaterial.off;
  return LiquidGlassSettings(
    glassColor: fushiThickMaterialFill(context, tint: tint),
    blur: off ? 0 : 30,
    thickness: 8,
    lightIntensity: 0,
    ambientStrength: 0,
    fresnelStrength: 0,
    chromaticAberration: 0,
    saturation: off ? 1.0 : 1.6,
    refractiveIndex: 1.0,
    shadowElevation: 0,
    platformViewFallbackColor: fushiGlassPlatformViewFallback(context),
  );
}

/// 子树里的 [FushiAppleFloatingSurface]（未显式给 `thick`）改用厚材质。给不便
/// 逐层传参的共用件用（例如视频侧面板旁的面板切换竖条 [FushiFloatingToolbar]）。
class FushiThickMaterialScope extends InheritedWidget {
  const FushiThickMaterialScope({
    super.key,
    this.thick = true,
    required super.child,
  });

  final bool thick;

  /// 最近祖先作用域的取值；没有作用域时 false（薄玻璃）。
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<FushiThickMaterialScope>()
          ?.thick ??
      false;

  @override
  bool updateShouldNotify(FushiThickMaterialScope oldWidget) =>
      oldWidget.thick != thick;
}

/// Flutter 形状 → 库的 [LiquidShape]：圆 → [LiquidOval]；胶囊 → 超大圆角的
/// [LiquidRoundedRectangle]（库按短边一半钳制）；平滑圆角 → 取左上角半径的
/// [LiquidRoundedSuperellipse]；其余圆角矩形 → [LiquidRoundedRectangle]。
LiquidShape fushiLiquidShapeOf(OutlinedBorder shape) {
  if (shape is LiquidShape) return shape;
  if (shape is CircleBorder) return const LiquidOval();
  if (shape is StadiumBorder) {
    return const LiquidRoundedRectangle(borderRadius: 999);
  }
  if (shape is RoundedSuperellipseBorder) {
    return LiquidRoundedSuperellipse(
      borderRadius: shape.borderRadius.resolve(TextDirection.ltr).topLeft.x,
    );
  }
  if (shape is RoundedRectangleBorder) {
    return LiquidRoundedRectangle(
      borderRadius: shape.borderRadius.resolve(TextDirection.ltr).topLeft.x,
    );
  }
  return const LiquidRoundedSuperellipse(borderRadius: 16);
}

/// 玻璃着色器「采不到背景」处的实色兜底（UIKit systemMaterial：深 #1C1C1E /
/// 浅 #F9F9F9）。库只在采样为空的像素上用它，采得到背景的地方照常是玻璃。
///
/// 不知道自己会压在什么上面的浮层（菜单、对话框、底部面板）一律带上：Android
/// 的 WebView 走 Hybrid Composition（见 [fushiPopupBackdropSampleable]），压在
/// 它上面的 Flutter 层落在独立 overlay surface 里，着色器采到的是空纹理——不带
/// 兜底就按透明黑合成，玻璃填充叠上去是一块灰矩形、高光是一团白斑（BUG-3055：
/// 有声书歌词模式「⋯」菜单）。iOS / macOS 的原生视图同理。
Color fushiGlassPlatformViewFallback(BuildContext context) {
  final bool dark = Theme.of(context).colorScheme.brightness == Brightness.dark;
  return dark ? const Color(0xFF1C1C1E) : const Color(0xFFF9F9F9);
}

/// 恒深色的控件层作用域：漫画阅读器 chrome、视频控件、页图上的空状态这类
/// 永远压在黑底 / 画面上的子树，Apple 设计系统下即使 app 是浅色也要用深色档
/// （白字、深色玻璃、强调色按深色档重建，见 [appleDarkColorsOf]），否则浅色
/// 档的黑色强调色主按钮压在黑底上直接隐形。
///
/// 结构恒定：无论设计系统 / 亮暗，[child] 永远挂在同一个 [Theme] +
/// [FushiGlassScope] 下；MD3、墨水屏与本就是深色的 app 直接沿用当前主题。
/// 深色主题按当前主题的设计系统 / 材质 / 字阶 / 外壳样式经 [buildFushiThemeData]
/// 重建（与主 app 的深色主题同一工厂），源主题上的其它扩展原样保留，按源主题
/// 缓存，不随每帧重建。
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
    final ThemeData rebuilt = buildFushiThemeData(
      scheme: theme.colorScheme.copyWith(
        brightness: Brightness.dark,
        primary: monochrome ? accent : appleDarkTierAccent(accent),
      ),
      textTheme: theme.textTheme.apply(bodyColor: label, displayColor: label),
      glass:
          theme.extension<FushiGlassTheme>()?.material ??
          FushiGlassMaterial.off,
      glassDesign: true,
      monochromeAccent: monochrome,
      // 外壳样式必须传回工厂（BUG-5208）：工厂缺省 `const FushiShellTheme()`
      // 不只产出同类扩展，平滑圆角还烤进菜单 / 对话框 / 卡片等组件形状，事后
      // 合并扩展救不回来。
      shell: theme.extension<FushiShellTheme>() ?? const FushiShellTheme(),
    );
    final ThemeData merged = rebuilt.copyWith(
      platform: theme.platform,
      // 源主题上工厂以外的扩展原样保留；工厂产物的同类扩展（设计系统 / 玻璃 /
      // 外壳 / 深色档 FushiAppleColors）在后、优先。不写显式类型实参：见
      // rethemeFushiWithScheme 的说明。
      extensions: [...theme.extensions.values, ...rebuilt.extensions.values],
    );
    _cache[theme] = merged;
    return merged;
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
  final FushiGlassMaterial material = glassMaterialOf(context);
  final bool dark = cs.brightness == Brightness.dark;
  final FushiAppleColors apple = appleColorsOf(context);
  final GlassThemeVariant base = switch (material) {
    FushiGlassMaterial.premium =>
      dark ? GlassThemeVariant.ios27Dark : GlassThemeVariant.ios27Light,
    FushiGlassMaterial.standard =>
      (dark ? GlassThemeVariant.ios27Dark : GlassThemeVariant.ios27Light)
          .copyWith(quality: GlassQuality.standard),
    FushiGlassMaterial.minimal =>
      dark ? GlassThemeVariant.minimalDark : GlassThemeVariant.minimalLight,
    // 实色档：minimal 组件族 + 不透明填充 + 零模糊（参数原样保留）。
    FushiGlassMaterial.off => GlassThemeVariant.minimal.copyWith(
      settings:
          (GlassThemeVariant.minimal.settings ?? const GlassThemeSettings())
              .copyWith(
                glassColor: fushiGlassFill(context),
                blur: 0.0,
                thickness: dark ? 14.0 : 18.0,
                lightIntensity: dark ? 0.18 : 0.45,
                ambientStrength: dark ? 0.0 : 0.12,
                fresnelStrength: dark ? 0.0 : 1.0,
                chromaticAberration: 0.01,
                saturation: 1.0,
                refractiveIndex: dark ? 1.12 : 1.2,
                edgeAbsorption: dark ? 0.0 : 0.03,
              ),
      quality: GlassQuality.minimal,
    ),
  };
  return base.copyWith(
    glowColors: GlassGlowColors(
      secondary: cs.primary,
      success: apple.success,
      warning: apple.warning,
      danger: apple.destructive,
      info: cs.primary,
    ),
  );
}
