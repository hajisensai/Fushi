## BUG-5180 · 阅读器起播有声漫画不带封面，首页迷你播放条只有兜底图标
- **报告**：2026-11-21（应用内反馈 #Wi5MxmIT24，开发者本人：「这个底部的播放条是硬播放条？？？为什么没有共用原有播放条」）
- **真实性**：✅ 真 bug，但不是「没共用播放条」：首页那条就是共用的 `NowListeningMiniBar` → `FushiNowPlayingBar`（`fushi/lib/src/media/audiobook/now_listening_mini_bar.dart:101`）。看起来像另一条，是因为会话没有封面，迷你条走兜底图标、没有封面取色。
  - 根因：`fushi/lib/src/media/manga/reader/manga_fushi/read_aloud.part.dart:320-324` 调 `resolveMangaAudioSessionRequest` 只传 title / author，没传 coverPath；后台入口 `audiobook_session_launcher.dart:126-139` 经 `_bookMeta` 传了。两个入口各自拼元数据，于是分叉。
- **[x] ① 已修复** — 新增 `audiobook_session_book_meta.dart` `loadSessionBookMeta`（书名走 override 通道、封面按书架同一解析 `resolveBookCoverFilePath`），`resolveMangaAudioSessionRequest` 内部按 bookKey 自己取，去掉调用方的 title / author / coverPath 参数；launcher 的私有 `_bookMeta` 删掉改用同一函数。
- **[x] ② 已增加自动化测试** — `fushi/test/media/manga/audio/manga_audio_playback_test.dart`「阅读器起播与后台入口给会话的书名 / 作者 / 封面一致且带封面」。变异实测：会话里不带封面时该项红，恢复后绿。
- **备注**：真机未复测新构建。
