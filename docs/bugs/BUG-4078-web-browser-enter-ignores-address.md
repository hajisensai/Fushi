## BUG-4078 · web-browser-enter-ignores-address
- **报告**：2026-11-04（用户：应用内反馈 iCf7dQzT-t，Windows）浏览器入口页地址栏已填 bookwalker 链接，点「进入浏览器」没打开这个链接
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/fushi_web_browser_page.dart` 的 `_enterBrowser`（修前 :214-219）无条件 `push(fushiWebBrowserRoute(context, ''))`，完全不读 `_address.text`，只恢复上次的标签页；只有地址栏回车（`onSubmitted: _openAddress`）才打开输入
- **[x] ① 已修复** — `_enterBrowser` 先看 `_address.text.trim()`：非空走 `_openAddress`（与回车同一套 `resolveWebBrowserInput` 判据：网址打开、非网址按引擎搜索），为空才只恢复上次的标签页
- **[x] ② 已加自动化测试** — `fushi/test/pages/fushi_web_browser_shell_test.dart`「入口页地址栏有链接时点「进入浏览器」打开这个链接」（修前红：标签页只有 old.example）
- **备注**：按钮保留为独立按钮、文案不变（最小改动）；是否并进地址栏尾部动作留给产品取舍
