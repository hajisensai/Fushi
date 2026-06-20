## BUG-346 · 视频片段导出 ffmpeg 执行失败：音轨映射越界硬失败 + stderr 被吞
- **报告**：2026-06-20（用户：报「视频片段导出 ffmpeg 执行失败」）
- **真实性**：✅ 真 bug。
  - **A 首要根因**：`buildFfmpegVideoClipExportArgs` 拼 `-map 0:a:$N` 无尾随 `?`
    （`hibiki/lib/src/media/video/video_clip_exporter.dart:60`，修前）。`N` =
    `controller.currentAudioStreamIndex`（`video_player_controller.dart:541`），它把 libmpv
    `tracks.audio` 的轨序号当 ffmpeg `0:a:N`；挂外挂音频或枚举顺序与 ffmpeg 容器流不一致时
    越界 → ffmpeg `Stream map matches no streams` 退出码非 0 → 导出失败。仅多音轨 + 切过非首轨
    才发作。同隐患在 `desktop_audio_clipper.dart:87`（修前，制卡句子音频裁剪）。
  - **C 横切根因**：失败时 ffmpeg stderr 被吞 —— `result.detail` 已装好 stderr
    （`video_clip_exporter.dart:117-120`），但 `_clipExportFailureReason`
    （`video_hibiki_page.dart:5899`）只返固定 i18n 文案从不读 detail，`_toggleClipExport` 全程
    无 `ErrorLogService.log`（对比 `desktop_audio_clipper.dart` 的 `_reportFfmpegFailure` 全记日志）
    → 真机黑盒，看不到真实失败原因。
- **[x] ① 已修复** —
  - **A（音轨映射加固）**：两处 `-map 0:a:$N` 改 `-map 0:a:$N?`，越界硬失败降级为回退默认轨；
    新增纯函数 `resolveAudioMapIndex`（`video_clip_exporter.dart`），在导出前对 `audioStreamIndex`
    做边界校验（`audioStreamCount` 由 `VideoPlayerController.realAudioStreamCount` 提供，
    `video_player_controller.dart`），越界则置 null 不加 `-map`（避免 `?` 静默导错音轨）。
    `desktop_audio_clipper.dart` 的 `buildFfmpegClipArgs` 复用同一 helper；两个 extract/export
    入口加 `audioStreamCount` 参数，`video_hibiki_page.dart` 两个调用点（制卡 3172 行附近 / 片段
    导出 5824 行附近）都把 `realAudioStreamCount` 传进去（导出在标记起点时快照
    `_clipExportStartAudioStreamCount`）。
  - **C（暴露 stderr）**：`exportVideoClipViaFfmpeg` 失败/异常分支调
    `ErrorLogService.instance.log('VideoClipExport', result.failureSummary)`（含退出码 + stderr），
    与 `desktop_audio_clipper` 对齐；`_toggleClipExport` 失败 OSD 在固定文案后追加截断的
    `result.detail`，给用户/真机可见线索。设置→错误日志页可直接看到真实 ffmpeg stderr。
  - 提交哈希：见本轮提交（worktree 分支 `claude/todo-610-video-clip-export`）。
- **[x] ② 已加自动化测试** —
  - 纯函数守卫：`hibiki/test/media/video/video_clip_exporter_test.dart`、
    `hibiki/test/utils/desktop_audio_clipper_test.dart` 断言 `-map 0:a:$N?` 带 `?`、
    `audioStreamCount` 越界时不加 `-map`。
  - 行为守卫：`video_clip_exporter_test.dart` 用返回退出码非 0 + 非空 stderr 的 FakeFfmpegBackend，
    断言失败时 `ErrorLogService` 收到含该 stderr 的 `VideoClipExport` 记录（C 的回归守卫）。
  - 源码扫描守卫：`hibiki/test/media/video/audio_stream_map_tolerant_guard_test.dart` 扫两文件，
    任何 `-map 0:a:$expr` 插值必带尾随 `?`。
- **备注**：B 方案（.mp4 不兼容音频改 `-c:a aac`）本轮不做，待真机 stderr 命中再开后续 TODO。
  仍需真机验：多音轨 .mkv 切非首轨后导出片段成功 + 失败时设置→错误日志页能看到真实 ffmpeg stderr。
