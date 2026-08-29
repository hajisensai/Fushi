# 网页流媒体播放器（Windows）+ Anime4K 超分复用 mpv 管线

日期：2026-08-29 · 分支 `worktree-web-video-player` · 范围：仅 Windows（fork WebView2 纹理链路只有 Windows）

## 0. 问题重述

- Fushi 现有「流媒体书」（直链 / YouTube / WebDAV / Jellyfin）全部走 libmpv，Anime4K 五档已在
  `video_player_controller.dart:1437` 无条件下发——**流媒体早就有超分**。
- 真正缺的是 `url_stream_video.dart:39 kKnownWebPageVideoHosts` 那类「网页播放页」站（Netflix /
  Prime / Abema / B 站 / TVer / Hulu JP / YouTube 页……）：mpv 解不出 HTML，Fushi 里**根本播不了**。
  超分是第二步，第一步是先能播。
- 字幕不在 DRM 保护范围（DRM 只锁音视频）。仓库 `tools/browser-extension/` 已有整套明文字幕抓取：
  `netflix-bridge.js`（JSON.parse hook 嗅 timedtexttracks）、`stream-bridge.js`（asbplayer 移植：
  TVer / Bilibili.tv / Hulu JP / Prime）、`youtube-bridge.js`、`content.js` 通用 `video.textTracks`
  收割 + DOM 采样，`subtitle-adapters.js` 纯函数 WebVTT/TTML/bbjson 解析。全部 MIT。

## 1. 目标 / 非目标

目标（三个 PR 顺序落地）：
1. **P1 网页播放器页**：Fushi 内用 WebView2（fork）播放上述站点；字幕管线进程内复用扩展 JS；
   字幕列表 + 当前句查词走现有 `VideoSubtitleJumpPanel` / `DictionaryPopupLayer`。
2. **P2 超分**：WebView2 帧经 fork 已有 WGC→D3D11 纹理链路 tap 出来，喂给 **libmpv 现有管线**
   （rawvideo + `mpv_stream_cb`），Anime4K 五档 / mpv 高画质缩放 / 用户勾选的任意 `.glsl`
   **一字不改**对网页播放器生效。
3. **P3 制卡**：句音频（runner 已有 `audio_loopback_capture.cpp` WASAPI loopback）+ 截图 → 现有
   mining 通道。

非目标：
- **不做**站点直链 extractor（此前口头提的「第 1 步」砍掉：每站逆向、永久维护、B 站 WBI/cookie
  一类的脆弱链路，而 WebView 播放器通吃，超分覆盖后收益归零）。
- **不做** Magpie 式外挂（抓任意窗口、置顶覆盖窗）。Fushi 不是通用超分器。
- **不绕** DRM：硬件 DRM（PlayReady SL3000 / Widevine L1）受保护输出在 WGC 下是黑帧，Magpie
  同样黑；检测到即提示「受保护内容，无法增强」并关闭超分叠层，不做任何规避。
- 移动端 / macOS / Linux：WebView 无纹理中间层，本计划不覆盖、不假装覆盖。

## 2. 数据流（P2 终态）

```
站点页面 ──WebView2(fork)──▶ WGC on visual ──▶ src_texture (D3D11, 视频原生分辨率)
                                                  │  TextureBridgeGpu::ProcessFrame
                                                  ├─▶ surface_ → Flutter 纹理（现状，超分关时显示）
                                                  └─▶ [tap 开启时] staging ring(3) → Map → 帧队列
                                                                  │
                          libmpv  ◀── mpv_stream_cb_add_ro("fushiwv") ── read() 阻塞等下一帧
                          demuxer=rawvideo(bgra) · untimed · demuxer-thread=no · cache=no · audio=no
                          glsl-shaders / scale=ewa_lanczossharp（现有 applyShadersToPlayer / applyMpvConfigToPlayer）
                                                  │
                          media_kit VideoController 纹理 ──▶ Flutter `Video`（IgnorePointer，铺满）
站点 JS（注入的扩展 bridge）──cues / currentTime / videoWidth×Height──▶ Dart（addJavaScriptHandler）
```

