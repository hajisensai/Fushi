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
- **画质 / 增强双模式**（§5.1 配方）：增强模式用独立 `WebViewEnvironment`（`additionalBrowserArguments:
  --disable-direct-composition`、独立 user data folder）+ Chrome UA + document-created EME 垫片；画质模式用
  默认环境。模式是网页播放器页级设置，切换 = 重建 WebView。P2 第一步先在 fork 里验 `--disable-direct-composition`
  下 visual 捕获仍出帧。

测试：
- C++ gtest（fork 已有 `TEST_RUNNER`）：帧队列覆盖语义、read 分片正确性、尺寸变化 EOF、黑帧判定。
- Dart：mpv 属性集纯函数、尺寸变化重开状态机。
- 真机：Anime4K 开/关截图对比（同一帧）；A/V 延迟台账（JS `currentTime` 帧号打进画面 vs mpv
  输出帧截图读数）；CPU/GPU 占用；1080p→4K 极高档不掉帧。延迟 > 100 ms 即触发方案 A 评估。

#### P2 修订（2026-08-29 晚，沿 fork 代码核实后）

「帧 tap → `mpv_stream_cb` rawvideo」的硬事实：
- fork 的 `ProcessFrame` 不在 WGC 线程，而在 **Flutter raster 线程**按需拉（`texture_bridge_gpu.cc:79-98`
  `GetSurfaceDescriptor` → `ProcessFrame`），持 `TextureBridge::mutex_`；帧池 `kNumBuffers=1`
  （`texture_bridge.cc:21`），`last_frame_` 复用同一块显存 → 任何拷贝必须在锁内完成。
- staging `Map(D3D11_MAP_READ)` 是同步回读：1080p60 ≈ 500 MB/s PCIe + 500 MB/s memcpy，且 mpv demux
  线程的消费速度会经环形缓冲**反压 raster 线程** → 整个 Flutter UI 掉帧。全链路两次 PCIe 往返 +
  三次全帧 memcpy（R6）。
- `Player.open` 走 `loadlist`，自定义协议非 safe 会被 mpv 拒（`real.dart:194-210`）；`setProperty`
  静默吞错（`real.dart:1239`）；`demuxer-rawvideo-w/h` 加载期固定，捕获尺寸却随布局/DPI 任意变。
- `mpv_stream_cb_add_ro` 不在 media_kit 的 Dart bindings 里，只能 C++ 注册（`libmpv-2.dll` 已导出）；
  注册后不可注销、按 handle 幂等。

**结论**：rawvideo 喂入只配当 **≤720p/30fps 的可行性原型**，不是正式方案。正式方案回到「帧已经在 fork 的
D3D11 纹理里，就地跑着色器」：候选 (a) libplacebo D3D11 后端（原样吃 mpv `.glsl`，新依赖 + CI 自建
artifact，仿 `ffmpeg-min.yml`）；(b) fork 内 ANGLE（Flutter Windows 已随包 libEGL/libGLESv2）自写
mpv-hook 指令（HOOK/BIND/SAVE/WIDTH/HEIGHT/WHEN）运行器，GLSL 体原生编译、零新依赖，`COMPUTE` 类
不支持即跳过。两者对 Dart 侧接口相同。P2 第一步仍是验证 `--disable-direct-composition` 下
`CreateGraphicsCaptureItemFromVisual` 出帧；第二步在 (a)/(b) 间按「用户粘贴任意 .glsl 要不要保证」定案。
超分只对可捕获内容（非硬件 DRM 站 / 增强环境）生效，观看网飞（正常模式）不受影响。

### P3 制卡

事实（沿代码核实）：
- 落卡唯一出口 `ImmersionMiningEngine.mine`（`immersion_mining_engine.dart:228`）已支持
  `providedCoverBytes` / `providedAudioBytes`（扩展 `mineClip` 路径就是这么进来的），网页播放器直接喂
  字节，不走 `app.fushi.reader/immersion_capture`（该通道在 `fushi/windows/` **没有 native 实现**）。
