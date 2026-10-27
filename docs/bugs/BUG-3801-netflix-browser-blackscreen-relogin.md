## BUG-3801 · Windows 浏览器里看 Netflix 黑屏卡顿，「用 Fushi 播放」要重新登录且要点两次
- **报告**：2026-10-27（用户截图：浏览器标签页 netflix.com/watch/… 画面全黑、卡；点右上角「用 Fushi 播放」进播放页又要求重新登录，没直接成播放器，看个视频要点两次）
- **真实性**：✅ 真 bug。三处根因：
  1. 重新登录：浏览器标签页用 `MangaWebViewEnvironment`（`%LOCALAPPDATA%\Fushi\MangaWebView2`，`fushi/lib/src/web_browser/tab_view/web_browser_tab_view.dart` `_prepareEnvironment`），播放页窗口宿主档用独立的 `WebVideoWebView2-4k` 环境；`copyWebVideoLoginCookies`（`fushi/lib/src/media/video/web_video_session.dart`）只从内置档 `WebVideoWebView2` 抄 cookie，从不读浏览器的 cookie 罐。站点并进浏览器（2026-10-26）后用户是在浏览器里登录的，播放页自然没登录态；没登录就没有 `<video>`，`_webPlayerModeFor` 恒为 false，所以停在网页档、「没换成播放器」。
  2. 黑屏 / 卡：浏览器标签页的画面是捕获合成的，Netflix DRM 视频走 DComp overlay，捕获出来是纯黑（同 `webVideoCapturableEnvironment` 注释里的结论），4K 捕获还卡。浏览器标签页本来就播不了，只有播放页窗口宿主档有硬件 PlayReady。
  3. 点两次：浏览器进了 Netflix 观看页不会自动交给播放页，必须再手点「用 Fushi 播放」。
- **[x] ① 已修复** — `copyWebVideoLoginCookies` 改为按 `kWebVideoLoginCookieSources` 依次从内置档与 app 内浏览器环境抄 cookie（浏览器后抄、同名覆盖，单个来源失败不挡其它）；`WebBrowserFeature` 新增 `onUrlChanged`（接 `onUpdateVisitedHistory`，覆盖 SPA pushState 换页），`PlayInFushiFeature` 在有播放页的平台、非无痕标签页进入 `webBrowserWatchPageNeedsPlayer`（Netflix `/watch/`）时自动交给播放页并让标签页退回上一页，同一地址每个标签页只自动交一次。
- **[x] ② 已加自动化测试** — `fushi/test/web_browser/web_browser_site_player_test.dart`「浏览器播不了的观看页：只有 Netflix /watch/ 自动交给播放页」。
- **备注**：cookie 跨环境复制与 WebView2 自动交接依赖真实 WebView2 / PlayReady，单测覆盖不到；未在真机复测 Netflix 登录态是否完整带过去（HttpOnly 的 `NetflixId` / `SecureNetflixId` 走 fork 的 CDP getCookies，与原内置档复制同一路径）。
