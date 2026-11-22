## BUG-5213 · 曲库「继续收听」卡正在播放时再点只续播、进不了播放页
- **报告**：2026-11-22（用户：「点这里的继续收听，只会把底下的继续播放。多次点击不会进到播放界面，改一下吧，在播放了点击就进页面」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/music/music_library_page.dart` `_continueListening` 无论当前在放什么都无条件 `engine.playQueue(...)`：卡上那首 / 那张专辑已经在放时再点，只是把队列重排一遍、在底部播放条里从头起播，卡片本身从来不进播放页。
- **[x] ① 已修复** — `_continueListening` 先判 `isContinueCardAlreadyPlaying`（当前曲目就是这张卡的那首，或同一张专辑已经往后放了几首）：是就（暂停着先接着放）`openMusicPlayerPage`，不再重新起播；否则照旧起播。
- **[x] ② 已加自动化测试** — `fushi/test/pages/music/music_continue_card_open_player_test.dart`（判据：同曲 / 同专辑别的曲 / 别的专辑 / 散曲 / 没在放）。
- **备注**：没在真实 app 里点验。
