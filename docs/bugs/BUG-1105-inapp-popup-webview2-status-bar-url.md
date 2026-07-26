## BUG-1105 · app 内查词弹窗仍会冒 WebView2 链接地址预览（BUG-1097 只修了一半）

- **报告**：2026-07-26（用户：查词弹窗左下角冒出 `https://hibiki.popup/popup.html?query=…` 的 URL 提示）
- **真实性**：✅ 真 bug，且是**我方交付缺陷**——BUG-1097 的修复只覆盖了一个 surface。
  那一轮把 `put_IsStatusBarEnabled(FALSE)` 加在
  `hibiki/windows/runner/global_lookup_window.cpp` 的 `ConfigureWebView()` 里，那是 runner
  自有的裸 WebView2 原生覆盖窗，只服务 **app 外查词**。**app 内**的查词弹窗 / 阅读器 /
  词典 tab（入口 `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart:1030-1052`
  的 `InAppWebViewSettings(...)`）走的是 vendored fork
  `packages/flutter_inappwebview_windows`，而全仓 `IsStatusBarEnabled` 在修复后仍**只有
  runner 那一处**，fork 里一个都没有。两条路渲染的是**同一份** `hibiki/assets/popup/popup.js`
  （同一行 `element.setAttribute('href', node.href)`），所以 app 内 hover 词典内链时
  WebView2 照样在左下角画链接地址预览（那条路 base 是 `about:blank` / `file://`，URL 形态
  不同，但用户看到的同样是「左下角冒出一条地址」）。
  根因位置：`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp`
  的两处 settings 下发点从未设过该属性 —— `prepare()`（创建路径）与 `setSettings()`（Dart 热更新）。
- **[x] ① 已修复**（提交 94c41c2fb）— 在 fork 的
  `in_app_webview.cpp:268`（`prepare()`，创建路径）与 `:1640`（`setSettings()`，热更新路径）
  各加一次**无条件** `webView2Settings->put_IsStatusBarEnabled(FALSE)`。
  **为什么无条件、而不是加成一个 Dart 开关**：该属性的 Dart 侧字段要落在
  `flutter_inappwebview_platform_interface`（住在 pub-cache），本仓**只 vendor 了
  `flutter_inappwebview_windows`、没 vendor platform_interface**；加字段就得再 vendor 一个包
  并影响全平台。而 Hibiki 的每个 WebView 都只渲染 EPUB / 词典内容，没有任何 surface 想要
  浏览器状态栏，开关本身是伪需求。代码注释里已写明这个理由，避免后人误判为「漏了开关」。
  `put_IsStatusBarEnabled` 在**基类** `ICoreWebView2Settings` 上（编译头
  `Microsoft.Web.WebView2/build/native/include/WebView2.h`），`get_Settings` 拿到的指针即可，
  不需要 QI 新版本接口。
- **[x] ② 已加自动化测试** — 源码守卫
  `hibiki/test/lookup/inapp_webview_status_bar_guard_test.dart`：分别抽出 fork 的
  `InAppWebView::prepare` 与 `InAppWebView::setSettings` 函数体（边界实测 126 / 44 行，
  不是整文件兜底），断言**两处都**出现 `put_IsStatusBarEnabled(FALSE)`；另断言它没有被吊在
  某个不存在的 Dart 开关上，以及 `popup.js` 的 href 保持不动。与 BUG-1097 的
  `global_lookup_status_bar_guard_test.dart` 成对，两个 surface 各有一个守卫。
- **备注**：C++ 改动已用 `flutter build windows --debug` 真编译验证。
  **验证到哪一层要说清**：Windows 上 `takeScreenshot` 是 no-op，且 status bar 是 WebView2
  自己画的原生 overlay、不在 Flutter 语义树里，因此**无法用集成测试断言「左下角不再有
  URL」**。本轮验证止于「源码守卫 + 真编译」，肉眼复测（app 内弹窗 hover 词典内链）待用户/真机补。
  该 fork 是 path-override 的 vendored 包，改它必须重新编译 Windows 才生效。
