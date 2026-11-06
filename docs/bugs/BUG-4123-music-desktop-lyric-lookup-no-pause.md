## BUG-4123 · Music desktop lyric lookups ignore Pause while looking up words
- **报告**：2026-11-05（用户：桌面歌词查词时音乐要不要也暂停）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/models/app_model.dart` 的 `FloatingLyricMusicSurface(onLookup: …)`：桌面歌词点词只路由查词卡，从不读 `music_lyrics_lookup_pause`；该设置在「音乐」设置里、文案「Pause while looking up words」不限于歌词页，只有 `fushi/lib/src/pages/implementations/music/music_lyrics_page.dart` 的 `_onLookup` 生效）
- **[x] ① 已修复** — 新增 `MusicLookupPause`（`fushi/lib/src/media/music/lyrics/music_lookup_pause.dart`），与歌词页同口径：设置开 + 在播才暂停，只续播自己暂停的；卡开着时用户自己恢复过播放就不再接管。续播信号：全局查词卡走 `GlobalLookupController.addHiddenListener`（新增，可多订阅，不与视频页接管的单槽 `onHidden` 互相顶替）；应用内查词卡走 `FloatingLyricLookupNotifier.lookupClosed`（新增，host 在用户关掉最后一层时发）。全局卡只在确实弹出后才暂停（未弹出不会有关卡回调）。（分支 fix/music-desktop-lyric-lookup-pause）
- **[x] ② 已加自动化测试** — `fushi/test/media/music/lyrics/music_lookup_pause_test.dart`（暂停 / 续播规则 6 例、应用内卡关卡信号、接线源码扫描 3 例）
- **备注**：有声书悬浮字幕同一个原生窗口也不暂停，但那边没有「查词时暂停」设置，属新功能，按用户决定不在本条范围。全局查词卡真实弹出 / 关闭依赖 WebView2，headless 测不了整链，待 Windows 真机复测：开桌面歌词 → 点词 → 音乐暂停 → 关卡 → 续播。