关键点：
- **捕获尺寸 = 视频原生尺寸，不是视口尺寸**。否则 Chromium 先双线性把 720p 拉到视口，我们再对
  一张模糊图跑 Anime4K，是假超分。JS 上报 `videoWidth/Height` → Dart 把 WebView2 逻辑尺寸 /
  `RasterizationScale` 设成原生尺寸，mpv 负责放大到视口（与 Magpie「小窗渲染、全屏放大」同理）。
- 输入不换手：`InAppWebView` 在 Stack 底层照常收指针/键盘；mpv 输出层 `IgnorePointer`。站点自己的
  控件叠在被捕获帧里，用户透过超分层看到并点到。
- 为什么是「喂 mpv」而不是 fork 里再搭一套着色器运行时：mpv 就是本 app 唯一的着色器运行时。
  libplacebo D3D11 pass（方案 A）GPU 零拷贝更优雅，但要新引 MinGW/vcpkg 构建的 libplacebo +
  glslang/spirv-cross 依赖链、新 CI 自建 artifact（仿 `ffmpeg-min.yml`）、本机现无 MSYS2/vcpkg 无法
  本地验证；在 P2 延迟实测不可接受前不值得。方案 B 代价是 GPU→CPU→GPU 一次往返（1080p60 ≈
  500 MB/s memcpy）+ 1~2 帧延迟；Dart 侧接口两方案相同，升级 A 不动 Dart。

## 3. 阶段拆分

### P1 网页播放器页（Dart + JS）

改动：
- `fushi/lib/src/pages/implementations/web_video_fushi_page.dart`（新）：
  - `InAppWebView`（fork）加载站点 URL；`initialUserScripts`（`DOCUMENT_START`，主世界——WebView2
    无隔离世界）注入：`subtitle-adapters.js` + `netflix-bridge.js` + `stream-bridge.js` +
    `youtube-bridge.js` + 新胶水 `web_video_glue.js`（替代 `content.js` 接收端：收 bridge 的
    postMessage cue → `window.flutter_inappwebview.callHandler('fushiCues', …)`；`timeupdate` /
    `play` / `pause` / `loadedmetadata` 上报 `currentTime` / `paused` / `videoWidth×Height`；
    通用 `video.textTracks` 收割从 content.js 抽出成纯函数进胶水）。
  - 布局：`Stack[ InAppWebView, 底部当前句条(可点词→DictionaryPopupLayer), 右侧 VideoSubtitleJumpPanel ]`；
    `onTapCue` → JS `video.currentTime = startMs/1000`（Netflix 走 `netflix-bridge.js` 的官方
    播放器 seek，直接改 currentTime 会 M7375）。
  - 查词：`DictionaryPopupLayer` + `DictionaryPopupWebView` 热槽（与视频页同款，`FushiAppUiScaleNeutralizer`
    中和）。
- JS 复用不复制：扩展 JS 作为 asset 引用需要在 `fushi/` 下——按 popup.js 三镜像同一模式镜像到
  `fushi/assets/web_video/`，加字节一致守卫测试（`fushi/test/tools/web_video_js_mirror_guard_test.dart`），
  `tool/bootstrap.ps1` 不参与（镜像入库）。
- 入口：`stream_video_launch.dart` 分流——`videoPath` 命中 `isKnownWebPageVideoUrl` 且 Windows →
  新页；导入弹窗对命中站点的软警告改为「用网页播放器打开」（非 Windows 保持现状）。
- 状态：断点用 `videoPath + currentTime` 落现有流媒体书 prefs 路径（`jimaku_batch.dart:36` 同口径）。

测试：
- JS：`web_video_glue.test.js`（node，沿用扩展测试沙箱：bridge cue → callHandler 载荷形状、
  textTracks 收割、seek 分流 Netflix/通用）。
- Dart：launch 分流纯函数、cue 载荷→`AudioCue` 转换、镜像守卫、新页 widget 冒烟（无 WebView 桩）。
- 真机：Windows 本机 Netflix + B 站各一：字幕列表出现、点句跳转、点词弹窗；截图留证。

