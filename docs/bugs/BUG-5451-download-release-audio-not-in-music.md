## BUG-5451 · 下载入库的发布里随附的 CD/OST 进不了音乐库
- **报告**：2026-11-25（用户：「我音乐库里面的音乐和 mv 真的齐吗」）
- **真实性**：✅ 真 bug。用户库：MyGO BD 的 `OST`（59 首）、孤独摇滚 BD 附带 `CD`（67 首）在磁盘上、不在任何音乐来源里。纯音频交给音乐库只有视频来源**全量扫描**一条路（`fushi/lib/src/media/source_library/source_library_scanner.dart:2004` `adoptVideoSourceAudio`）；下载任务入库（`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart` `_importMedia`）只建视频行，不交接音频。视频来源 `auto_scan=0`、最后一次扫描 11-10，这两个发布 11-21 / 11-23 才下完，CD 永远等不到扫描。
- **[x] ① 已修复** — pipeline 加 `onReleaseAudioImported` 钩子：入库后把任务里选中、没跳过的纯音频（`videoDownloadJobReleaseAudioPaths`）交给 app；app 侧 `fushi/lib/src/media/music/download_release_audio_intake.dart` 按与扫描同一份规划规则登记音乐来源（视频库媒体目录取库里该来源的视频行，原盘取盘根；不对账）。钩子之前入库的任务由 `replayReleaseAudioHandOff` 启动时补交一次（幂等）。
- **[x] ② 已加自动化测试** — `fushi/test/media/music/download_release_audio_intake_test.dart`、`packages/fushi_engine/test/media/music/metadata/music_release_videos_test.dart`（`videoDownloadJobReleaseAudioPaths` 组）。
- **备注**：同一次排查发现的整理器遗留外挂字幕 / 外挂音轨另记一条。
