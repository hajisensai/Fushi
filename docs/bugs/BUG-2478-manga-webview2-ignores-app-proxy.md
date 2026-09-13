## BUG-2478 · Windows 漫画源登录页/Cloudflare 页的 WebView2 不走 app 代理设置
- **报告**：2026-09-12（用户：「登录页好像没吃代理」）
- **真实性**：✅ 真 bug。`mihon_web_login_page.dart` / `aidoku_cloudflare_challenge_page.dart` 的 `InAppWebView` 没有任何代理装配；WebView2 默认跟 Windows 系统代理，与 app 的 `network_proxy_mode` / 手填代理无关（`app_proxy.dart` 那套只装到 `HttpClient` 与 native 中继）。用户选了手动代理或直连，登录页照走系统设置。
- **[x] ① 已修复** — `manga_web_view_environment.dart`：建环境时按 `resolveAppProxyHostPort()` + `appUserProxyModeReader()` 给 WebView2 浏览器参数（`MangaWebViewEnvironment.proxyArguments`）：手动/自动查到代理 → `--proxy-server=host:port`；直连 → `--no-proxy-server`（不能退回系统代理）；自动且没查到 → 跟系统。参数只能在建环境时给，所以按参数串缓存环境，用户改代理后换环境（先 dispose 旧的；同目录撞 `0x8007139F` 时退到按参数派生的兄弟目录）。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_locked_chapter_and_web_env_test.dart`（`proxyArguments` 三态）。
- **备注**：**已知边界**：手动代理带 Basic 认证时接不进去——WebView2 的代理认证走 `BasicAuthenticationRequested`，`packages/flutter_inappwebview_windows` 没暴露它；本机/局域网代理绝大多数不要认证，先不为它引原生改动。要做时在 fork 加该事件并接到 Dart `onReceivedHttpAuthRequest`。
