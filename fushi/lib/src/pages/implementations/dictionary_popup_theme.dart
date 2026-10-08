import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/theme_notifier.dart'
    show SurfaceRoles, buildFushiThemeData, deriveSurfaceRolesFrom;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiDesignSystem, FushiEinkTheme, FushiGlassMaterial;

/// 查词弹窗覆盖主题的解析结果：罩住整个查词浮层的 [theme]，以及弹窗外壳的
/// [fillColor]。两者必须同源——外壳填充色与主题的 surface 一旦差一个色阶，
/// 弹窗边缘就会出现一圈色带。
@immutable
class DictionaryPopupTheme {
  const DictionaryPopupTheme({required this.theme, required this.fillColor});

  /// 罩住查词浮层子树的覆盖主题（`base_source_page.buildDictionary` 用它包住
  /// 整棵浮层树，`dictionary_popup_webview` 再从中读出注入 WebView 的主题变量）。
  final ThemeData theme;

  /// 弹窗外壳（Flutter 侧 Material）的填充色。
  final Color fillColor;
}

/// 书内查词弹窗覆盖主题的**单一决策点**。
///
/// 抽成纯函数是为了让两条不变式能被直接断言，而不是只能靠源码扫描间接钉：
///
/// **① 必须挂 [FushiEinkTheme]。** 这份 ThemeData 用的是纸色 scheme，不是
/// `ThemeNotifier.theme` 本身；它经 [buildFushiThemeData] 成型、由这里显式传入
/// [eink]，扩展才会跟过来。而
/// `popup_settings_injection` 判定墨水屏读的正是这个扩展：丢了它，判定恒 false，
/// popup.css 的整个 `html.eink` 覆盖块（纯黑白变量 / 去阴影 / 去半透明卡底 /
/// 方角 / 线式高亮）在**书内查词**这条最高频路径上一行都不生效，弹窗入场淡入
/// 也不归零。后果不是「少一点动画」，而是墨水屏适配整体失效。
///
/// **② 墨水屏下不做纸色覆盖。** 正文在 eink 下已被 `ReaderContentStyles.css`
/// 强制成纯黑白，而阅读器主题解析出的 `readerBackground` / `readerForeground`
/// 走的是主题 preset 手调底色、完全不看 eink。照常派生中性梯度就会出现「正文
/// 纯白底 + 弹窗纸色灰阶底」的割裂，而灰阶正是墨水屏上的抖动噪点。
///
/// [einkDark] 取 app 的明暗模式，与正文 CSS 的 `einkDark` 同一真值（同样**不**读
/// 阅读器自己的 theme key）。[buildColorScheme] 传 `AppModel.buildColorScheme`，
/// 它在墨水屏下本就返回纯黑白 ColorScheme。
///
/// [textTheme] / [designSystem] 取 app 当前值（`AppModel.textTheme` /
/// `ThemeNotifier.designSystemTheme`）：弹窗 Flutter 外壳的组件主题与字号阶梯
/// 与主 app 同源，只有中性表面换成纸色。
///
/// [glassDesign] / [glass] / [monochromeAccent] 取 app 当前的设计系统（偏好
/// `design_system == 'glass'`）、玻璃材质（`ThemeNotifier.glassMaterial`）与单色
/// 强调色判据，原样交给 [buildFushiThemeData]：覆盖主题因此同样挂上
/// `FushiGlassTheme` 与 `FushiAppleColors`，书内查词弹窗在 Apple 设计系统下
/// 不再回落成 MD3。Apple 设计系统的内容层是系统分组色（见
/// `appleColorScheme`），不做纸色派生——表面整套换成 Apple 系统色、亮暗仍跟
/// 阅读器纸色；外壳填充随之取主题的页面底，与主题同源不出色带。墨水屏下
/// Apple 设计系统本就不生效（`buildFushiThemeData` 内 `glassDesign && !eink`）。
DictionaryPopupTheme resolveDictionaryPopupTheme({
  required bool eink,
  required bool einkDark,
  required Color readerBackground,
  required Color readerForeground,
  required bool readerDark,
  required ColorScheme Function(Brightness brightness) buildColorScheme,
  required TextTheme textTheme,
  FushiDesignSystem designSystem = FushiDesignSystem.auto,
  bool glassDesign = false,
  FushiGlassMaterial glass = FushiGlassMaterial.off,
  bool monochromeAccent = false,
}) {
  final Color bg =
      eink ? (einkDark ? Colors.black : Colors.white) : readerBackground;
  final Color fg =
      eink ? (einkDark ? Colors.white : Colors.black) : readerForeground;
  final Brightness brightness = eink
      ? (einkDark ? Brightness.dark : Brightness.light)
      : (readerDark ? Brightness.dark : Brightness.light);
  final ColorScheme scheme = buildColorScheme(brightness);

  // 非墨水屏：弹窗配色 = app 真实 ColorScheme（主题色 / 高亮 / 描边跟用户主题）
  // + 纸色与字色盖上去的中性角色，与编辑页预览共用 [deriveSurfaceRolesFrom]。
  final bool apple = glassDesign && !eink;
  ColorScheme dictionaryScheme = scheme;
  if (!eink && !apple) {
    final SurfaceRoles paper = deriveSurfaceRolesFrom(bg);
    dictionaryScheme = scheme.copyWith(
      surface: paper.surface,
      surfaceDim: paper.surfaceDim,
      surfaceBright: paper.surfaceBright,
      surfaceContainerLowest: paper.surfaceContainerLowest,
      surfaceContainerLow: paper.surfaceContainerLow,
      surfaceContainer: paper.surfaceContainer,
      surfaceContainerHigh: paper.surfaceContainerHigh,
      surfaceContainerHighest: paper.surfaceContainerHighest,
      onSurface: fg,
      onSurfaceVariant: paper.onSurfaceVariant,
      outline: paper.outline,
      outlineVariant: paper.outlineVariant,
      inverseSurface: paper.inverseSurface,
      onInverseSurface: paper.onInverseSurface,
      surfaceTint: Colors.transparent,
    );
  }

  final ThemeData theme = buildFushiThemeData(
    scheme: dictionaryScheme,
    textTheme: textTheme,
    eink: eink,
    designSystem: designSystem,
    glass: eink ? FushiGlassMaterial.off : glass,
    glassDesign: apple,
    monochromeAccent: monochromeAccent,
  );
  return DictionaryPopupTheme(
    theme: theme,
    fillColor: apple ? theme.colorScheme.surface : bg,
  );
}
