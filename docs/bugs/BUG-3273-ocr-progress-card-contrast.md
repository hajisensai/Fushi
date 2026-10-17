## BUG-3273 · 图形字幕转文字进度卡浅色主题下文字看不清且无法收起
- **报告**：2026-10-11（用户：截图反馈播放器左上角「转成文字字幕（OCR）」进度卡文字完全看不清，且卡片没法隐藏）
- **真实性**：✅ 真 bug。卡片底色走 `videoM3eFloatingColor`（恒为深色悬浮表面），而 `video_fushi_page.dart` 外层包的 `_videoChromeColorScheme(context)` 只是原样返回 app 主题的配色（`video_fushi_page.dart:1358`）；卡片标题 / 状态取 `theme.textTheme`、引擎行取 `scheme.onSurfaceVariant`（`video_graphic_subtitle_ocr_progress.dart` 旧 build），浅色主题下全是深色字压在深色底上。卡片上只有「取消」，没有收起入口，整轨任务期间一直挡画面。
- **[x] ① 已修复** — 卡片前景改取 `videoM3eNeutralChromeScheme`（与底色同一套深色方案，textTheme / iconTheme 同步换色）；卡片标题栏加「收起」，收成一枚图标 + 进度环 + 百分比的小药丸，点药丸展开，进度刷新不会弹开。同批：整轨 OCR 改为边抽轨边识别，播放头附近优先，识别结果实时补进可点字幕（`recognizeGraphicSubtitleCuesLive`）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_graphic_subtitle_ocr_progress_test.dart`（浅色主题下文字亮度高于卡片底色；收起 / 刷新不弹开 / 展开）；`fushi/test/media/video/graphic_subtitle_track_ocr_test.dart`「边看边识别」组；`fushi/test/pages/video_graphic_subtitle_guard_test.dart` 接线守卫。
- **备注**：PGS 是纯位图字幕，轨里没有任何文字数据，只能 OCR。
