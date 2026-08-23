## BUG-1808 · 歌词模式实测未激活具体reader-action焦点节点
- **报告**：2026-08-24（`iPhone pay` / iOS 26.6 物理机有声书进入歌词模式）
- **真实性**：✅ 真 bug（测试基建）。第一轮未请求具体 action；加固后实机已证明具体 `reader-action` FocusNode、`ActivateIntent=true`、quick settings 关闭均成功，但仍无歌词 loadData。继续回溯发现物理机 app container 跨测试保留 `ReaderFushiSource.lyricsMode`：原值为 true 时开书先启动 pending auto-restore，本用例随后手动 toggle 会撞 `_lyricsModeTransition` 早返回。用例没有保存/归零/恢复该持久化前置，结果取决于上次会话状态。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** — RED：物理机 `reader_lyrics_mode_entry_itest.dart` 在“lyrics page must report ready”失败，exit 1；修复后同一用例请求具体 reader-action FocusNode、断言 ActivateIntent 成功和 sheet 关闭，再验证真实歌词 DOM。
- **备注**：修复保留具体 action 激活断言，在开书前保存原 lyricsMode、置 false 并在 tearDown 恢复；下一层断言 sheet 关闭后 reader 仍在且 lyricsMode 变 true，用来区分误激活邻近退出按钮、toggle 早返回与后续 WebView load 失败。
