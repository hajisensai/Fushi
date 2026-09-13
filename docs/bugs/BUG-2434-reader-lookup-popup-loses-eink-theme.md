## BUG-2434 · 书内查词弹窗丢失墨水屏主题扩展，整个 html.eink 覆盖块失效
- **报告**：2026-09-10（用户：对比 Hoshi Reader Android 的查词框墨水屏适配，「现在查词框显示发虚，而且词典字体页发虚」）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart` 的
  `_syncDictionaryTheme()`：它手工 `ThemeData(useMaterial3: true, colorScheme: ...)` 拼出查词弹窗的
  覆盖主题，**没有 `extensions:`**。
  `FushiEinkTheme` 全仓只在 `ThemeNotifier._buildThemeData`（`theme_notifier.dart:1347-1350`）挂一次，
  任何不经它构造的 ThemeData 都会丢掉这个扩展。而这份覆盖主题经 `base_source_page.dart:634` 的
  `Theme(data: appModel.overrideDictionaryTheme ?? theme, ...)` 罩住**整个查词浮层子树**，
  `dictionary_popup_webview` 再用 `Theme.of(context)` 喂 `buildPopupStaticSettingsJs` →
  `popup_settings_injection.dart:110` 的 eink 判定恒 `false`。
  于是**只要是在书里查词**，`popup.css` 的整个 `html.eink` 覆盖块（纯黑白变量 / 去阴影 / 去
  text-shadow / 杀掉半透明亚克力卡底 / 方角 / 线式高亮 / 顶部按钮 opacity 压平）一行都不生效，
  `dictionary_popup_layer.dart:500` 的入场淡入归零也一并失效。app 外全局查词与视频字幕查词不设
  override，反而一直是对的——书内查词是最高频路径，却恰恰是唯一坏的那条，这也是它能长期潜伏的原因。
  **第二重根因**：即便把扩展补上，原实现仍会用 `deriveSurfaceRolesFrom(阅读器纸色)` 把
  `buildColorScheme()` 在墨水屏下本该纯黑白的 surface 角色整套覆盖回纸色派生的灰阶梯度
  （`onSurface` / `outline` / `surfaceContainer*` 全被换掉）。而正文 CSS 在 eink 下已被
  `reader_content_styles.dart:215-223` 强制成纯黑白 —— 结果就是「正文纯白底 + 弹窗纸色灰阶底」，
  而灰阶正是墨水屏上的抖动噪点。用户报的「发虚」在这两重下是叠加的。
- **[x] ① 已修复** —— 把覆盖主题的全部决策抽成纯函数 `resolveDictionaryPopupTheme()`
  （新文件 `fushi/lib/src/pages/implementations/dictionary_popup_theme.dart`），`_syncDictionaryTheme()`
  只负责把 AppModel / 阅读器主题的当前取值喂进去。两条不变式在同一处收口：
  - **必须挂 `FushiEinkTheme`**（`extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)]`）。
    非墨水屏时也挂、值为 `false`——弹窗要靠它把 `html.eink` **摘除**，只在开启时挂会让关掉墨水屏后
    卡在黑白方角态。
  - **墨水屏下跳过纸色派生**：`bg`/`fg` 取纯黑白，`brightness` 取 `appModel.isDarkMode`（与正文 CSS
    的 `einkDark` 同一真值，同样不读阅读器自己的 theme key），`ColorScheme` 直接用
    `buildColorScheme()` 的纯黑白结果，不再 `copyWith` 纸色梯度。
  - 非墨水屏下的语义**逐字节不变**（同一套 `deriveSurfaceRolesFrom` 梯度 + 同样保留 app 真实主题色）。
- **[x] ② 已加自动化测试** —— `fushi/test/dictionary/dictionary_popup_theme_test.dart` 共 5 条，直接
  断言纯函数返回值而不是扫源码（扫源码只能证明「写了这行字」，证明不了颜色真的没被覆盖）：
  浅色 / 深色墨水屏各断言「扩展为 true」+「surface/onSurface/surfaceContainerHigh 是纯黑白」+
  「纸色一点都渗不进来」（`isNot(paperBg)`）；非墨水屏断言纸色梯度、`onSurface`、`outline`、
  主题色 `primary` 全部原样保留，且扩展仍挂着只是值为 false。
  判别力验证：临时摘掉 `extensions:` 那一行 → 正好 3 条（两条 eink + 一条「扩展仍挂着」）当场红，
  其余 2 条仍绿；恢复后 5/5 绿。
  另在 `test/settings/md3_design_system_static_test.dart` 的两张豁免表登记新文件（理由：那段
  `ColorScheme.copyWith` 是逐字搬运自已豁免的 `chrome.part.dart`），并按同一条「不留死豁免」纪律
  删掉 `chrome.part.dart` 上已不再命中的 `surfaceContainerHighest/Low/Lowest` 三个 token。
- **备注**：
  - 与 [BUG-2435](BUG-2435-dict-style-preview-missing-eink.md)（词典样式预览不注入 eink）、
    [BUG-2436](BUG-2436-eink-popup-body-opacity-not-flattened.md)（正文侧半透明漏网）是同一条用户
    报告下的三个独立根因：本条管「书内查词弹窗根本没进过墨水屏模式」，2431 管「用户调样式时看的
    那份预览也没进」，2432 管「进了之后仍有十几处灰没压平」。
  - `FushiDesignSystemTheme` 在这份覆盖主题里**同样是丢失的**（`_buildThemeData` 挂了两个扩展，
    这里只补了 eink 那个）。默认 `auto` 下五平台统一 Material 3，丢它没有可见后果，故本轮不动以
    控制爆炸半径；真要补需连带复核隐藏的 Cupertino 渲染路径。
  - **验证边界（如实记录）**：整条链路已由单测闭环——「覆盖主题必须带 FushiEinkTheme」
    （`dictionary_popup_theme_test.dart`，含摘掉 extensions 就红的判别力验证）→「拿到扩展后注入串
    真的 toggle 出 `eink`」（`popup_settings_injection_memo_test.dart` 新增 group，含「丢了扩展恒
    false」这条正是本 bug 失效形态的用例）→「popup.css 里 html.eink 块存在且含新规则」
    （`popup_css_eink_guard_test.dart`）。剩下未被单测覆盖的只有「WebView 执行这段 JS」这一段，
    属既有行为（app 外全局查词一直走同一条注入、一直正常）。
    另在本机 Windows Release 真 app 上跑过启动冒烟（正常常驻、无早退）。
    **未做**：墨水屏设备目视复测（本机没有 Android 墨水屏），以及 headless 像素对照
    （本机 Chrome/Edge 的 `--screenshot` 开关已不产出文件、CDP 侧 Chrome 又立即退出，两条路都没走通）。
    观感层面的「锐利了多少」因此没有像素证据，待有设备时补。
