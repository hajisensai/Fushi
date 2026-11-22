## BUG-5105 · 换线路 / 换档重载在停止上报期间被换集，仍拿旧集位置重载并作废新集
- **报告**：2026-11-22（外部审计 HBK-AUDIT-005，Codex 2026-11-21 PR 审查，来源 PR #4007）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/pages/implementations/video_fushi/episode.part.dart:61-80`@cbdc2a45ed：`_recoverInterruptedStream` 只在问线路之后查一次 `_remotePlaybackGeneration`，`await _reportRemotePlaybackStopped(...)` 回来后只查 `mounted`，就用旧集 `positionMs` 载 `_currentEpisode`；`video_fushi_page.dart:5233` `_loadRemoteEpisode` 第一句 `++_remotePlaybackGeneration` / `++_episodeLoadSeq`，`:5618` 取完流才落 `_currentEpisode`。同形还有 `quality.part.dart` 的自适应换档 `:441-464`、手动换档 `:533-552`、换版本 / 线路 `:593-611`）
- **[x] ① 已修复** — 新增 `fushi/lib/src/media/video/remote_session_reload.dart` `reloadRemoteEpisodeInSession`：重载绑定发起时的会话代际，release / 停止上报 / 取流每个异步边界后复核，被更新的加载接管就放弃、返回 false；页面 `_reloadRemoteEpisodeInSession` 一次取定 info / client / 集号，四条路（断流换线路、自适应换档、手动换档、换版本）全部改走它，代际在各自第一个 await 之前取（分支 claude/audit-fix-video-player-async）
- **[x] ② 已加自动化测试** — `fushi/test/media/video/remote_session_reload_test.dart`（阻塞停止上报构造换集次序：新集只载一次且保留自己的起点；新集落定后停止上报才回来；发起前会话已换；页面退出；重载取流期间被接管；正常路径次序）+ 同文件源码守卫（四条路必经 helper、代际先于 await）；`video_remote_playback_release_guard_test.dart` 改核 helper 的释放次序
- **备注**：真机 / 真实 Jellyfin、互联 host 断流复测未做（本代理无设备）；行为测试在次序层用页面语义同构的模型驱动，页面 widget 级远端播放测试目前仓内没有可复用夹具。

### 根因

换线路 / 换档 / 换版本都是「同一播放会话里重载当前集」：释放旧流 → `await` 停止上报（网络）→
`_loadRemoteEpisode(_currentEpisode, initialPositionMsOverride: 旧位置)`。它们是 fire-and-forget
任务，期间用户换集时页面会 `++_remotePlaybackGeneration` 并开始取新集的流，但 `_currentEpisode`
要等取流完成才落。旧任务醒来只查 `mounted`：

- 新集还在取流 → 用旧集号 + 旧位置载入，抢到更新的 `_episodeLoadSeq`，用户刚选的新集被作废；
- 新集已落定 → 用新集号 + **旧集的毫秒位置** 载入，新集丢了自己的起点。

### 修复

`reloadRemoteEpisodeInSession`（纯次序函数，可单测）：入口、停止上报之后各复核一次会话代际；
`load` 同步推进代际，据此认出本程并在取流结束后判断是否被接管。调用方只在返回 true 时弹
「已切换线路 / 画质」OSD；自适应换档返回 false 走既有回滚。

### 变异实测

去掉 helper 里停止上报之后的会话复核（只留 `isMounted()`），`remote_session_reload_test.dart`
前两条换集次序用例变红；恢复后全绿。
