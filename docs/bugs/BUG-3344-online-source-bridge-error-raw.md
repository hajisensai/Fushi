## BUG-3344 · AI 下载漫画失败时把 BRIDGE_HTTP_500 原始异常甩给用户
- **报告**：2026-10-14（用户：反馈 iFzLzVLYAd，Windows，「显示500应该去登录吧」，截图是 AI 下载 · 漫画页的错误气泡）
- **真实性**：✅ 真 bug。① `fushi/lib/src/media/acquisition/media_acquisition_backends.dart:287` / `:372` 把异常 `'$error'` 原样塞进 toast，用户看到 `OnlineMangaUnavailable(...): MihonRuntimeException(BRIDGE_HTTP_500): Cef was not initialized.`；② 即便走统一文案 `describeOnlineSourceErrorText`，`fushi/lib/src/media/online/online_source_error_text.dart:18` 的 HTTP 状态正则也会把 `BRIDGE_HTTP_500`（桌面 sidecar 自己的信封状态，站点 HTTP 错误另走 `SOURCE_HTTP_*`）说成「来源返回错误（HTTP 500）」，把扩展抛出的真实原因抹掉。本例真实原因是桌面 Mihon sidecar 从未初始化 KCEF（`third_party/m_extension_server` 里没有 `KCEF.init`），需要 WebView 的扩展在桌面端必然失败——与登录无关，重试无用。
- **[x] ① 已修复** — 两处 toast 改走 `describeOnlineSourceError(logTag:)`（原文照写错误日志）；HTTP 状态正则加 `(?<!BRIDGE_)`，`BRIDGE_HTTP_*` 露出扩展自己的说明；新增 `Cef was not initialized` / `kcef` 判据映射成「这个来源需要内置浏览器（WebView），桌面版暂不支持」（i18n `online_source_error_webview_unavailable`）。提交 d8830baef6（分支 `cc/fb-misc-ui`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/online/online_source_error_text_test.dart`（反馈原文串、`BRIDGE_HTTP_500/503` 露出说明、`SOURCE_HTTP_503` 仍映射状态码）。
- **备注**：桌面 sidecar 补 KCEF（内置 CEF 运行时）才能让这类扩展真正可用，体积与打包代价大，未在本修复范围。
