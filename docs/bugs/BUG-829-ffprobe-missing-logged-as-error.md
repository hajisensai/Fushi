## BUG-829 · 内封字幕字体枚举缺 ffprobe 被当错误记日志
- **报告**：2026-07-15（用户）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/subtitle_embedded_fonts.dart:260` `_enumerateFontAttachments`。
- **[x] ① 已修复** — `hibiki/lib/src/media/video/subtitle_embedded_fonts.dart:260`
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/subtitle_embedded_fonts_test.dart`（`missing-ffprobe degrade` group）
- **备注**：

### 根因
`_enumerateFontAttachments` 文档契约写「失败返回空列表」，但只处理了「ffprobe 跑起来但退出码非 0」（`!probe.isSuccess`）这一类失败，**没处理「ffprobe 二进制根本不存在」**。桌面 ffprobe 未随产物捆绑（`grep ffmpeg/ffprobe hibiki/windows/ ci/` 全空）也不在 PATH 时，`_backend.runProbe` → `_runCliFfprobe`（`ffmpeg_backend.dart:446`）解析成裸 `ffprobe`，`Process.start` 抛 `ProcessException`（`系统找不到指定的文件。`）并 `rethrow`，穿过无 try/catch 的 `_enumerateFontAttachments` 一路冒到 `loadForVideo` 的兜底 catch（`subtitle_embedded_fonts.dart:251`），被 `ErrorLogService.log('SubtitleEmbeddedFontLoader.loadForVideo', ...)` 当成**应用错误**刷进错误日志页——每开一个带内封字体的视频刷一条。

内封字体是「有则更好」的可选增强（对齐 mpv/libass 的 attachment 字体），缺 ffprobe 是**预期降级**而非错误。

### 修复
在 `_enumerateFontAttachments` 就地 `try/catch (ProcessException)`，捕获「无 ffprobe 可执行」→ 返回空集，回退系统字体 fallback，不再上抛、不记错误日志。诚实兑现「失败返回空列表」的契约；真正意外错误（其余异常）仍会经 `loadForVideo` 兜底记录。
