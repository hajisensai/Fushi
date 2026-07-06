## BUG-570 · 尊重字幕自带样式开关重开视频后失效
- **报告**：2026-07-06（用户：ASSx2 .ass 字幕，打开「尊重字幕自带样式」仍走 app 样式）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:1692`（`_loadSingle` 用 `repo.loadCues` 从 DB 取 cue）+ `packages/hibiki_audio/lib/src/audiobook/audiobook_model.dart:92`（`AudioCue.markup` 瞬态、DB 往返不携带）。
  - 字幕 overlay `VideoSubtitleOverlay` 的 respectAssStyle 只在 `currentCue.markup != null` 时应用 `cueStyle`（V4+ Styles 字体/主色/描边）。首次加载外挂 .ass 走 parser（markup 在内存，开关生效）；单视频把 cue 落库（`saveSubtitleSelection`，markup 不入库）后**重开视频**，`_loadSingle` 直接用 `loadCues` 的无 markup cue → `currentCue.markup==null` → respectAssStyle 恒退回 app 统一样式。
  - 播放列表换集走 `_restorePersistedSubtitle`→`loadCuesForSource` 是重解析、天然带 markup，不受影响；故只坏在单视频重开路径。
- **[x] ① 已修复** — `video_hibiki_page.dart` `_loadSingle`：持久化字幕源是仍在磁盘上的外挂文本档案（`_rehydratableExternalSubtitlePath`：`.srt/.ass/.ssa/.vtt` 且 `existsSync`）时，重解析档案（`_loadExternalSubtitleCues`）作为真相源拿回带 markup 的 cue，而非直接用 DB 无样式 cue。内嵌轨（`embedded:<n>`）不重解析，保留 DB 缓存避免 BUG-081 的 ffmpeg 重抽取。提交见分支 todo1246-ass-style。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_subtitle_ass_style_rehydrate_test.dart`：① 行为层证明 DB 往返丢 markup + 重解析档案恢复 cueStyle（真 parser + drift 内存 repo + 临时档案）；② 源码守卫 `_loadSingle` 确在用 `_rehydratableExternalSubtitlePath` 驱动 `_loadExternalSubtitleCues` 重解析。既有 `ass_parser_test.dart`（cueStyle 解析）/`video_subtitle_overlay_markup_test.dart`（respectAssStyle 应用 cueStyle）已覆盖 parser + overlay 两端。
- **备注**：内嵌 ASS 轨重开仍走 DB 缓存、markup 未恢复（重抽取昂贵，BUG-081 权衡）；用户报的是外挂 .ass，已覆盖。若后续要让内嵌 ASS 也尊重自带样式，需缓存抽取出的 .ass 档案路径供廉价重解析，另开工。
