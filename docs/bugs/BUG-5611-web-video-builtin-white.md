## BUG-5611 · web-video-builtin-white
- **报告**：2026-11-28（BUG-5591 前台验证时发现；同日用户现场反馈「浏览器视频用 fushi 播放，视频直接都是白的」，当时系统里唯一的实例正是 develop 分叉点 `e18ab28f1c8` 的 Release 构建）
- **真实性**：✅ 真 bug，既有问题，不是 BUG-5591 分支引入的。Release 前台复现：从 app 内浏览器打开 YouTube 观看页，点工具栏「用播放页打开」，播放页顶栏是「制卡优先」档，控制通道 `GET /api/admin/video/player` 报 `playing:true`，字幕照常出，但画面区域是纯白。BUG-5591 分支（`3ee74f7a3c7`）与它的 develop 分叉点 `e18ab28f1c8`（`D:\fushi-wt\fs-baseline` 的 Release）表现一致，所以与全屏改动无关。同一会话里 app 内浏览器页（共享环境，不是播放页用的可捕获环境）的 YouTube 画面正常。根因待查，`file:line` 未定位。
  - 已确认：「制卡优先」档（`fushi/lib/src/media/video/web_video_hosting.dart` 的 `WebVideoHosting.builtin`）不用窗口宿主，播放页的 `CustomPlatformView` 按设计不可见（`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview_manager.cpp:191`，非窗口宿主建成 `WS_CHILD` 不带 `WS_VISIBLE`），画面靠 WGC 离屏截取进 Flutter 纹理；所以「子窗隐藏」本身不是故障点。
  - 已确认：`D:\hibiki-dev-data\logs\native\wgc_capture.log` 里播放页那一路 WGC 池有 `frame-first-success`，截取链路有帧；白色更像截到的网页本身没画出视频（页面背景是白的），或纹理桥送出的帧不是视频那一层。下一步应在「画质优先」档（窗口宿主）对照、并在纹理桥 `custom_platform_view/texture_bridge.cc` 处落一帧像素确认白从哪一层来。
- **[ ] ① 未修复** — 根因未定位；需要单独任务沿 WGC → 纹理桥 → Flutter 纹理逐层取证。可捕获档环境参数见 `fushi/lib/src/media/video/web_video_session.dart:88`（`--disable-direct-composition`，WGC 截不到 DComp overlay 的已知约束），白屏可能是同类「视频层不进截取面」在非 DRM 站点上的表现，需实证。
- **[ ] ② 未加自动化测试** — 待根因确定后在最强可落地层补。
- **备注**：Windows 专属；网页视频 / WebView2 / 原生纹理类。复现素材：`https://www.youtube.com/watch?v=HrTvMpjmmsA`，开发数据根 `D:\hibiki-dev-data`。
