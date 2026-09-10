## BUG-2431 · 词典样式预览不注入 eink class，墨水屏下预览与真弹窗不同源
- **报告**：2026-09-10（用户：「而且词典字体页发虚」，与 [BUG-2430](BUG-2430-reader-lookup-popup-loses-eink-theme.md) 同一条报告）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/pages/implementations/dict_style_preview.dart` 的
  `_bootstrap()`：它只 `document.documentElement.setAttribute('data-theme', ...)`，**从不 toggle
  `eink` class**。
  该文件开头明写「不自绘近似渲染……这里渲染路径与真弹窗同源」——预览跑的确实是**真的**
  `popup.html` + `popup.js`。但真弹窗的 eink class 由 `popup_settings_injection.dart:110-112` 的主题
  变量段 toggle，而 popup.css 的整个 `html.eink` 覆盖块挂的就是这个 class。预览少了这一段，于是
  墨水屏下**用户是照着一份灰阶 + 圆角 + 阴影 + 半透明卡底的预览去调词典字体/字号/配色，而真弹窗
  是另一个样子**——正好是那句「近似的东西必然失真」要避免的情形，只是失真来自缺一个 class 而不是
  自绘。
  第二个缺口：即便首帧补上，`_bootstrap()` 是一次性的，开着预览去翻墨水屏开关不会有任何反应。
- **[x] ① 已修复** —— 抽出 `_pushTheme()`：从 `Theme.of(context)` 读 `FushiEinkTheme`，一并下发
  `data-theme` 与 `classList.toggle('eink', <bool>)`。
  - 用 `toggle` 而非 `add`，与真弹窗同款——`add` 摘不掉，关掉墨水屏后预览会卡在黑白方角态。
  - 在 `didChangeDependencies` 里调用，主题切换（含墨水屏开关）当场补推；用 `_pushedDark` /
    `_pushedEink` 记住上次真正推下去的值，避免每次依赖变化都重复 `evaluateJavascript`。
  - `_bootstrap()` 在 `_ready = true` 之后先 `_pushTheme()` 再 `_pushStyles()`，保证首帧就带上。
- **[x] ② 已加自动化测试** —— `fushi/test/dictionary/dict_style_preview_eink_guard_test.dart` 共 4 条
  源码守卫：读得到 `FushiEinkTheme`、真的 `classList.toggle('eink'`、**不**用 `classList.add('eink'`
  （摘不掉的反向断言）、以及存在 `didChangeDependencies`（只在 bootstrap 推一次会让开关无反应）。
  只能做源码守卫的原因与既有 `popup_instant_scroll_guard_test` 同处境：预览的渲染发生在真 WebView
  里，单元测试环境没有 WebView，断言不到最终像素，故钉的是「注入链路上每一段载荷位都还在」。
- **备注**：
  - 预览的 `InAppWebView` 是 `transparentBackground: false`（真弹窗是 `true`），本轮未动。
  - 真机复测状态见 [BUG-2430](BUG-2430-reader-lookup-popup-loses-eink-theme.md) 的「验证」一节
    （同一次真 app 复测覆盖两条）。
