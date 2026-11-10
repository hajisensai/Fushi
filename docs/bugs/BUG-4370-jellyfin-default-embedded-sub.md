## BUG-4370 · Jellyfin 服务器标为默认的内嵌字幕起播不显示
- **报告**：2026-11-07（用户：应用内反馈 wCQIR4Pvz9，iOS 3.0.0+19763，iPad）
- **真实性**：✅ 真 bug。根因（develop `b765ac68f1` 行号）：
  1. `fushi/lib/src/sync/jellyfin_video_client.dart:2343` `parseMediaSource` 构造 `JellyfinSubtitleStream` 不读 `IsDefault`（同函数音轨 :2337 读了），服务器默认标记在入口就丢了；
  2. `fushi/lib/src/sync/jellyfin_video_client.dart:3549` 起播只把 `IsExternal` 外挂文本轨当后端默认字幕（`subtitleUrl`），内嵌轨只进选择器；
  3. `fushi/lib/src/pages/implementations/video_fushi_page.dart:4862` `_loadRemoteEpisode` 只重放**持久化**选择，没有持久化选择时只会挂后端默认外挂字幕；远端 `videoPath == null`，本地那套「自动抽内封文本轨 + 主字幕语言偏好」（`video_player_controller.dart` `_loadEmbeddedSubtitleIfNeeded`）直接 return。于是服务器标了默认的内嵌字幕永远不会自动显示，app 的主字幕语言偏好对远端也不生效。
- **[x] ① 已修复** — 维护者拍板「app 偏好优先，偏好未命中再用服务器默认标记」。`JellyfinSubtitleStream.isDefault` 读 `IsDefault`，经新增的 `RemoteVideoEmbeddedSubtitleTrack.isDefault`（含 JSON / copyWith）交给播放页；纯函数 `pickRemoteStartupSubtitleTrack`（`remote_subtitle_catalog.dart`）定优先级：持久化选择 > 主字幕语言偏好（与本地同一套 `pickSubtitleSourceByPreference`）> 服务器默认标记 > 后端默认外挂字幕。挑中的轨编码成 `embedded:<n>` 走与手选 / 重放同一条路径（服务器抽取，失败回落 libmpv），不持久化。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_remote_startup_subtitle_pick_test.dart`（判据单测 + Jellyfin `IsDefault` 解析 + JSON 往返 + 播放页接线源码守卫）。
- **备注**：图形默认轨（PGS 等）不自动挂（与本地自动抽取只挑文本轨一致）。未做真机 / Jellyfin 实机复测；测试未在本分支运行，统一在合并后验证。
