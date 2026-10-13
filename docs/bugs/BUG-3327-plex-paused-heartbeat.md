## BUG-3327 · Plex心跳把已暂停条目重新标成播放中
- **报告**：2026-10-13（审查第三方 PR #2107「Jellyfin 延迟心跳保留暂停状态」时发现 Plex 同根问题）
- **真实性**：✅ 真 bug。`fushi/lib/src/sync/plex_video_client.dart` 的 `putRemoteVideoPosition`（修前约 874 行）恒发 `/:/timeline?state=playing`。播放页 `_persistRemotePosition`（`video_fushi_page.dart`）要先 `await prefsRepo.setPref` 才上报心跳，后台暂停的 `setRemoteVideoPlaybackPaused(paused: true)` 会先到，迟到的心跳把条目改回 playing——与 Jellyfin #2107 的 `IsPaused=false` 同一根因。
- **[x] ① 已修复** — 把按条目的暂停意图抽成两边共享的 `RemotePlaybackPauseIntent`（`fushi/lib/src/sync/remote_video_client.dart`：暂停意图在请求发出前同步记下，起播在第一个 await 前清除，停止时保留，按条目归属）；Jellyfin 换用它（行为不变），Plex 的心跳与暂停上报都按它决定 `paused` / `playing`。提交 `fix(plex): heartbeat follows the per-item pause intent instead of always "playing" (BUG-3327)`。
- **[x] ② 已加自动化测试** — `fushi/test/sync/plex_paused_heartbeat_test.dart`（8 例：未暂停报 playing、暂停后迟到心跳报 paused 且不发 stopped、继续后恢复、暂停请求在途时已报 paused、暂停上报失败后下一条心跳补上、重新起播清除意图、停止后迟到心跳仍 paused、暂停不串到别的集）；回归 `jellyfin_paused_heartbeat_test.dart`、`plex_video_client_test.dart`。
- **备注**：未在真 Plex Media Server 上复测。
