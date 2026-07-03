## BUG-535 · Android 视频无画面(vo=null/texture not-created)
- **报告**：2026-07-03（用户：RMX3085 / Android 11 / app 1.0.1-debug.6411）
- **真实性**：✅ 真 bug（Android 纹理握手从未完成）。根因路径见下。
- **[x] ① 根因定位 + 定向诊断（未一步根治，见说明）** — 提交 <PENDING>
- **[x] ② 源码扫描守卫测试** — `hibiki/test/media/video/video_noframe_diag_guard_test.dart`
- **备注**：

### 现象（用户诊断日志）
解码链完全正常：`first frame decoded: 1920x1080` / `videoParams w=1920 h=1080
pixelformat=yuv420p10 colormatrix=bt.709`（10bit HEVC）/ `controller.load() returned ok
durationMs=1460010 videoController=true`。但视频输出/纹理从未建成：`mpv vo=null` /
`current-vo=`（空）/ `open() returned; textureId=null(not-created)` / `hwdec=no` /
`gpu-context=android` / `gpu-api=`（空）→ 黑屏/无画面。

### 根因（file:line 证据链）
media_kit_video 2.0.1（本仓 vendored 于 `third_party/media_kit_video`，Android 控制器
与 pub.dev 2.0.1 一致，只补了 seekbar UAF 与 controls 可见性，未动纹理路径）在 Android
走**纹理渲染**：`vo=gpu` 生效**严格前置**是拿到非 0 的 `wid`（ANativeWindow global ref）。

1. `third_party/media_kit_video/lib/src/video_controller/android_video_controller/real.dart:56`
   —— widListener：`voValue = widValue == '0' ? 'null' : 'gpu'`。即 `wid==0 → vo` 永久为
   `null`；`vo=gpu` 只在 `wid != 0` 时才设。
2. 同文件 :197 create() 里刻意先设 `vo=null`（`wid` 未到前设 gpu 会 SIGSEGV），并设
   `gpu-context=android`（与用户日志的 `gpu-context=android` 吻合）。
3. `wid`/`id` 唯一来源是 native 回调 `VideoOutput.Resize`（real.dart:258），它由
   `VideoOutput.onSurfaceAvailable()` 触发：
   `third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/VideoOutput.java:94`
   —— `wid = newGlobalObjectRef(surfaceProducer.getSurface())`。
4. media_kit_video 1.3.0 起把 Android 纹理从 `SurfaceTextureEntry` 迁到 Flutter 新的
   `TextureRegistry.SurfaceProducer`（VideoOutput.java:55）。该设备上 `onSurfaceAvailable`
   从未产出有效 surface：或 `getSurface()` 返 null、或 `setSurfaceSize()` 抛异常被
   `try/catch(Throwable){Log.e}` 静默吞掉（VideoOutput.java:87）、或 `newGlobalObjectRef`
   反射失败返 0（VideoOutput.java:119）。三者任一 → `wid=0` 永不上报 → widListener
   永远设 `vo=null` → `current-vo`/`gpu-api` 全空、texture id 停 null → 无画面。

**这不是 hwdec/10bit 解码问题**（日志 `hwdec=no` 软解、`first frame decoded` 已出帧、
`videoParams` 已就绪）；卡死在「Android surface/纹理握手从未完成」。全链路错误被吞：native
`catch(Throwable){Log.e}` 不抛；Dart `VideoController.create` 失败只
`platform.completeError`+`debugPrint`（video_controller.dart:131），`VideoController.id`
仍 null，UI 只看到 texture not-created，静默无画面。

### 为何是「定向诊断」而非「一步根治」
根因在 media_kit_video 2.0.1 的 `SurfaceProducer` native 实现内部（该迁移在部分
Android 11 ROM/GPU 驱动上易失效），无法在 Dart 层根治；用户已授权「查不出来就加日志」。
真正的候选修法（降级到 1.2.x `SurfaceTextureEntry` 纹理实现，或改 vendored native
surface 路径）需真机逐一验证，属后续独立施工。

**旧诊断的盲区**：只在 `open()` 后**一次性**回读 `vo`——但那一刻 `vo=null` 是 media_kit
的有意初始态（`wid` 未到），无法区分「vo=null 瞬态（正常）」与「vo=null 永久（真无画面）」。

### 本次定向诊断改动（`hibiki/lib/src/media/video/video_player_controller.dart`）
1. `_attachTextureIdDiag` / `_detachTextureIdDiag`：挂 `VideoController.id`（纹理握手
   **唯一** Dart 侧可观测输出）监听，记录 id 每次变化——id 变非空＝握手成功、此后
   `vo=gpu` 画面应出；始终 null＝握手从未完成（根因坐实）。
2. `_logRenderStateAfterFirstFrame`：等 `waitUntilFirstFrameRendered` / 6s 超时后**再**
   回读一次 texture id + vo/current-vo/gpu-api，区分 vo=null 瞬态 vs 永久；并显式记出
   被 media_kit 吞掉的 `VideoController.create` 异常（如 h264 解码器缺失的 UnsupportedError）。

### 下次真机需看的日志判据
- `[VIDEO-DIAG] texture id changed: <非空>` 出现 → 握手最终成功（问题在别处）；
- 全程只见 `texture id initial: null` + `render state after 6s-timeout: textureId=null(not-created) ... vo=null`
  → 坐实「SurfaceProducer 纹理握手从未完成」，规避方向＝降级/改 native surface 路径；
- 若出现 `render state after create-error: ... error=<...>` → 直接拿到 create 失败根因串。
- 同时看 logcat 有无 `VideoOutput: onSurfaceAvailable` / `newGlobalRef` / `setSurfaceSize` 的 `Log.e`。
