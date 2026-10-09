import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/theme_notifier.dart' show buildFushiThemeData;
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
/// 抽成纯函数是为了让不变式能被直接断言，而不是只能靠源码扫描间接钉：
///
/// **① 必须挂 [FushiEinkTheme]。** 这份 ThemeData 经 [buildFushiThemeData] 成型、
/// 由这里显式传入 [eink]，扩展才会跟过来。`popup_settings_injection` 判定墨水屏读的
/// 正是这个扩展：丢了它，判定恒 false，popup.css 的整个 `html.eink` 覆盖块（纯黑白
/// 变量 / 去阴影 / 去半透明卡底 / 方角 / 线式高亮）在**书内查词**这条最高频路径上
/// 一行都不生效，弹窗入场淡入也不归零。
///
/// **② 配色 = app 的 ColorScheme 本身，与外部查词模块同源。** 用户 10-09 定案「外部
/// 查词模块（浏览器扩展 / 桌面全局查词窗）的色彩才是对的，以它为准统一」：那两处
/// 直接用 `buildColorScheme(明暗)` 的整套角色（`AppModel.browserExtensionThemeColors`
/// / `global_lookup_render`）。书内弹窗此前在 app ColorScheme 之上再用阅读器纸色
/// 派生的中性梯度覆盖整条表面角色与正文色：卡片、展开后的词典块
/// 变成纸色派生的灰阶，粉色等主题的表面色调被抹掉，歌词模式 / 不同纸色下同一个
/// 弹窗各是一套颜色（截图：粉色主题高亮被拉暗、展开后的灰色别扭、歌词模式查词色彩
/// 和别处不一致）。现在书内弹窗不再做纸色覆盖，外壳填充取同一 scheme 的 surface，
/// 四个查词表面同一套颜色。
///
/// 唯一跟阅读器走的是**明暗**（[readerDark]）：深色纸上弹出浅色弹窗刺眼，故取阅读器
/// 主题的明暗去建同一个 app ColorScheme。墨水屏下 [einkDark] 取 app 的明暗模式，与
/// 正文 CSS 的 `einkDark` 同一真值；[buildColorScheme] 传 `AppModel.buildColorScheme`，
/// 它在墨水屏下本就返回纯黑白 ColorScheme。
///
/// [textTheme] / [designSystem] / [glassDesign] / [glass] / [monochromeAccent] 取 app
/// 当前值，原样交给 [buildFushiThemeData]：覆盖主题因此同样挂上 `FushiGlassTheme` 与
/// `FushiAppleColors`，书内查词弹窗在 Apple 设计系统下不回落成 MD3。墨水屏下 Apple
/// 设计系统本就不生效（`buildFushiThemeData` 内 `glassDesign && !eink`）。
///
/// [lyricsCoverScheme]：歌词模式（MD3）下歌词页按封面取色得到的那份 ColorScheme
/// （`LyricsThemeHostState.coverScheme`，歌词页自己也是拿它经
/// `rethemeFushiWithScheme` → [buildFushiThemeData] 重走工厂）。非 null 时弹窗
/// 直接复用这份 scheme——歌词页铺的是封面色，再用 app scheme 就是「青色歌词页上
/// 弹出紫色弹窗」的撞色。明暗随 scheme 本身（与歌词页一致）。墨水屏与 Apple 设计
/// 系统下忽略：墨水屏要纯黑白，Apple 歌词页恒深色档、不吃封面色。
DictionaryPopupTheme resolveDictionaryPopupTheme({
  required bool eink,
  required bool einkDark,
  required bool readerDark,
  required ColorScheme Function(Brightness brightness) buildColorScheme,
  required TextTheme textTheme,
  FushiDesignSystem designSystem = FushiDesignSystem.auto,
  bool glassDesign = false,
  FushiGlassMaterial glass = FushiGlassMaterial.off,
  bool monochromeAccent = false,
  ColorScheme? lyricsCoverScheme,
}) {
  final Brightness brightness = eink
      ? (einkDark ? Brightness.dark : Brightness.light)
      : (readerDark ? Brightness.dark : Brightness.light);
  final ColorScheme scheme = buildColorScheme(brightness);
  final bool apple = glassDesign && !eink;
  final ColorScheme? lyricsScheme = eink || apple ? null : lyricsCoverScheme;
  final ThemeData theme = buildFushiThemeData(
    scheme: lyricsScheme ?? scheme,
    textTheme: textTheme,
    eink: eink,
    designSystem: designSystem,
    glass: eink ? FushiGlassMaterial.off : glass,
    glassDesign: apple,
    monochromeAccent: monochromeAccent,
  );
  return DictionaryPopupTheme(
    theme: theme,
    // 外壳填充 = 主题自己的 surface（墨水屏 scheme 的 surface 即纯白 / 纯黑），
    // 与主题同源不出色带，也与外部查词模块的 popupCardSurface(scheme) 一致。
    fillColor: theme.colorScheme.surface,
  );
}
