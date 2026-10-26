## BUG-3784 · web-video-site-floating-ball-unclickable
- **报告**：2026-10-26（用户：视频站点网页档里「网页的层级比悬浮球还高，点不到悬浮球了」（截图））
- **真实性**：✅ 真 bug。网页档 `WebVideoSession._applyInputEnabled`（`fushi/lib/src/media/video/web_video_session.dart`）让 WebView2 子窗口收输入，Win32 命中测试先落到子窗口，整块矩形里画在它上面的 Flutter 控件（悬浮球、查词框、对话框 / 菜单）看得见点不到。
- **[x] ① 已修复** — 原生 fork 加 `setWindowedInputExclusions`（`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.cpp` `applyWindowedRegion`：`SetWindowRgn` 挖掉圆角矩形）；Dart 侧 `UnderlayInputRegion` 登记区域（悬浮球本体 / 按钮 / 标签、查词弹窗），`WebVideoSurface` 换成本地坐标下发；本页路由被对话框 / 菜单 / 新页盖住时网页整个不收输入（`setCovered`）。（分支 `claude/webpage-loading-ui-issues-bd26d2`）
- **[x] ② 已加自动化测试** — `fushi/test/web_browser/web_page_underlay_and_menu_test.dart`「输入区：底层合成开着时上报全局矩形」（Dart 侧上报链）；SetWindowRgn 挖洞本身需 Windows 真机 + 带底层合成补丁的引擎验证，本轮未验。
- **备注**：