- WASAPI loopback（`audio_loopback_capture.cpp`）是**整机默认渲染端点混音**，只有 `grabRecent(backMs)`
  往回取（环 60 s），没有按窗起停；Dart 封装 `LoopbackGalAudioSource`，PCM → `slicePcmByMs` →
  `pcmSliceToAacBytes`（`galgame_audio_encode.dart`）。
- 逐句时序照抄扩展 `fushiRunNetflixBatch`（`content.js:524`）：seek(cueStart−200) → pause → 等落定/缓冲/真前进
  → play + 计时 → 「字幕变句 + 0.35 s」或 hardEnd 12 s → pause → `grabRecent(elapsed+preRoll)` +
  `takeScreenshot`（增强环境下非黑）。
- 增强环境：`WindowsWebViewEnvironment.create(userDataFolder, additionalBrowserArguments:
  '--disable-direct-composition')` + `HeadlessInAppWebView(webViewEnvironment:)`，登录态用
  `CookieManager.instance(webViewEnvironment: watchEnv).getCookies` → 增强 env `setCookie` 同步。
- app 内没有持久化制卡队列（扩展的 `chrome.storage.local.fushiQueue` 是唯一先例）：新建
  Drift 表 `web_mine_queue`，条目形状复刻 `content.js:437`（fields / sentence / cueStart−200 /
  cueEnd+200 / mineAt / videoKey / pageUrl / documentTitle），去重键复刻 `fushiQueueKey`。

- 句音频：`audio_loopback_capture.cpp` 已有 WASAPI loopback；按 cue [start,end] 窗口录 → 现有
  `immersion_capture` 通道（与扩展 `mineClip` 同一服务端 `buildImmersionRequest`）。
- 截图：P2 tap 帧或 `takeScreenshot`。

#### P3 落地（2026-08-30）

比上面的事实清单再砍一刀：**不开第二个（headless）WebView 实例**。重放就在本页（可捕获的 1080p 内置档）
跑——同一个 WebView2、同一份登录态、同一条 JS 桥，省掉 cookie 同步和第二个环境。「观看用正常模式、制卡用
1080p 稳定模式」由**入队/重放分离**实现，而不是双实例并存：

- `web_mine_queue`（schema **v89**，`packages/fushi_core` tables.dart；设备本地，进 backup 的 device-local
  三处清单）：`bookUid / videoKey / href / cueStartMs / cueEndMs / sentence / cueSentence / fieldsJson /
  status(pending|done|failed) / error / noteId / createdAt / minedAt`。`fieldsJson` 冻结弹窗点击那一刻的 Anki
  字段（词典释义等），重放只补媒体。Dart 侧 `WebMineQueueStore`（`fushi/lib/src/mining/web_mine_queue_store.dart`）。
- 入队：`WebVideoFushiPage.onMineEntry` 覆写 `DictionaryPageMixin` 的制卡入口——有锚点 cue 就入队 + toast
  「已加入制卡队列（待制 N 张）」，回 `const MinePopupResult()`（弹窗不画 ✓，卡还没落地）；无 cue 退回
  mixin 的纯字段制卡，行为与改动前一致。
- 重放：`WebMineReplayRunner`（`web_mine_replay.dart`，纯编排、假时钟可测）每句 seek(cueStart−300) → 等落位 →
  play → 等观测到开播 t0 → cue 中点 `takeScreenshot` → 播过 cueEnd+250 → pause → `grabRecent(now−t0+150)`
  → `pcmSliceToAacBytes`。时间窗**按墙钟**取而不是猜播放器时钟。宿主接口 `WebMineReplayHost` 由页面用
  现有 `_seekMs/_play/_pause/_state` 实现。
- 落卡：`ImmersionMiningEngine.mine(ImmersionMiningRequest(providedCoverBytes: png, providedAudioBytes: m4a,
  requireAudio: false, source: video, …))`；成功 `markDone(noteId, warning)`、失败 `markFailed(error)`。
  引擎 `providedCoverBytes` 路径会按用户静图格式偏好转码一次（只换编码不改尺寸）。
- UI：AppBar 「制卡队列」图标带 Badge 计数 → 点击跑队列；运行中标题变「制卡中 i/N」、图标变停止；跑完 toast
  「成功 X 失败 Y」并 seek 回原位置。运行期不登记观看进度/时长（`_mineRunning` 门）。
