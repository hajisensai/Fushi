## BUG-2448 · 互联远端视频打不开：随包 libmpv 换 libcurl 后默认校验自签证书
- **报告**：2026-09-11（用户：fushi 互联打不开视频了，根本性修复一下，统一这里代码）
- **真实性**：✅ 真 bug。用 app 随包的 `libmpv-2.dll`（安装版 2.4.0-debug.14539，`mpv v0.41.0-923-g7b8915bc1`）
  直接 `loadfile` 本机生产 host 签发的 stream URL（`https://127.0.0.1:38765/api/library/videos/<id>/stream?token=…`）：
  ```
  [curl/error] error: SSL peer certificate or SSH remote key was not OK
  [curl/error] TLS certificate verification failed. ... a self-signed certificate ...
  [stream/error] Failed to open https://127.0.0.1:38765/api/library/videos/.../stream?token=...
  RESULT LOAD_FAILED
  ```
  同一条 URL 用 curl 走 Basic/token 直连 host 是 206 正常回流（host 侧没坏）；同一 DLL 加 `tls-verify=no` 即
  `FILE_LOADED duration=1420.928`。根因链：
  - `third_party/media_kit_libs_windows_video/windows/CMakeLists.txt:120`（BUG-1644，2026-08-14）把随包 libmpv 钉到
    `mpv-dev-x86_64-20260813-git-7b8915bc1d.7z`——这个 master 构建的 http(s) 取流后端从 ffmpeg lavf 换成了 **libcurl**，
    curl 默认校验证书；ffmpeg 的 tls 从不校验，所以之前自签 https 一直「碰巧能播」。
  - 互联 host 默认开 TLS（`applyFirstHostingTlsDefault`），证书自签、信任判据是配对时 TOFU 记下的指纹，只有 Dart 侧
    的 `createPinnedHttpClient`（`packages/fushi_engine/lib/sync/tls/fushi_pinning_http.dart:46`）知道；播放页却把
    https stream URL 原样塞给 native（`fushi/lib/src/media/video/video_player_controller.dart:1436` 的 `sourceUri` →
    `Media(sourceUri)`），让 libmpv 自己做 TLS。Android 随包 libmpv 仍是 ffmpeg 6.1.6 后端、不校验；Windows 校验——
    同一条流两端两种结局，说明 TLS 信任一开始就放错了层。
  - 2026-09-08 `000726dde9` 又给 libmpv 设了 `http-proxy` 指向 app 内置 loopback 中继（`app_native_proxy.dart`），
    但对 https 目标中继只做 CONNECT 隧道，TLS 仍是 native 端到端 → 经中继同样 `Failure when receiving data from the peer`。
    中继的既有测试 `app_native_proxy_mpv_test.dart` 只盖了公网明文 http，从没测过「自签 https + token 流」。
- **[x] ① 已修复** — `20b942a1eb`（主修）+ 同 PR #1418 的 code review 返工提交（登记撤销 / 客户端复用 / 连接超时）
  - TLS 信任收进中继一处：`app_native_proxy.dart` 新增钉扎原点登记 `registerPinnedNativeOrigin(host, port, 指纹)` +
    `nativePlaybackUri(url)`（已登记原点的 https 降成**带显式端口**的明文 http；其它 URL 原样）；`_forward` 按
    `(host, port)` 查到指纹就把 upstream 升回 https、用 `createPinnedHttpClient` 连——native 无论哪个后端都只看到
    loopback 明文，证书判据与 API/字幕/封面通道同一份。
  - `InterconnectSyncBackend._ensureResolved` 每次解析出 https host 就登记（幂等覆盖，重新配对换证书时指纹跟着刷新）；
    明文 http host 不登记。`downloadRemoteVideo` 等 Dart 侧通道仍拿真 https URL 自己钉扎，不受影响。
  - `VideoPlayerController.load` 的主流 `sourceUri` 与外挂音轨 `AudioTrack.uri(...)` 统一过 `nativePlaybackUri`——
    native 拿 URL 只此两个入口。本地文件 / 公网流 / YouTube / Jellyfin（`api_key` 鉴权、系统 CA）零变化。
  - 没选 `tls-verify=no`：那是把互联流对任意证书放行（ffmpeg 时代的「碰巧能播」），且各平台 libmpv 是否认这个选项
    又是一道新的分叉。
  - code review（PR #1418）返工三条：① 登记表原本只增不删——host 关 TLS 后同一端口改回明文重新配对，残留旧指纹会让中继把
    明文请求硬升 https 去握手明文端口（API/字幕都正常、只有视频 502 到重启）→ `_ensureResolved` 解析成 http 即
    `unregisterPinnedNativeOrigin`；② 钉扎客户端每请求新建、请求完即关 → libmpv 每个 Range/seek 都重新 TCP+TLS 握手
    → 改为按 `(host, port, 指纹)` 缓存复用（指纹换了关旧的，`close()` 一并关）；③ 钉扎客户端补 `kAppHttpConnectionTimeout`
    （对端休眠 / WAN 黑洞时不卡到 OS 默认超时）。
  - 有意不改：钉扎客户端不走 app 代理策略（与 `WebDavOps` 等 Dart 侧钉扎通道一致，API 能通视频就能通）；登记表是
    进程级 ambient 状态 + 控制器单一收口，而非把指纹随 `RemoteVideoStreamUrls` 携带——`downloadRemoteVideo` 等 Dart 侧
    消费者需要真 https URL，两种形态在产出端分叉反而多一处分歧点，收口处有源码守卫钉住。
- **[x] ② 已加自动化测试**
  - `fushi/test/utils/net/app_native_proxy_pinned_origin_test.dart`（新，11 条）— 真自签证书起 https 原点，以 native 的
    请求形状（absolute-form GET + Proxy-Authorization）过中继：指纹相符 200 透传 / Range 206 + Content-Range 透传 /
    指纹不符 502 / 未登记明文直连 502 / 撤销登记后 502 / 连续 3 个 Range 请求原点只见 1 条连接（复用）；
    `nativePlaybackUri` 四条真值（含隐含 443 必须显式端口、大小写、覆盖登记）。
  - `fushi/test/utils/net/app_native_proxy_mpv_test.dart` — 补「自签 https 原点经钉扎中继」真库用例（`FUSHI_TEST_MPV_DLL`
    指向随包 `libmpv-2.dll` 时跑，本机实跑 2/2 绿；无 DLL 跳过）。
  - `fushi/test/sync/fushi_client_live_video_test.dart` — https host 解析后已登记为钉扎原点、`remoteVideoStreamUrls`
    仍回真 https、`nativePlaybackUri` 降成同 host 显式端口 http；明文 http host 不登记；同一 host:port 解析成明文会
    撤销旧登记。
  - `fushi/test/media/video/video_player_native_playback_uri_guard_test.dart`（新）— 源码守卫：`load` 里主流与外挂音轨
    两个 native 入口必须过 `nativePlaybackUri`，带反向断言。
- **备注**：真机证据：修复路径在本机生产 host 上用随包 libmpv 实跑（登记 host 指纹 → `nativePlaybackUri` → 经真实
  `AppNativeProxy`），`Opening done: http://127.0.0.1:38765/.../stream?token=…`、`FILE_LOADED duration=1420.928`。
  手机端（Android，ffmpeg 后端 libmpv）本轮未真机复测：修复后它同样只经中继取明文 http，与 Windows 走同一条链。
  制卡回退的「client ffmpeg 直连抽取」（BUG-891 缺口）不在本轮：`miningSource` 仍是原 https URL，行为不变。
