## BUG-2871 · macOS 查词浮层右侧出现白色竖条（WKWebView 透明背景只透了一半）
- **报告**：2026-10-02（用户：「mac 的查词条右侧有问题」，附阅读器竖排查词截图，深色主题）
- **真实性**：✅ 真 bug。根因在依赖 `flutter_inappwebview_macos` 1.1.2 `macos/Classes/InAppWebView/InAppWebView.swift:122`：`transparentBackground: true` 只把 `underPageBackgroundColor` 设成 `.clear`，**没关** WKWebView 自己的 `drawsBackground`。消费方 `fushi/lib/src/pages/implementations/dictionary_popup_webview.dart`（`transparentBackground: true`）。
- **[x] ① 已修复** — `ci/patches/hosted/flutter_inappwebview_macos-1.1.2/macos/Classes/InAppWebView/InAppWebView.swift`：`transparentBackground` 时 `setValue(false, forKey: "drawsBackground")` + `underPageBackgroundColor = .clear`（与本仓 `macos/Runner/GlobalLookupOverlay.swift:515` 同一配方），`setSettings` 运行时切换同步。
- **[x] ② 已加自动化测试** — `fushi/test/build/macos_webview_transparent_background_guard_test.dart`（源码扫描守卫 4 例：锁定版本 = 补丁目录版本；init / setSettings 两条路径关 drawsBackground；浮层仍请求透明背景）。真机取证用例 `fushi/integration_test/macos_popup_right_edge_probe_itest.dart`（需前台可见窗口，见备注）。
- **备注**：真机像素验证用独立 WKWebView 探针完成（同一份 popup.css、同一 WebKit，macOS 27.2，系统浅色外观），不占前台。App 内可见窗口复测需窗口在前台（被遮挡窗口无 vsync、隐藏模式 WKWebView 不渲染），用户在用机时未做，待补。

### 现象（用户截图像素采样，DPR 2）

浮层 WebView 区右缘 `x=1550..1565`（16 物理像素 = **8 CSS px**）：`x=1550` 一条 1px 灰线，`1551..1564` 纯白 `(255,255,255)`，自顶栏分隔线下一直铺到底，底部被卡片圆角裁掉；左侧文档区是主题深色 `(35,39,42)`。宽度与 `popup.css` 的 `::-webkit-scrollbar { width: 8px }` 一致。

### 根因

popup.css 的滚动条是经典（占位）`::-webkit-scrollbar`，轨道 `background: transparent`，「静止隐形」的前提是槽位透出**卡片底色**。html 背景只铺内容区，槽位里透出的是 WKWebView 自身的底层。插件在 macOS 上 `transparentBackground` 只清了 underPage 颜色，`drawsBackground` 仍为 true，WKWebView 在页面下铺系统默认底色——浅色外观下是白色，深色外观下是深色（因而只在「系统浅色 + App 深色主题」时肉眼可见）。Windows（WebView2 fork）与 iOS（插件设 `isOpaque=false`）不受影响。

### 验证

独立 WKWebView 探针（`loadFileURL` 加载真实 `fushi/assets/popup/popup.css` + 深色主题 + 可滚动长释义，`screencapture -l` 抓合成像素，宿主窗口底色 = 卡片色 `(35,39,42)`）：

| 配置 | 槽位 `x=944..959` 像素 |
|---|---|
| 插件原样（仅 `underPageBackgroundColor = .clear`） | `(255,255,255)` ← 复现白条 |
| 补丁（再加 `drawsBackground = false`） | `(36,39,42)` ← 透出卡片底色 |

`flutter build macos --debug` 带补丁编译通过；守卫 `flutter test test/build/macos_webview_transparent_background_guard_test.dart` 4/4。
