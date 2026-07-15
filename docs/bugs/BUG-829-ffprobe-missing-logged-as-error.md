## BUG-829 · 内封字体不生效（枚举缺 ffprobe，还被当错误刷日志）
- **报告**：2026-07-15（用户；追问「为什么内封字体不支持？支持一下」）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/video/subtitle_embedded_fonts.dart` `_enumerateFontAttachments` 唯一依赖 ffprobe。
- **[x] ① 已修复** — `hibiki/lib/src/media/video/subtitle_embedded_fonts.dart`（枚举改用 ffmpeg `-i`，新增 `parseFfmpegFontAttachments`）
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/subtitle_embedded_fonts_test.dart`（`parseFfmpegFontAttachments` group + `missing-binary degrade` group）
- **备注**：

### 根因（两层）
内封字体链路：**ffprobe 枚举附件流 → ffmpeg `-dump_attachment` 抽取 → 解析 sfnt name 表 → FontLoader 注册**。唯独「枚举」这步用 ffprobe，而**桌面 ffprobe 未随产物捆绑**（`grep ffmpeg/ffprobe hibiki/windows/ ci/` 全空）也不在 PATH。于是 `_backend.runProbe` → `_runCliFfprobe`（`ffmpeg_backend.dart:446`）解析成裸 `ffprobe`，`Process.start` 抛 `ProcessException`（`系统找不到指定的文件。`）。后果两层：
1. **功能层**：枚举直接失败 → 内封字体在缺 ffprobe 的机器上**根本不生效**（字幕退回系统字体，观感与 mpv 差）。
2. **日志层**：异常穿过无 try/catch 的 `_enumerateFontAttachments` 冒到 `loadForVideo` 兜底 catch，被 `ErrorLogService.log('SubtitleEmbeddedFontLoader.loadForVideo', ...)` 当**应用错误**刷进错误日志页（每开一个带内封字体的视频刷一条）。

对比：内封**字幕**枚举走 ffmpeg `-i`（`video_subtitle_source.dart` `parseSubtitleStreamsFromFfmpegLog`），在同一台机器上是工作的——差别就在字体这步用了不该用的 ffprobe。

### 修复（让内封字体真正支持）
把附件枚举从 ffprobe 换成 **ffmpeg `-i`**（与内封字幕枚举同一可用工具、同一 `FfmpegBackend`）：
- 新增纯函数 `parseFfmpegFontAttachments(ffmpegLog)`：解析 ffmpeg `-i` stderr 的 `Stream #0:N: Attachment: <codec>` + metadata `filename`/`mimetype`，判据复用 `_isFontAttachment`，`attachmentOrdinal` 按附件流序递增对齐 `-dump_attachment:t:<n>`。
- `_enumerateFontAttachments` 改调 `_backend.run(['-hide_banner','-i',videoPath])`，只看 output 不看退出码（`-i` 无输出恒非 0），不再用 `runProbe`。
- 连 ffmpeg 都缺时 `catch (ProcessException)` → 返回空集诚实降级，不刷错误日志。

结果：**「能列内嵌字幕的机器就能列内嵌字体」**，内封字体真正生效；缺可执行文件时也不再误报错误。旧 `parseFfprobeFontAttachments`（JSON 解析）保留（有单测、纯函数），仅不再是生产枚举路径。
