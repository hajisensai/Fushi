## BUG-4015 · 歌词模式 Esc 先退歌词层再退书，要按两次才回书架
- **报告**：2026-11-04（用户：应用内反馈 NaFaJbaAdc，Windows）
- **真实性**：✅ 真 bug（有意设计与用户期望不符）——`fushi/lib/src/reader/reader_back_ladder.dart` 的 `resolveReaderBackStep` 对 `ReaderBackSource.shortcut` 在 `lyricsMode` 下返回 `closeLyrics`，`reader_fushi/caret.part.dart` 的 `globalBack` 分支据此先 `_toggleLyricsMode()`，第二次 Esc 才退书。
- **[x] ① 已修复** — 阶梯不再区分来源：快捷键（Esc / Alt+← / 手柄 B）与系统返回同一条——词典弹窗先关，否则退书；删掉 `ReaderBackSource` 与 `ReaderBackStep.closeLyrics`。歌词开关照常记在书上，重开仍是歌词模式；退书前仍先退窗口全屏。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_back_ladder_test.dart`；源码守卫 `fushi/test/pages/reader_lyrics_exit_and_follow_override_guard_static_test.dart`（globalBack 不许再 `_toggleLyricsMode()`）。
- **备注**：系统返回早在 BUG-3956（NJIIDAhIZL）就改成直接退书。