- 交接：`WebVideoFushiPage(autoRunMineQueue: true)`——4K 窗口宿主档的「切到内置档制卡」按钮以此打开本页，
  画面一就绪自动跑队列。
- 换集行（`row.videoKey != 当前`）：先 `loadUrl(row.href)` 等该视频就绪再重放；30 s 不就绪标 `navigate_timeout`。
- 不做：多语言整轨自动切轨（用户切轨才触发新下载，见 BUG-1949）、后台第二实例、队列跨书全局页（队列按书，
  入口在该书的播放页）。

## 4. 风险

| 风险 | 处置 |
|---|---|
| WebView2 对 PlayReady 支持 | **已实测（2026-08-29，本机 Evergreen 151.0.4129.107，见 §5）**：硬件级 SL3000 许可可得、真账号 Netflix 播到 2560×1440（UHD 阶梯）、0 掉帧；受保护帧截屏纯黑、页面字幕层可见 |
| 网飞帧能否捕获（超分/截图/录制前提） | **已实测（§5.1）**：Chrome UA + 拒 PlayReady + `--disable-direct-composition` → Widevine 软件档 1080p、帧可截。双模式落地受 environment 级参数约束，fork 的 visual 捕获在该参数下须真机验 |
| 方案 B 延迟 1~2 帧 | P2 实测台账；超 100 ms 走方案 A |
| 站点 bridge 与扩展分叉 | 镜像守卫测试，改只改扩展源 |
| rawvideo 尺寸变化闪一下 | 防抖 300 ms 重开；可接受 |
| fork 未构建 / 非 Windows | 所有原生入口 fail-open，页面退化为纯 WebView 无超分 |

## 5. 已实测事实（2026-08-29，Windows 11 24H2，Evergreen WebView2 151.0.4129.107，宿主 pywebview）

证据：`.codex-test/web-video-player/`（不入库）。探针脚本在 job tmp，不入库。

- EME 能力：`com.microsoft.playready.recommendation` robustness 3000 / 2000 / 150、`playready.hardware`
  全部 OK；`decodingInfo` HEVC 2160p + PR3000 = supported+powerEfficient；Widevine 只到
  `SW_SECURE_CRYPTO`（L3）。UA 带 `Edg/151.0.0.0`。
- 手写 EME 许可链（微软测试片 + 测试许可服务器 `cfg=(sl:3000)`）：video 3000 + audio 2000 →
  `createMediaKeys`/`generateRequest`/许可 200/`update` → keyStatus **`usable`**。**音频 robustness 不能
  设 3000**（`NotSupportedError`），与 Netflix 在 Edge 上的 3000/2000 组合一致。
- video 2000（软件 CDM）在本机 `generateRequest` 挂死，**真 Edge 同样挂死** → 非 WebView2 问题
  （疑似软件 CDM 首次个性化走网络被本机 fake-ip DNS 卡住），与 Netflix 硬件路径无关。
- shaka 4.11 要用 `drm.keySystemsMapping: {'com.microsoft.playready': 'com.microsoft.playready.recommendation'}`
  才会走 recommendation；否则选旧 keysystem 且 CDM 不发许可请求。
- 微软 4K H.264 测试片在 SL3000 下 `MediaFoundationRenderer 0x8004B821`（许可已拿到、解码失败），
  但 **真账号 Netflix 在同一 WebView2 里正常播**：`/watch/81236554` `videoWidth×Height=2560×1440`、
  21 s 内 522 帧解码 / 0 掉帧 → 测试片失败是内容/编码特例，不是 WebView2 硬件 DRM 不可用。
- 截屏（GDI，t=12 s / 25 s）：视频区域 mean=0、stddev=0（**受保护输出，帧不可得**）；页面渲染的
  字幕文本「六万年前」清晰可见 → 字幕/查词/制卡链路不受 DRM 影响。

### 5.1 「画质 / 增强」双模式实测（同日，同一 WebView2，网飞真账号）

