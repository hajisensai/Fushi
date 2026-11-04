## BUG-4015 · 浏览器标签页被盖住 / 在后台时网页预告片仍自动播放
- **报告**：2026-11-04（用户：内置浏览器开着 Netflix 首页，从别处打开本地视频后，后面的网飞首页预告片开始自动播放）
- **真实性**：✅ 真 bug。浏览页被整页路由盖住时只转告各功能（`fushi/lib/src/pages/implementations/fushi_web_browser_page.dart:840` `_setCovered`），没有任何功能让 WebView 知道自己看不见了；页面媒体只在「用 Fushi 播放」交接时才按住（`fushi/lib/src/web_browser/features/play_in_fushi/play_in_fushi_feature.dart:33` `kWebBrowserHoldMediaScript`，仅 `_holdPage` 调用）。WebView2 仍是 `IsVisible=true`，页面 `visibilityState` 一直是 `visible`，Netflix 首页预告片照常自动播。浏览器内部被 `IndexedStack` 藏起的后台标签页同理。
- **[x] ① 已修复** — 新增 `WebBrowserPageVisibilityFeature`（`fushi/lib/src/web_browser/features/page_visibility/web_browser_page_visibility_feature.dart`）：标签页看得见 = 浏览页没被盖住且是前台页；变成看不见时先跑按住脚本、再 `pause()`（Windows：WebView2 `IsVisible=false` + `TrySuspend`；Android：`onPause`）/ `setAllMediaPlaybackSuspended`（iOS / macOS / Linux），看得见时倒序恢复。
- **[x] ② 已加自动化测试** — `fushi/test/web_browser/features/page_visibility/web_browser_page_visibility_feature_test.dart`（盖住 / 露出顺序、后台标签页、切前台页、换文档重新按住、快速来回、单步失败、关闭标签页）。
- **备注**：真机复测原始失败路径（开着 Netflix 首页再从别处打开本地视频）待补。
