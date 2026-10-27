## BUG-3822 · 视频字幕栏每次都从「全部」页签打开，不记得上次停在「收藏」
- **报告**：2026-10-27（用户：应用内反馈 xlzGuK5YmD，Windows 3.0.1-debug.20797，设计诉求；所有者 2026-10-27 按分诊推荐拍板：记住上次打开的页签，不按「有收藏就开收藏」硬判）
- **真实性**：✅ 行为确认。`fushi/lib/src/media/video/video_subtitle_jump_panel.dart:725`（修前）`VideoSubtitleListFilter _filter = VideoSubtitleListFilter.all;` 是面板纯内存状态，每次打开列表都重置为「全部」；同面板的自动滚动 / 点字幕查词 / 字号档位早已落 Drift preferences，唯独页签没有。
- **[x] ① 已修复** — 面板新增 `initialFilter` / `onFilterChanged`（与 `initialTapLookup` / `onTapLookupChanged` 同构），`_setFilter` 只在用户真的换了页签时回调；偏好键 `video_subtitle_list_filter`（string，`VideoSubtitleListFilter.name`，默认 `all`，已登记 `preference_keys.dart`）经 `PreferencesRepository` / `AppModel` 读写，持久化归属与同面板其余三项一致（普通 preferences 键，随 Profile 快照 / 备份走）。本地视频页（`video_fushi/subtitle.part.dart`）与网页视频页（`web_video_fushi_page.dart`）都按它打开、切换即落盘；`videoSubtitleListFilterFromName` 解析存值，认不出回落「全部」。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_jump_panel_test.dart`「xlzGuK5YmD: opens on the remembered tab and reports tab switches」（真 widget：初值为收藏时直接只显示收藏句、恢复初值不回调、点「全部」回调一次；初值为全部时即使有收藏也开全部）与「persisted tab name round-trips」（存值解析 + 两个页面接线 + 枚举名冻结）。
- **备注**：未在 Windows 真机复测。
