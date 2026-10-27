## BUG-3856 · superseded-navigation-error-covers-page
- **报告**：2026-10-28（排查 BUG-3855 时的 Windows 真 app 探针发现：首开 YouTube 后点什么都没反应）
- **真实性**：✅ 真 bug。YouTube 首开会自行改址加 `&themeRefresh=1`，WebView2 把被顶掉的首个主框架导航以 `CONNECTION_ABORTED`（「Indicates that the connection was stopped.」）报 `onReceivedError`，且报在新导航 `onLoadStart` 之后；`fushi/lib/src/web_browser/tab_view/web_browser_tab_view.dart` `_onReceivedError` 不看错误属于哪次导航，直接 `_tab.setError`，「无法连接到该网站」失败页盖在已加载好的新文档上、吞掉所有点击（4 次真 app 运行 3 次出现，证据 `fushi/.codex-test/windows-itest/ytprobe1/2/4`）。描述与真断连同一句，取消类判据认不出。
- **[x] ① 已修复** — 新增 `WebBrowserNavigationLog`（`web_browser_load_errors.dart`）记录最近开始的主框架导航，`_onReceivedError` 丢弃「开始过但已不是最近一次」导航的错误；当前导航与没记录过的地址（重定向）照常显示。
- **[x] ② 已加自动化测试** — `fushi/test/web_browser/tab_view/web_browser_tab_view_logic_test.dart`「被顶掉的导航迟到的错误（BUG-3856）」4 条。
- **备注**：真 app 修后复测未单独跑（BUG-3855 探针提交前已改为清掉失败页再取证）。
