## BUG-5264 · 音乐速览：播放服务器 / 插件 / Apple Music 曲目时「继续」为空
- **报告**：2026-11-22（用户：侧栏速览卡要与点进去的页面一致；只读审查发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_nav_peek.dart:945-963`（develop 06c73737a2）`_loadMusic` 在 `engine.current != null` 时先 `db.getMusicTrack(current.trackUid)`；服务器 / 插件 / Apple Music 曲目的 uid 是合成的（`media/music/server/music_server_play_item.dart:33`、`media/music/plugin/music_plugins.dart:63`、`apple_music_station_item.dart`），表里查不到返回 null，而回落到最近专辑的分支是 `else if`，于是「继续」为空。播放条（`music_now_playing_bar.dart`）一直直接画播放项本身。
- **[x] ① 已修复** — 「正在播放」条目按播放条的口径从 `MusicPlayItem` 本身建：标题、副行（抽出共用的 `musicNowPlayingByline`，播放条也用它）、封面（`musicCoverImageProvider(item.coverPath)`，曲库曲目只有内嵌封面时再按曲库那一行补）；只有什么都没在播时才回落到最近播放的专辑。新函数 `navPeekNowPlayingEntry`。（提交 2aea2c3928 + 速览接线提交）
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_nav_peek_mirrors_page_test.dart`「服务器曲目（合成 uid、不在曲库表）照样出继续，副行同播放条」+ 守卫。
- **备注**：未在应用里肉眼复测。
