## BUG-3956 · 歌词模式下系统返回要两次才回书架
- **报告**：2026-11-01（用户：反馈 NJIIDAhIZL（Android 平板））
- **真实性**：✅ 真问题（原为刻意设计）。`fushi/lib/src/pages/implementations/reader_fushi_page.dart` PopScope `onPopInvokedWithResult` 照搬 Esc 阶梯：`_lyricsMode` 时先 `_toggleLyricsMode()` 再返回，系统返回手势要两次才回书架。
- **[x] ① 已修复** — 新增 `fushi/lib/src/reader/reader_back_ladder.dart` `resolveReaderBackStep(source: shortcut|route)`：系统返回（route）先关词典弹窗、否则直接退书；Esc（shortcut）仍是词典 → 歌词 → 退书。提交见 PR（fix(reader): system back exits the book from lyrics mode）。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_back_ladder_test.dart`、`fushi/test/pages/reader_lyrics_exit_and_follow_override_guard_static_test.dart`。
- **备注**：真机返回手势复测待补。
