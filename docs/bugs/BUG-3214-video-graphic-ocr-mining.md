## BUG-3214 · 视频暂停 OCR 出的文字无法制卡
- **报告**：2026-10-09（用户：视频暂停后自动 OCR 出的文字没法制卡）
- **真实性**：❌ 未复现（无 PGS / VobSub 样片与 OCR 引擎环境，未真机跑）。走查：暂停 OCR 层
  `fushi/lib/src/media/video/video_graphic_subtitle_ocr_overlay.dart` 点字 → `video_fushi_page.dart` `_buildGraphicSubtitleOcrOverlay`
  → `_handleSubtitleLookupTap(..., null)` → `_lookupAt`（`overrideCue: null`）。图形字幕没有 cue，`resolveVideoLookupAnchorCue` 多半回 null，
  `_resolveVideoMiningRange`（`video_fushi/lookup_mining.part.dart`）产出 `0..0` 区间：按 `immersion_mining_engine.dart` 的「无 cue」约定
  只出静帧卡（无句子音频 / 片段），句子字段是 OCR 文本；若当前帧截图也失败则 `no cover and no audio produced` 中止并弹 OSD。
  因此「没法制卡」可能是：① 卡制成了但没有句子音频（预期带音频）；② 截图失败导致中止；③ 其它入口问题。需用户补充现象（是否有 OSD 报错、卡是否进了 Anki）。
- **[ ] ① 未修复** — 若是 ①：可用 mpv `sub-start` / `sub-end` 给暂停 OCR 帧补上图形字幕事件的时间窗，属新增能力，待确认后做。
- **[ ] ② 未加自动化测试** —
- **备注**：
