## BUG-3769 · Windows 浏览器证书错误停在 WebView2 自带拦截页，app 失败页不出现
- **报告**：2026-10-24（用户：浏览器已知问题之一——Windows 上证书错误显示 WebView2 自带的拦截页，不是 app 的失败页）
- **真实性**：✅ 真 bug，两段都在 Windows fork（`packages/flutter_inappwebview_windows`）：
  1. 原生 `NavigationCompleted`（`windows/in_app_webview/in_app_webview.cpp`，原 `else if (!InAppWebView::isSslError(webErrorType) && navigationAction)`）把 `COREWEBVIEW2_WEB_ERROR_STATUS` 1–5（证书错误）滤掉，留给上游从未实现的 ServerTrustAuth 回调，`onReceivedError` 根本不发。
  2. 去掉过滤后 Dart 侧仍收不到：`lib/src/in_app_webview/in_app_webview_controller.dart` 的 `onReceivedError` 分支调平台接口 `WebResourceError.fromMap`，它对 type 做 `WebResourceErrorType.fromNativeValue(type)!`，而平台接口 1.3.0 没给 1–5 号状态配 Windows 值 → 通道回调里抛空值异常，事件丢失。离屏真 app 实测第一轮仍停在「你的连接不是专用连接 / NET::ERR_CERT_AUTHORITY_INVALID」，`tab.error == null`。
- **[x] ① 已修复** — 原生不再过滤证书错误（删掉 `isSslError`）；fork 控制器改用 `_webResourceErrorFromMap`，无对应枚举的状态归 `UNKNOWN`、保留原生描述（"Indicates that the SSL certificate …"），由 `classifyWebBrowserMainFrameError` 按描述归到 `WebBrowserLoadErrorKind.certificate`。
- **[x] ② 已加自动化测试** — `fushi/integration_test/web_browser_shell_itest.dart`「证书错误失败页」：运行时用 openssl 生成自签证书起 HTTPS 站点（私钥不入库），在真 WebView2 里加载，断言失败页类别为证书；描述→类别的纯函数映射已由 `fushi/test/web_browser/tab_view/web_browser_tab_view_logic_test.dart` 覆盖。
- **备注**：app 失败页不提供「仍然继续访问」（WebView2 拦截页的「高级 › 继续」随之不再可达），证书错误一律拦下。
