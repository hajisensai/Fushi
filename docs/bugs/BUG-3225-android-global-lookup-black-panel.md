## BUG-3225 · Android app 外查词窗词条区整块黑底、浅色主题文字看不见
- **报告**：2026-10-10（用户：「安卓的全局查词样式炸了修复一下」，附 AnkiDroid 复习界面调起的系统查词窗截图，查「こもってますね」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/components/fushi_material_components.dart` `FushiPopupSurface.build` 的 MD3 分支：`panelColor: Color.alphaBlend(primary 5%, (color ?? surfaceContainer).withValues(alpha: 1))`，以及 `_ApplePopupGlassBackdrop._buildGlass` 的 `opaque = panelColor.withValues(alpha: 1)`。
- **[x] ① 已修复** — `FushiPopupSurface` 把「显式全透明的 `color`」当作「本层不画面板」，背衬（玻璃 / 实底 / 原生材质）`enabled` 一律关掉（`_panelSuppressed`），MD3 与 Apple 两个分支同改。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/fushi_popup_surface_nested_fill_test.dart`「显式透明填充的内层不画面板（BUG-3225）」：外层独立窗卡面 + 透明内层，真实像素读内层中心必须等于外层卡面色；Android / Windows × MD3 / Apple × 浅 / 深 8 例。撤掉修复后 8 例全红（Android MD3 浅色读到 `#000505`，即用户截图里的黑）。
- **备注**：

### 根因
app 外查词窗（`popup_main` → `PopupDictionaryPage`）的整卡由外层 `FushiPopupSurface(standaloneWindow: true)` 画；基础层 `DictionaryPopupLayer` 有意传 `overrideFillColor: Colors.transparent`（`popup_dictionary_page.dart` `_buildLayer`），让外层卡面透出来，WebView 文档也透明（`html.mobile-external`）。

10-04 起的玻璃 / MD3 查词面板改造（`94b3aec67a` / `130fa3501e`，已在 upstream/develop）给装平台视图的 `FushiPopupSurface` 加了画在 WebView 背后的面板背衬，面板色取 `color.withValues(alpha: 1)`。`Colors.transparent` 是 `0x00000000`，把 alpha 拉到 1 就是**不透明纯黑**。Android 的 WebView 走 Hybrid Composition、采不到模糊（`fushiPopupBackdropSampleable` = false），于是走 `ColoredBox(opaque)`：词条区整块近黑（主色 5% 淡染）。WebView 里的词条文字仍按浅色主题出深色字，所以词头「こもる」、频率「2740」、音调「こもる [2]」在黑底上几乎看不见；词典释义卡片、变形标签等自带底色的元素照常浅色——与截图完全一致。

排除项：
- Android WebView algorithmic darkening / force dark：`:popup` 的 `PopupDictTheme` 继承 `Theme.DeviceDefault`（深色基底），但 targetSdk 35 下 WebView 的算法暗化需要显式 `setAlgorithmicDarkeningAllowed(true)`，全仓没有设（inappwebview 的 `algorithmicDarkeningAllowed` 缺省不下发）；而且算法暗化会连文字一起反色，截图里文字仍是浅色主题的深色字，对不上。黑块是 Flutter 层画在 WebView 背后的面板，与系统深色模式开关无关（系统浅 / 深都会出现）。
- 主题 CSS 变量没注入：`html.mobile-external` 让文档背景透明，变量照常注入，词典卡片颜色正确即为证。
- app 内查词弹窗正常：它们传的是不透明的 `overrideDictionaryColor` 或 null，从不传全透明色。

Windows / Linux 若有同形透明内层同样会画成 97% 黑（MD3 真模糊档）；修法与平台无关。

### 复现
无 adb 真机；Android 模拟器上 `:popup` 入口只能 build apk + am start，成本高。改用 widget test 真实像素渲染真 `PopupDictionaryPage`（Android 平台主题、浅 / 深）：改前图词条区整块黑底、空态文字几乎不可见，与用户截图同形；改后透出外层卡面。系统深色模式开关不影响 Flutter 层的这块面板（见上），app 浅 / 深主题两档都出图。
