## BUG-4323 · 视频进度条显示还有时间（23:39/24:02）但拖不到后面：mkv 容器时长被字幕轨拉长
- **报告**：2026-11-09（开发者自提，应用内反馈 DnLQJmQfqA，Windows）
- **真实性**：✅ 真 bug，已用原文件复现。根因在文件 + libmpv，app 侧只是照搬了容器时长：
  - `BanG Dream! It's MyGO!!!!! (2023) - S01E03.mkv`（mkvmerge v80）容器 `Duration: 00:24:02.00`，
    但视频轨 `DURATION` 统计标签 `00:23:39.962`、音频轨 `00:23:40.016`；英文 ASS 字幕轨到
    `00:24:00`、其余字幕轨更长——Segment Duration 取的是所有轨（含字幕）的结束时间。
  - libmpv（`mpv v0.41.0 --keep-open=yes --hr-seek=yes --hr-seek-framedrop=no`，与 media_kit
    默认一致）`seek 1430 absolute` 后立即 `eof-reached`，`time-pos=1419.92`，`duration=1442`：
    23:40 之后没有可解的帧，`keep-open` 停在最后一帧，进度条又弹回 23:39。
  - app 侧排除：进度条 `third_party/media_kit_video/.../material_desktop.dart:1440` 直接
    `player.seek(duration * slider)`；`VideoPlayerController.seekMs` / `notifyExternalSeek` 只钳
    到 `>= 0`；`clampSeekTargetMs` 钳到 duration；`hr-seek-demuxer-offset` 对本地文件恒 0
    （`mpv_cache_snapshot.dart` `hrSeekDemuxerOffsetForSeek`）；OP/ED 自动跳过只在段首 3 s
    窗口内触发（`video_theme_song_tracker.dart`）；没有任何改写 seek 目标的逻辑。
  - 问题所在：所有界面的总时长都来自 libmpv `duration`（只读、`--end` 也不改它），即
    `fushi/lib/src/media/video/video_player_controller.dart` 读 `player.state.duration` 的
    `durationMs` 与 media_kit 控制条，从不核对音视频真正结束在哪。
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/video/video_playable_end.dart`：duration 就绪后读
  libmpv `track-list`，取所有容器内音视频轨 `metadata.DURATION` 的最大值作为可达末尾；早于容器
  时长时把 media_kit `PlatformPlayer` 的时长状态与时长流改成它（进度条、时间文本、横滑 / 双击
  seek、章节刻度、`durationMs` 一致生效）。缺任一音视频轨标签不修正；播放位置越过修正值即撤销、
  还原容器时长；换集 / 销毁 dispose。接线：`video_player_controller.dart`
  `_refreshChaptersWhenDurationReady` → `_refreshPlayableEndForLoad`。EOF 时写一行
  `video` 诊断（落点 / 时长 / 容器时长 / 最近 seek 目标），没有统计标签的文件以后可据此排查。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_playable_end_test.dart`（标签解析、
  track-list 判据用实测 MyGO track-list、修正写入 / 重报 / 被位置推翻 / dispose，以及控制器接线
  源码守卫）。测试未在本分支运行，统一在合并后验证。
- **备注**：没有逐轨统计标签的文件（多数 MP4、老工具封装的 mkv）不修正，仍会出现同样现象，
  只能从 EOF 诊断日志看出来；未做真机 / 应用内复测（本批次不做真机验证）。