黑帧的真正变量**不是 DRM 等级，而是 Chromium 的 DirectComposition overlay**：GPU 合成开着时，
受保护视频（哪怕 Widevine 软件档）被放进受保护 overlay，任何截屏都黑；用户 Chrome 关硬件加速能截网飞
就是这个原因（其 Chrome 实测走 Widevine 1080p）。逐步排除的台账：

| 配置 | 网飞选的 keySystem（`createMediaKeys` 原型钩子实测） | 分辨率 | 帧可截？ |
|---|---|---|---|
| 默认（UA 带 `Edg/`） | `playready.recommendation.3000` | 2560×1440 / 1920×1080 | ❌ 纯黑 |
| 运行期垫片拒 PlayReady（实例/原型补丁） | 拦不到——网飞在页面加载时已抓走原始函数引用 | — | — |
| document-created 垫片拒 PlayReady，UA 仍 `Edg/` | 依次试 `.3000`→`.2000` 被拒后**不试 Widevine**，无 `<video>` | — | — |
| document-created 垫片 + **Chrome UA**（去 `Edg/`） | `com.widevine.alpha` `SW_SECURE_DECODE` | 1920×1080 | ❌ 仍黑（overlay） |
| 上一行 + `--disable-gpu` | 同上 | 1920×1080 → 掉到 960×540（纯软件渲染扛不住） | ✅ |
| 上一行 + **`--disable-direct-composition`** | 同上 | **1920×1080 稳定**，0 掉帧 | ✅ **清晰可截** |

**用户决定（2026-08-29）**：观看一律走正常模式（PlayReady 全画质，不捕获）；1080p 稳定（增强）模式**只在自动制卡时用**，
由制卡流程在独立环境里跑，不影响观看；网页播放器的观看体验对齐现有视频页。三个阶段全部做。

**增强模式配方（已验证）**：Chrome UA（`CoreWebView2.Settings.UserAgent` 去掉 `Edg/` 标记）+
document-created 注入的 EME 垫片（拒 `com.microsoft.playready*`、Widevine `HW_SECURE_*` 降
`SW_SECURE_CRYPTO`）+ 浏览器参数 `--disable-direct-composition`（`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`
或 environment 的 `additionalBrowserArguments`）→ 网飞 1080p Widevine 软件档、帧可捕获 → 超分 / 截图 /
录制全通。**画质模式** = 默认环境（PlayReady 硬件档 1440p/4K，不可捕获）。

### 5.2 app 内真机（`integration_test/web_video_netflix_live_itest.dart`，runner `-Visible -KeepUserDirs`）

- **硬件 PlayReady 在 fork 的 composition hosting 下不可用**：默认档（UA 带 `Edg/`，Netflix 选
  `playready.recommendation.3000`）页面报 `D7703-1003-80070003`（CDP 截图证据
  `.codex-test/windows-itest/web-video-netflix-live/screenshots/observe-web-video-webview.png` 上一版）。
  同一份登录 profile、同一台机、同一环境变量，pywebview（窗口宿主）播到 2560×1440——差别只剩
  `CreateCoreWebView2CompositionController` + 自建 visual 离屏 WGC 捕获（WebView2 #4935 同类：hardware
  keysystem 黑屏，`playready.software` 正常）。runner 重定向 LOCALAPPDATA/USERPROFILE/TEMP 也会独立触发同错
  （见 `-KeepUserDirs`），两者叠加时先排环境再看宿主。
- **软件 DRM 档（Chrome UA + document-start EME 垫片 → Widevine `SW_SECURE_DECODE`）在 app 内全链路通过**：
  起播（位置持续前进、0 掉帧）、DOM 采样 live 轨进字幕列表面板、画面字幕叠层渲染当前句、bridge seek
  精确落点（780504→810505，目标 810504）、Flutter 帧证据 `observe-web-video-subtitle-list.png`。
- **CDP `Page.captureScreenshot` 在默认环境（不加 `--disable-direct-composition`）下就能拿到清晰帧**
  （3.1 MB PNG，草原蝗虫画面）——它走 compositor 回读，不受 DComp overlay 影响。P3 取帧走 `takeScreenshot`
  即可，`--disable-direct-composition` 只在需要 WGC 纹理（超分）时才必要。
