## BUG-5453 · 下载整理只搬视频，发布自带的外挂字幕/外挂音轨留在原地
- **报告**：2026-11-25（用户：「我音乐库里面的音乐和 mv 真的齐吗」排查中发现）
- **真实性**：✅ 真 bug。`packages/fushi_engine/lib/media/video/download/video_download_organizer.dart` `plan()` 只给视频与原盘文件出整理计划；用户库 `video_download_job_files` 里 110 个 `.ass`、9 个 `.mka` 停在原发布目录。整理后的视频丢了发布组的中文外挂字幕；旁边没了视频的整片 `.mka`（天気の子 英 / 日 5.1 音轨、Audio Guide，吹响 / 哆啦A梦 / 孤独摇滚 Re 的整片 FLAC 音轨）被视频来源扫描当纯音频收进音乐库，成了 9 首「歌」。
- **[x] ① 已修复** — `planVideoReleaseCompanions`：同目录或视频目录直接子目录、以视频主干 + `.`/`_`/`-` 开头的字幕 / 音轨随视频落到目标目录（`<目标主干><后缀>`，文字字幕后缀对齐 `isSidecarSubtitleSuffix`），经 `backend.renameFile` 改名（种子继续做种），文件行 kind 记 `subtitle`。存量由 `relocateStrandedReleaseCompanions` 在管线启动时补搬（幂等；种子已摘 / 视频已删 / 目标被占则跳过记日志）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_release_companions_test.dart`。
- **备注**：本机播放器不自动挂本地外挂音轨（`fushi/lib/src/media/video/video_player_controller.dart` 只挂在线源 URL），搬过去的 `.mka` 目前只是跟着视频走、不再被误收成歌；能否在播放时选用是另一项功能。已误收进音乐库的那 9 条曲目，文件搬走后由所在音乐来源下次重扫软删。
