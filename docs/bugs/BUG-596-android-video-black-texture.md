## BUG-596 · 安卓视频解码正常但纹理合成黑屏
- **报告**：2026-07-07（用户：RMX3085 / Realme 8 / Android 11 / Mali-G76 / app 1.0.1-debug.6897，TODO-1232）
- **真实性**：✅ 真 bug（Android 纹理**握手已成功**却仍黑屏）。根因在 Flutter Impeller 合成层，非解码/纹理握手层。证据链见下。
- **[x] ① 根因定位 + 关 Impeller 复测闭环仪表化（根治手段=关 Impeller，已有 A3 开关；默认翻转待真机确认）** — 提交 <PENDING>
- **[x] ② 自动化测试（源码扫描守卫 + 单测）** — `hibiki/test/utils/misc/render_backend_service_test.dart`（本次运行后端快照 / activeBackendLabel）+ `hibiki/test/media/video/video_diag_logging_guard_test.dart`（activeRenderBackend 必挂在抗环形缓冲淘汰的存活行）
- **备注**：本 bug 是 BUG-535 的**下一环**。BUG-535（`EnableSurfaceControl=false`）修好了「纹理握手从未完成（wid=0 / vo=null / texture id 停 null）」；本机的新日志显示握手**已成功**（texture id=0 非空、wid=12866、vo=gpu、GL 出帧）却仍黑——正是 BUG-535:25/79 预言的分支「握手成功仍黑 → 试 `EnableImpeller=false`」。无安卓 realme 真机，「关 Impeller 是否解决」需用户真机复测（用现有设置开关，见下），故本次不擅自把全局默认翻成 Skia（A3 明确「非默认全局关」）。

### 现象（用户诊断日志 `[VIDEO-DIAG]`，device=RMX3085_11_A.24）
解码 + GL 渲染**全绿**：`first frame decoded: 1920x1080` / `videoParams w=1920 h=1080 pixelformat=yuv420p10`（10bit HEVC 软解）/ `controller.load() returned ok ... videoController=true`。纹理握手**成功**：
- `[VIDEO-DIAG] texture id changed: 0`（**id=0 是非空**——握手成功，见 BUG-535:79 判据）
- `render state after first-frame: textureId=0 rect=1920x1080`
- `Set property: wid="12866"`（非 0 的 Surface global ref）、`vo=gpu` / `current-vo=gpu` / `gpu-context=android`
- `Initializing GPU context 'android'` → EGL/GLES 3.2 (Mali-G76) → `Using FBO format rgba16f` → `Texture for plane 0: 1920x1080 / plane 1,2: 960x540` → `first video frame after restart shown` → `playback restart complete @ 0.167 audio=playing video=playing`

即：libmpv 已把画面渲进 SurfaceProducer 的 Surface，Flutter 侧纹理 id 也有效——**唯独屏幕黑**。

### 根因（file:line 证据链）
纹理握手已完成，黑屏在**握手下游的 Flutter 合成层**：

1. media_kit_video 2.0.1（vendored）Android 走 `TextureRegistry.SurfaceProducer` 唯一路径（无 1.2.x 的 `SurfaceTextureEntry` 回退）：
   `third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video/VideoOutput.java:55,97-99`
   —— `surfaceProducer = createSurfaceProducer()`；`onSurfaceAvailable()` 里 `id = surfaceProducer.id()`、`wid = newGlobalObjectRef(surfaceProducer.getSurface())`。
2. `id = surfaceProducer.id()` 返回 **0** 是 Flutter TextureRegistry 的**首个合法纹理 id**（不是失败哨兵）；`wid=12866` 是合法 Surface global ref。二者经 `VideoOutput.Resize` 回传：
   `third_party/media_kit_video/lib/src/video_controller/android_video_controller/real.dart:268-272`（`id.value=id`、`wid.value=wid`）。
3. `wid != 0` → widListener 设 `vo=gpu`（real.dart:56），libmpv GL 出帧。→ **native/mpv/GL 侧到此已 100% 完成，无进一步可修。**
4. 剩下唯一能让 `Texture(textureId: 0)` 显黑的是 **Flutter 合成器**：Impeller 在该 Android 11 / Mali-G76 ROM 上不合成 media_kit 的 SurfaceProducer 外部纹理（对应 flutter/flutter 上 Impeller + SurfaceProducer 外部纹理在部分设备黑屏的一批 issue）。这正是 `hibiki/lib/src/utils/misc/render_backend_service.dart:7-11` 早已记的疑点，也是 BUG-535:25 预留的下一手 `EnableImpeller=false`。

**排除项**：非 hwdec/10bit（软解已出帧）、非握手失败（BUG-535 已修，本机 id/wid/vo 全非空）、非 `EnableSurfaceControl`（manifest 已 false 且握手已成功）。

### 根治手段与本次改动
- **根治手段（已存在）**：关 Impeller 走 Skia。A3 已实现完整链路——设置页开关 `diagnostics.disable_impeller`（`settings_schema_system.dart:208`）→ `RenderBackendService.setImpellerDisabled` 持久化 native pref → `MainActivity.getFlutterShellArgs`（`MainActivity.java:420-426`）下次启动追加 `--enable-impeller=false`。用户开开关 + 重启即切 Skia。
- **本次改动（闭环仪表化，让真机复测可判定）**：用户导出的这份日志里，带 `impellerDisabledPref` 的 `_applyLoad` 头部行被 libmpv verbose 洪水挤出了 `ErrorLogService` 环形缓冲（导出只剩 controller 层行），**无法自证测的是哪个后端**。修法：
  1. `render_backend_service.dart`：新增 `activeImpellerDisabled` / `activeBackendLabel`——`init()` 首次快照「本次运行实际生效后端」（≠ 可被用户翻的 `impellerDisabled` 下次意图），杜绝「已翻开关但未重启」被误报成 Skia。
  2. `video_hibiki_page.dart`：把 `activeRenderBackend=<skia|impeller|n/a>` 同时记在 `_applyLoad` 头**和** `controller.load() returned ok` 行（后者更晚、能存活于导出）。之后用户开关 Impeller + 重启 + 复测导出，日志即无歧义显示 `activeRenderBackend=skia` 与画面是否恢复。
- **为何不擅自默认全局关 Impeller**：A3 明确「全局默认仍是 Impeller，本开关只在用户主动打开时翻转，属产品安全的试验路径（非默认全局关）」；且本端无 realme 真机无法确认 Skia 确实解决。全局翻 Skia 会改动**所有** Android 用户的渲染后端，属高影响面且未经真机确认的改动——按仓库纪律不做未验证的全局默认翻转，把「确认 Skia 解决 → 是否默认翻转」交真机后决策。

### 下次真机复测判据（用户侧）
1. 装本 build，设置 → 诊断 → 打开「关闭 Impeller（改用 Skia 渲染）」→ **重启 app** → 开同一 mkv。
2. 导出 `[VIDEO-DIAG]` 日志，确认 `activeRenderBackend=skia`：
   - 画面出 → 坐实 Impeller 合成层根因；据此决定是否把 Android 默认翻成 Skia（或保留开关为准）。
   - 仍黑（`activeRenderBackend=skia` 且黑）→ 排除 Impeller，根因更深（media_kit SurfaceProducer native 纹理路径 / 驱动），转降级纹理路径独立施工。
