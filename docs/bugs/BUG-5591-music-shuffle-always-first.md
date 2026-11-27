## BUG-5591 · music-shuffle-always-first
- **报告**：2026-11-27（用户：应用内反馈 L2u-0VI18A）
- **真实性**：✅ 真 bug。音乐「随机播放」总从列表第一首开始。根因 `fushi/lib/src/media/music/music_player_engine.dart` `playQueue`（旧 `startIndex = 0` + shuffle 分支 `items[start]` 固定排第一）：各「随机播放全部」入口（`music_apple_music_pages.dart` `playMusicServerTracks`、`music_album_page.dart` / `music_local_playlist_page.dart` / `music_cd_detail.dart` / `music_server_pages.dart` / 插件页 `_playTracks` 的 `shuffle: true`、控制面 `/player/play` 不给 index）都不传起点，默认 0，于是第一首永远是列表第一首；`music_listen_from_video.dart` 另自己用 `Random().nextInt` 凑起点绕过。
- **[x] ① 已修复** — `playQueue` 的 `startIndex` 改为可空：null + shuffle = 整队打乱（第一首也随机），给了起点再随机 = 那首排第一；null + 顺序 = 第一首。所有包装层（`playMusicServerTracks`、CD / 服务器专辑 / 歌单 `_play`、插件 `_playTracks` / `play`、`MusicCtlPlayer` 与 `/player/play` 的 `index`）起点同改可空透传；删掉 `music_listen_from_video.dart` 的随机起点特例，统一走引擎语义。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/music_player_engine_test.dart`「BUG-5591 随机播放全部」（注入固定 `Random(seed)`，断言队列 = 同种子打乱结果、12 个种子第一首不全相同）；`fushi/test/ops/ctl_music_routes_test.dart` 断言随机不给 index 时起点透传为 null。
- **备注**：
