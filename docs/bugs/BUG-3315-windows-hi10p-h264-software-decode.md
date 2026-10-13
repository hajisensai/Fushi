## BUG-3315 · Windows 播放 H.264 High 10 走 CPU 软解掉帧；诊断默认不采 mpv 掉帧统计
- **报告**：2026-10-13（用户：「我放视频的时候有时候会掉帧」；要求根治、不降画质、10-bit H.264 改成能硬解）
- **真实性**：✅ 真 bug，三处根因：
  1. `fushi/lib/src/media/video/video_mpv_config.dart` `kWindowsAutoHwdec` / `kWindowsCopyHwdec` 只给 D3D11 候选，而 D3D11VA 没有 H.264 High 10 解码配置 → Hi10P 片源（番剧压制常见）必然回落 CPU 软解；
  2. `fushi/lib/src/media/video/video_player_controller.dart` `_maybeSampleBlackFlicker` 按 `mpv/stats` 的 **v** 级判是否采样，而默认过滤串 `all=v,mpv=info` 的 `mpv=info` 前缀把 `mpv/stats` 压到 info → 默认配置下一行 mpv 掉帧统计都不采（`fushi/lib/src/diagnostics/video_diag_log.dart` `defaultMsgLevel`）；
  3. media_kit 1.2.6 `observeProperty` 写死 `MPV_FORMAT_NONE`（`real.dart` `mpv_observe_property(..., MPV_FORMAT_NONE)`），mpv 对无格式订阅恒报变化，`MPV_EVENT_TICK` 属性每帧一次事件且每次同步 `mpv_get_property_string`（拿核心锁）——本地未推送的图形字幕计时观测（`d4122cb1f7` 的 `video_graphic_subtitle_timing.part.dart` `_ensureGraphicLiveObserver`）因此选过图形字幕后整场每帧两次锁 mpv 核心。
- **[x] ① 已修复** — `13abdc370a`：Windows 候选表末尾追加 `nvdec-copy`（排在全部 D3D11 之后，D3D11 能解的格式不加载 nvcuda64，零拷贝 CUDA 永不下发）；默认过滤串补 `mpv/stats=v`、采样门按 warn 判。media_kit 补丁层新增 `NativePlayer.observePropertyChanges`（`MPV_FORMAT_STRING`，mpv 核心比值、值随事件到达），见 `ci/patches/hosted/media_kit-1.2.6/PATCHES.md`；图形字幕观测切换到它在基于 `d4122cb1f7` 的分支上完成。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_hwdec_controller_config_guard_test.dart`（零拷贝 CUDA 不下发 / CUDA 只以 copy 变体排在 D3D11 之后 / 两档以 nvdec-copy 兜底，变异两轮转红）、`fushi/test/diagnostics/video_diag_log_test.dart` + `video_diag_wiring_guard_test.dart`（默认过滤串放行 mpv/stats v / 采样门按 warn，变异转红）、`fushi/test/third_party/media_kit_observe_changes_test.dart`（真 libmpv 对照：FORMAT_NONE 每帧回调 vs 比值订阅 ≤2 次）、`fushi/integration_test/video_hwdec_hi10p_itest.dart`（真实 app 进程起播 Hi10P：hwdec=nvdec-copy、播放推进、零掉帧）。
- **备注**：
  - 实测证据（本机 RTX 5090 / 驱动 596.49，随包 libmpv）：用户日志 `video_mpv_log.txt` 显示 `h264-d3d11va` / `h264-d3d11va-copy` 均失败 → `Using software decoding`，`Codec profile: High 10`；ctypes 直驱同一 DLL：`nvdec-copy` / `cuda-copy` 成功（输出 p010），`vulkan(-copy)` / `d3d11va-copy` 失败；`d3d11va,d3d11va-copy,nvdec-copy` 列表在 BUG-1639 的 HEVC Main 10 片源上仍选 `d3d11va-copy`；14 实例并发 nvdec-copy ×5 轮无崩溃。
  - 与 BUG-1639 的关系：那条排除 CUDA 是因为裸 `auto-safe` 在 d3d11va 之后直接走零拷贝 `nvdec`、并在 app 进程内 `cuCtxCreate` 崩溃（根因未完全追清）。本条只在 D3D11 拒绝的 profile 上以 copy 变体进入 CUDA，且以真实 app 进程集成测试验证。
  - 掉帧的其它嫌疑（ASS 动画字幕整层每帧重建、起播头一分钟 ffmpeg 与 mpv 抢盘、控制栏模糊）需要修好的诊断采样采到证据后再定，不在本条臆测修改。
