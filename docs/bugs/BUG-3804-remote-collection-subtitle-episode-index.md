## BUG-3804 · 互联合集连播第 2 集起拿不到主机选定的外挂字幕
- **报告**：2026-10-25（用户：反馈 XmUBLYR1Ut，Windows 主机 + Android 客户端，远程播放剧集拿不到主机上选定的外挂字幕，BUG-3615 后仍复现）
- **真实性**：✅ 真 bug。合集连播时 `_loadRemoteEpisode` 的 `index` 是合集内位置，每个成员在主机上是单视频（`streamEpisodeIndex` 恒 0，取流用它），默认字幕下载却传 `episodeIndex: index`（`fushi/lib/src/pages/implementations/video_fushi_page.dart:4683`），主机 `_resolveEpisodeVideoPath` 对单视频 `episodeIndex>0` 返回 null → 404，客户端局部 catch 只 debugPrint，静默无字幕。BUG-3615 只修了主机下发。
- **[x] ① 已修复** — 默认字幕下载改传 `streamEpisodeIndex`，与取流同一个主机侧集序号。提交见分支 `claude/feedback-system-fix-d0ccae`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_remote_episode_index_guard_test.dart`（源码扫描：`_loadRemoteEpisode` 内所有 client 按集请求只能传 `streamEpisodeIndex`）。
- **备注**：未在真机互联上复测；页面级远端加载没有可轻量驱动的测试设施，故用源码守卫。
