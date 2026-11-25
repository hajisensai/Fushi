## BUG-5452 · 本地 MV 自动匹配找不到同一发布里被整理走的 NCOP/NCED/PV
- **报告**：2026-11-25（用户：「我音乐库里面的音乐和 mv 真的齐吗」）
- **真实性**：✅ 真 bug。用户库 `music_videos` / `music_video_match_checks` 都是 0 行。MV 候选只看曲目**附近**（`fushi/lib/src/media/music/metadata/music_video_service.dart` `collectMusicVideoFilesNear`：同目录、MV/PV 目录、相邻原盘）；下载整理把视频搬进 `<作品 (年)>/Extras/SPs`、原盘整盘搬进 `<作品 (年)>/<盘>`，随发布的 CD 留在原发布目录，同一发布的特典与 CD 分在两棵树里，「附近」永远看不到。
- **[x] ① 已修复** — 新增 `packages/fushi_engine/lib/media/music/metadata/music_release_videos.dart`：按下载任务文件清单把发布里的片头片尾 / PV / CM 特典与原盘流（按大小筛）配给发布里的曲目；路径按「来源根下相对路径」配，来源整体搬家（本机 → NAS 映射盘）后仍能由曲目路径反推现在的来源根。后台匹配与手动「找本地 MV」都接上（`MusicVideoNearbyFiles.releaseVideos`，不按文件名筛，交声纹判）。用户真实库模拟：12 个发布都配得上，其中 10 个（约 570 首在库曲目）的特典已全部可读。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/music/metadata/music_release_videos_test.dart`、`fushi/test/media/music/music_video_auto_match_test.dart`（同发布特典 + 来源搬家用例）。
- **备注**：