- 整集明文字幕轨（netflix-bridge `timedtexttracks`）在 app 内未到，只有 live 轨 → 根因是站点侧
  `JSON.parse` 零命中，扩展同样受影响，另立 **BUG-1949**（不阻塞 P1，live 轨可用）。
- **用户在 app 里看到什么（WGC 抓 app 窗口，两次 itest 各一张）**：默认环境 → 网飞控件在、
  **视频区纯黑**（`wgc_capturable_0/wgc_17_089s.png`）；独立环境 `--disable-direct-composition` →
  **画面清晰**（`wgc_capturable_1/wgc_15_080s.png`，蝗虫特写 + `RATED 7+` + 右侧字幕列表）。
- **P1 最终默认**：网页播放器页 = 软件 DRM 档（Chrome UA + EME 垫片）+ 独立可捕获环境
  （`%LOCALAPPDATA%\Fushi\WebVideoWebView2`，`--disable-direct-composition`）。这不是降级而是 fork 捕获式
  显示链路下**唯一可播的档**；Netflix 1080p（= 用户 Chrome 关硬件加速），帧可捕获 → P2 超分 / P3 制卡
  在同一环境直接可做，不再需要「观看 / 制卡」双环境。
- 结论修正：「观看=PlayReady 全画质」在 fork 现有 composition hosting 下**做不到**（硬件 DRM 报 D7703）。
  要 1440p/4K 必须给 fork 加**窗口宿主**（HWND child，`CreateCoreWebView2Controller`）模式给视频页专用，
  且该模式下画面不经捕获、超分/取帧不可用——工作量单独评估，由用户拍板。

### 5.3 用户决定（2026-08-30）

- **画质双模式给用户选**：「1080p 内置」= 现 P1（捕获式，超分/取帧可用）；「4K」= fork 新增 **HWND 窗口宿主**模式
  （`CreateCoreWebView2Controller`，硬件 PlayReady 可用，画面不经捕获）。4K 模式下 Flutter 画不到子 HWND 之上，故
  (a) 画面字幕改为**注入页面 DOM**（自己的字幕 div 盖住站点原生字幕，逐词点击 / hover → `callHandler` 回 Dart 查词，
  即浏览器扩展的做法）；(b) 查词弹窗用**独立顶层窗口**（`global_lookup_window.cpp` 那套，gal 查词浮窗同款，可盖在子
  HWND 之上）。
- **BUG-1949 要修**（先查其它分支是否已修）。
- **P2 着色器运行时选 (a) libplacebo**（原样吃 mpv `.glsl`；新依赖 + CI 自建 artifact，仿 `ffmpeg-min.yml`）。
- 全部做完。执行顺序：BUG-1949 → P3 制卡 → 4K 窗口宿主 → P2 libplacebo。

P2 落地时的两条硬约束：
- `--disable-direct-composition` 是 **WebView2 environment 级**（每个 user data folder 一个浏览器进程）
  参数，不能运行期切换 → 双模式 = 两个 `WebViewEnvironment`（两套 profile 目录，cookie 不共享，登录要各登一次，
  或用 `CookieManager` 同步）。fork 的 `WebViewEnvironmentSettings.additionalBrowserArguments` 已有入口。
- fork 的纹理链路是 `CreateGraphicsCaptureItemFromVisual`（composition hosting）；`--disable-direct-composition`
  只关 Chromium 内部的 DComp 用法，对 host 提供的 visual 树是否有副作用**必须在 fork 里真机验**——这是 P2
  第一件事，验不过就退回 `--disable-gpu-compositing` 一类更粗的开关逐个试。

## 6. 验证清单

- `dart format` 改动文件 + 全量 `flutter analyze`（含 test）。
- 定向 `flutter test`：新测试 + `test/tools/` 守卫 + 视频 launch 相关。
- 合并前全量 `dart run tool/flutter_test_failures.dart --no-pub` 只认 VERDICT 行。
- fork 改动：`flutter build windows`（Git Bash 需前置独立 CMake，代理 + `NO_PROXY=localhost`）看 `Built` 行。
- 真机证据落 `.codex-test/web-video-player/`。
