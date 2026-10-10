## BUG-3233 · HDR合成器一次失败就整个进程记成不支持
- **报告**：2026-10-10（集成审查 #1986 时发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_player_controller.dart` `_enterOrUpdateHdrCompositor`：引擎 / 纹理任一步没切成就写进程级静态缓存 `_compositorHdrSupported = false`。纹理晚一帧建好（`_videoController?.notifier.value == null`）或某一路输出暂时找不到 handle 这类偶发失败，也会让之后整个进程都不再尝试合成器 HDR，一律走宿主窗直到重启。
- **[x] ① 已修复** — 失败按层级分流（`compositorHdrFallback`，`video_hdr_output.dart`）：引擎没开成 → 进程级「不支持」（引擎能力进程内不变）；纹理未就绪 → 本轮走宿主窗，挂一次性监听等纹理到位后重判；纹理拒绝 → 只对当前 Player 退回宿主窗（`_compositorTextureRefusedFor`），换片新 Player 重试。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_hdr_output_test.dart`「compositorHdrFallback（合成器 HDR 失败的记忆范围）」：三种分流 + 控制器只在 engineUnsupported 分支写进程级缓存。
- **备注**：真机 HDR 呈现仍未在 3.47.6 补丁引擎上验证。
