## BUG-5454 · 本机播放器不加载本地视频旁的外挂音轨
- **报告**：2026-11-25（用户：「本机播放器目前不会自动加载本地的外挂音轨 这是bug吧」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/video_player_controller.dart` `load()` 只对调用方给的 `externalAudioTracks`（在线源扩展的 `Video.audioTracks`）发 `audio-add … auto`，本地视频没有任何发现外挂音轨的环节；本地页面也不传这个参数。发布组随片附的 `.mka` / `.flac` / `.dts`（天気の子 英 / 日 5.1、评论音轨、整片 FLAC 音轨）在本机音轨面板里永远选不到。
- **[x] ① 已修复** — 引擎 `video_sidecar.dart` 新增纯函数 `listSidecarAudioTracks`（同目录 + 直接子目录、视频主干 + `.`/`_`/`-` 开头、外挂音轨扩展名 `isSidecarAudioExtension`；最长主干认领；纯数字主干不认子目录同号文件）与 `sidecarAudioLabel`（标签 / 语言码），下载整理器带走外挂件也改用同一份扩展名判据。app 侧 `video_local_sidecar_audio.dart` 只做目录 IO；`load()` 对本地普通文件（非原盘菜单 / 播放列表 / DVD 标题）与 open 并行列目录，结果并进可选外挂音轨，走原有 `audio-add … auto` + `track-list` 认轨链路：不抢原声，选中后制卡从该音轨裁音频。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/video/video_sidecar_audio_test.dart`（判据）、`fushi/test/media/video/video_local_sidecar_audio_test.dart`（真实临时目录发现）。
- **备注**：互联远端播放 host 的本地视频时仍拿不到外挂音轨：host `/streamurl` 只下发 `sidecarSubtitles`，要补一条鉴权音频流路由（`packages/fushi_engine/lib/sync/fushi_sync_server/video.part.dart`、`local_library_host_service/videos.part.dart`）并把发现结果下发成 `externalAudioTracks`，未做。
