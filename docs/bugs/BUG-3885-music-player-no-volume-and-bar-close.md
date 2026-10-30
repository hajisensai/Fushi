## BUG-3885 · music-player-no-volume-and-bar-close
- **报告**：2026-10-30（用户：用户：音乐播放器内无法调节音量；底部栏要一个关闭按钮）
- **真实性**：✅ 真缺口。`fushi/lib/src/pages/implementations/music/music_lyrics_page.dart` 的走带行只有五格，没有音量入口；`music_now_playing_bar.dart` 迷你条没有停止 / 关闭按钮。
- **[x] ① 已修复** — 播放页走带行改六格，加入与底栏同款的 `MusicVolumeButton`（点开弹滑杆，所有按钮同一行）；迷你条（窄屏卡片 roomy 时、宽屏展开态）加关闭按钮（`session.stop()`）。
- **[x] ② 已加自动化测试** — 既有 `fushi/test/pages/music_lyrics_page_test.dart`、`music_now_playing_bar_pushed_route_test.dart`（见 PR）。
- **备注**：Windows 调试实例上人工确认过。
