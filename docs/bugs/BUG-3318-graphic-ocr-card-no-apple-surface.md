## BUG-3318 · 图形字幕OCR进度卡在Apple与墨水屏下不走播放器浮层表面
- **报告**：2026-10-13（审查 BUG-3273~3276 合并时发现；用户要求 UI 同时符合 M3E 与 Apple 风格）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_graphic_subtitle_ocr_progress.dart` 的进度卡（及 BUG-3273 新增的收起药丸）自己画 `Material(color: videoM3eFloatingColor)`，绕开了播放器浮层统一表面 `VideoFloatingPanelSurface`（`video_side_panel.dart`）：Apple 设计系统下是一块 M3 深色卡而不是液态玻璃，墨水屏下是半透明深色而不是实色描边；卡片前景也只 `copyWith` 了配色，组件主题仍烤着 app 浅色值。药丸高 32，命中区偏小。
- **[x] ① 已修复** — 卡片与药丸改走 `VideoFloatingPanelSurface`（Apple 液态玻璃 / M3E 中性深色 + 面板中性主题 / 墨水屏实色描边，三套由同一处决定）；表面新增 `glassRadius` 让药丸在玻璃下也是胶囊；药丸高 40、整颗可点。提交同 BUG-3317。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_graphic_subtitle_ocr_progress_test.dart`「进度卡 / 药丸走播放器浮层统一表面：Apple 是液态玻璃，MD3 不是」；BUG-3273 的浅色主题对比度测试照常通过。
- **备注**：暂停 OCR 状态标记（`VideoGraphicSubtitleOcrStatusPill`）是不可点的 inverseSurface 提示，两套设计下都可读，未动。
