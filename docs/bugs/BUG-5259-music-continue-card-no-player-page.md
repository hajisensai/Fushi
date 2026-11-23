## BUG-5259 · music-continue-card-no-player-page
- **报告**：2026-11-23（应用内反馈 iPXB7k6Ssq：音乐库「继续收听」卡点了不进播放页）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_library_page.dart` `_continueListening` 只调 `engine.playQueue(...)`、不调 `openMusicPlayerPage`；主卡与侧卡 `onOpen` 都接它，所以点卡只让迷你条起播，且每点一次都重建队列、把正在放的这首从头重开。专辑页「播放全部」与迷你条点按都会进播放页，这里不一致。
- **[x] ① 已修复** — `_continueListening`：引擎当前曲已是这首时不重建队列，暂停中就 `play()`；否则照旧从所在专辑那一首起播。两种情况都 `openMusicPlayerPage(context)`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music/music_continue_listening_test.dart`：点主卡推入 `MusicLyricsPage`；回曲库暂停后再点，假后端没有第二次整队打开、队列位置不变、接着放。
- **备注**：