### P2 超分（fork C++ + Dart）

改动：
- `packages/flutter_inappwebview_windows/windows/custom_platform_view/`：
  - `frame_tap.{h,cc}`（新）：per-webview 帧 tap；`ProcessFrame` 在 tap 开启时额外
    `CopyResource` 到 3 槽 staging ring，Map 后推入有界队列（深度 1，新帧覆盖旧帧——只要最新）；
    关闭时零开销；中心 16 点采样全零连续 N 帧 → `protectedContent` 事件。
  - `mpv_stream_source.{h,cc}`（新）：`GetProcAddress(GetModuleHandle("libmpv-2.dll"), "mpv_stream_cb_add_ro")`
    注册 `fushiwv://<webviewId>`；`read` 阻塞等新帧、整帧 BGRA 顺序吐出；`close` 解绑；尺寸变化
    → 关流让 mpv EOF，Dart 重开。libmpv 不在进程内（非 Windows 视频构建）→ 注册失败返回错误。
  - 方法通道：`setFrameTap(enabled, width, height)`、`getFrameTapState()`。
- Dart：`web_video_fushi_page.dart` 内 media_kit `Player` + `VideoController`（不用
  `VideoPlayerController.load()`，它的字幕/轨/断点逻辑对这里全是噪音；只用纯函数
  `applyShadersToPlayer` / `applyMpvConfigToPlayer`），`Media('fushiwv://<id>')` + 属性
  `demuxer=rawvideo` / `demuxer-rawvideo-w,h,mp-format=bgra` / `untimed=yes` / `demuxer-thread=no`
  / `cache=no` / `audio=no`。着色器档位切换沿用视频页同一份设置（`VideoShaderTier`）。
- 黑帧 → 关叠层 + 提示（i18n 走 `i18n_sync --add`）。

测试：
- C++ gtest（fork 已有 `TEST_RUNNER`）：帧队列覆盖语义、read 分片正确性、尺寸变化 EOF、黑帧判定。
- Dart：mpv 属性集纯函数、尺寸变化重开状态机。
- 真机：Anime4K 开/关截图对比（同一帧）；A/V 延迟台账（JS `currentTime` 帧号打进画面 vs mpv
  输出帧截图读数）；CPU/GPU 占用；1080p→4K 极高档不掉帧。延迟 > 100 ms 即触发方案 A 评估。

### P3 制卡

- 句音频：`audio_loopback_capture.cpp` 已有 WASAPI loopback；按 cue [start,end] 窗口录 → 现有
  `immersion_capture` 通道（与扩展 `mineClip` 同一服务端 `buildImmersionRequest`）。
- 截图：P2 tap 帧或 `takeScreenshot`。
- 细节待 P1/P2 落地后另开计划。

## 4. 风险

| 风险 | 处置 |
|---|---|
| WebView2 对 PlayReady 支持不明（Widevine 内置） | P1 真机实测 Netflix；黑帧/拒播即记录，不宣称 |
| 方案 B 延迟 1~2 帧 | P2 实测台账；超 100 ms 走方案 A |
| 站点 bridge 与扩展分叉 | 镜像守卫测试，改只改扩展源 |
| rawvideo 尺寸变化闪一下 | 防抖 300 ms 重开；可接受 |
| fork 未构建 / 非 Windows | 所有原生入口 fail-open，页面退化为纯 WebView 无超分 |

## 5. 验证清单

- `dart format` 改动文件 + 全量 `flutter analyze`（含 test）。
- 定向 `flutter test`：新测试 + `test/tools/` 守卫 + 视频 launch 相关。
- 合并前全量 `dart run tool/flutter_test_failures.dart --no-pub` 只认 VERDICT 行。
- fork 改动：`flutter build windows`（Git Bash 需前置独立 CMake，代理 + `NO_PROXY=localhost`）看 `Built` 行。
- 真机证据落 `.codex-test/web-video-player/`。
