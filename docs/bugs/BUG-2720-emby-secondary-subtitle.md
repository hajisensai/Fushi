## BUG-2720 · Emby 兼容层上副字幕选内嵌轨必失败
- **报告**：2026-09-27（用户：「emby 副字幕用不了」）
- **真实性**：✅ 真 bug。用户的「Emby」是自研兼容层 UHD Media Server（`/System/Info` ProductName），没有 `/Videos/{id}/{src}/Subtitles/{n}/Stream.*` 抽取端点——2026-09-27 对条目 `m01M1ECWWPVZ5STG9E8NHP4JDGB` 的 4、5 号内嵌 srt 实测均 HTTP 404。主字幕在 BUG-2590 / 2648 加了「抽取失败 → 交给 libmpv 解码、`sub-text` 回流成可点 cue」的回落，**副字幕三条路径都没有**：
  - 选轨 `_applyRemoteEmbeddedSecondarySubtitle`（`fushi/lib/src/pages/implementations/video_fushi/subtitle.part.dart`）：`getRemoteVideoSubtitle` 抛 404 直接报「加载失败」；
  - 重进恢复 `_restoreRemoteSecondarySubtitle`（同文件）：下载失败静默 `return`，副字幕丢失；
  - 控制器只有主槽回流 `selectEmbeddedTextTrackViaPlayer`（`fushi/lib/src/media/video/video_player_controller.dart`），没有副槽（libmpv `secondary-sid`）的对应能力。
  - 顺带缺陷：media_kit 把 `sub-text` 与 `secondary-sub-text` 合成同一条 `[主, 副]` 流，主字幕回流订阅对副槽变化也会收到事件，把事件当作「上一句结束」会提前截断没给 `sub-end` 的暂定句——主副同时回流时才暴露。
- **[x] ① 已修复** — 控制器新增 `selectEmbeddedSecondaryTextTrackViaPlayer`：`secondary-sub-visibility=no` 后选 `secondary-sid`（只解码不画），`secondary-sub-text` + `secondary-sub-start/end` 回流成副 cue 进可点 overlay 副层；`setSecondaryCues` / `clearSecondaryCues` / `load` / `dispose` 结束回流并把 `secondary-sid` 放回 `no`。主副两路订阅都经 `playerSubtitleSlotChanges` 按槽去重。播放页副字幕选轨与重进恢复在抽取失败时回落到它（条件与主字幕相同：直出原始容器、非外挂文件轨，按 `containerTrackOrdinal` 选轨），并持久化 `embedded:<n>`。零额外流量，不引入后台 ffmpeg 抽取（遵守 BUG-2590 的用户拍板）。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/player_decoded_subtitle_cues_test.dart`（按槽去重行为、副轨属性下发顺序、未 load 安全返回、副槽回流源码守卫）；`fushi/test/pages/video_remote_embedded_subtitle_player_fallback_guard_test.dart`（副字幕选轨 / 恢复先回落再报失败、走副槽不占主槽、持久化）；真服务器取证 `fushi/integration_test/media_server_emby_embedded_subtitle_itest.dart` 新增 `FUSHI_EMBY_SECONDARY_TRACK` 阶段。
- **备注**：libmpv 的 `secondary-sub-start/end/visibility` 属性在随包 Windows libmpv（v0.41 dev）已核对存在；旧版 libmpv 缺起止属性时 `buildPlayerDecodedCue` 退回事件时刻 + 暂定时长，缺可见性属性时副字幕会被 libmpv 画进画面（不影响可点 overlay）。同一条轨不能同时占主副两槽（libmpv 限制），主副要选不同的轨。
