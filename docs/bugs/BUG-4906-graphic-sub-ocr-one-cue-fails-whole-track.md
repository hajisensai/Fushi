## BUG-4906 · 图形字幕整轨转文字一条 cue 出错整个任务作废
- **报告**：2026-11-20（路线图 #3722 c36 / gap-disc-1：整轨转文字时一条 cue 出错整个任务作废，已识别的文字全部丢掉）
- **真实性**：✅ 真 bug：`fushi/lib/src/media/video/graphic_subtitle_track_ocr.dart` 的 `recognizeGraphicSubtitleCuesLive` 里，每条 cue 的渲染 / 识别都在 `launch` 的 `catch (error, stack) { failure ??= error; }` 里落成整任务失败；主循环下一轮 `if (failure != null)` 就 `Error.throwWithStackTrace`，调用方 `fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart` 的 `_runGraphicTrackOcr` 进 `catch` 报「导入失败」，实时补进的半截文字被 `restoreGraphic` 撤回，已识别的全部丢掉。单条失败（某张位图解码异常、Lens 单次请求超时等）与引擎整体坏掉走同一条路径。
- **[x] ① 已修复** — 单条渲染 / 识别出错只跳过这一条（已在 `started` 里，不重排、不自动重试），经新回调 `onCueError` 报出；`GraphicSubtitleOcrUnavailable` 仍立即整任务失败；连续 `kGraphicSubtitleOcrMaxConsecutiveFailures`（8）条失败、或收尾时一条都没识别出而有失败，抛最后一个错误让整任务失败（引擎 / 网络整体坏掉，不空转到轨尾，也不把「识别坏了」误报成「这条轨没有文字」）。页面侧累计失败条数写进错误日志，产物落盘后给一条警告提示 `video_subtitle_graphic_ocr_cues_skipped`（跳过了几条）。
- **[x] ② 已增加自动化测试** — `fushi/test/media/video/graphic_subtitle_track_ocr_test.dart`「整轨识别：单条失败不作废整轨」组 4 项：中间一条失败其余照常出字且不重试；连续失败达阈值整任务失败且不再排新 cue；失败不连续不作废；全失败抛错。修复前第 1、3 项会因整任务抛错而红。
- **备注**：未做 Windows 真机 2 小时 PGS 片中途断网验证（本轮所有者定不做设备验证）。
