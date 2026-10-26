## BUG-3783 · subtitle-backfill-race-reports-installed
- **报告**：2026-10-26（AI 助手操作目录描述子代理在写 `video.subtitle.download` 的撤销时发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/subtitle/video_subtitle_backfill.dart` 的 `_writeSidecar`：开头与对齐之后两道「同名 sidecar 已存在」检查命中时都 `return target`，调用方（`backfill` 与手动下载两处）把返回值当成功，报 `SubtitleBackfillOutcome.installed` + `installedPath` 指向**原本就存在、不是这次写的**文件。后果：成功提示是假的；AI 助手「撤销 = 删掉刚装的字幕」会按这个路径删掉用户原有字幕。
- **[x] ① 已修复** — `_writeSidecar` 改返回 `bool`（true = 这次真写了），两处调用方在 false 时报 `alreadyHasSubtitle`（新的 `_sameNameExists`），`installedPath` 只在真写时给。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/subtitle/video_subtitle_backfill_alignment_test.dart`「对齐期间同名 sidecar 已被别人落下」补断言 `outcome == alreadyHasSubtitle`。
- **备注**：AI 撤销侧另有修改时间防护（`op_descriptions_video.dart`），但根因在这里。
