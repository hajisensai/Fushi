## BUG-3260 · 外挂字幕解析为空时交给 libmpv 的是失效的 DeliveryUrl
- **报告**：2026-10-10（PR #2033 审查遗留疑点：「Emby 外挂字幕起播只用 DeliveryUrl、不回落」）
- **真实性**：✅ 部分属实（代码路径确认）。下载路径 `getRemoteVideoSubtitle`（`fushi/lib/src/sync/jellyfin_video_client.dart:3265`）本来就按 `_subtitleUrlCandidates` 先 DeliveryUrl 后手拼端点回落；但 `RemoteVideoEmbeddedSubtitleTrack.url` 只取候选第一条（`jellyfin_video_client.dart:3174`，即 DeliveryUrl），外挂轨「下到了却解析不出」时页面把 `track.url` 交给 libmpv（`video_fushi/subtitle.part.dart` `_applyRemoteEmbeddedSubtitle` 的 `onEmptyCues`、`video_fushi_page.dart` `_loadRemoteEpisode` 恢复分支）——若下载是 DeliveryUrl 失效后回落成功的，libmpv 拿到的是那条失效地址，仍然没字幕。另外恢复分支落地名写死 `embedded_<n>.srt`，Emby 外挂 ASS 重进时被按 SRT 解析成空，必然走到这条回落。
- **[x] ① 已修复** — 两处回落改为交**刚下好的本地文件**（`track.copyWith(url: subtitle.path)`），与哪条候选成功无关、也不再走第二次网络；恢复分支落地名改用轨自带的 `fileName`（与手选路径同源，扩展名随原格式）。下载全失败的分支两条候选都已失败，交 `track.url` 不变。提交 `a0ca09e8f0`（`fix(video): hand libmpv the downloaded external subtitle file`）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_remote_embedded_subtitle_player_fallback_guard_test.dart`「外挂轨解析为空：libmpv 读本地已下载文件，落地名随原格式」（源码扫描守卫；页面级 widget 测试需要真 libmpv 与 Emby 服务端，不可落地）。
- **备注**：真机未复测（无 Emby 样本）。
