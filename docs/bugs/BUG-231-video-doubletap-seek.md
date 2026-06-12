## BUG-231 · 视频缺双击左右快进 + 步长设置（TODO-173）
- **报告**：2026-06-12（用户：）
- **真实性**：✅ 真缺失（非回归 bug，是缺功能）。`_handleVideoPointerUp`（`hibiki/lib/src/pages/implementations/video_hibiki_page.dart`）双击命中后只按平台分流：桌面 → `_toggleVideoFullscreen`、移动端 → `playOrPause`（TODO-149/BUG-221 的双击暂停），**从不读 `event.position.dx`**，故没有「双击左右快进」。seek 原语 `_seekRelative(deltaMs)` / 字幕跳句 `_skipCueAndPokeControls(forward:)` 已具备。
- **[x] ① 已修复** — 三处串联：
  - (a) `video_asbplayer_config.dart` 加离散字段 `doubleTapSeekSeconds`（取值 `{0=关, 3, 5, 10, -1=字幕跳句}`，默认 0=关保留原暂停/全屏），toJson/decode（白名单兜底 `{-1,0,3,5,10}`）/copyWith/defaults 各补一处。
  - (b) `_handleVideoPointerUp` 双击命中后、平台分流之前插入 `_handleDoubleTapSeek(event.position)`：用 `_videoControlsContext` 的 RenderBox `globalToLocal`（复用 `_isVideoChromePointer` 范式）拿 local.dx/宽度，左 1/3 → 后退、右 1/3 → 前进、**中间 1/3 → 落回原有平台分流（中带保留 149 暂停/全屏）**；`doubleTapSeekSeconds==0` 时整体跳过分区。seek 模式调 `_seekRelative(±n*1000)`、字幕模式调 `_skipCueAndPokeControls`，并 `_showOsd` 提示。
  - (c) `video_quick_settings_sheet.dart` 在 `_buildSeekSecondsRow` 后加 `_buildDoubleTapRow`（`AdaptiveSettingsSegmentedRow<int>` chips：关/3s/5s/10s/下一句），onChanged 走 `_commitAsb(copyWith)`。i18n 新增 key。提交：（见本轮 commit）
- **[x] ② 已加自动化测试** — `video_asbplayer_config_test.dart` 扩 `doubleTapSeekSeconds` 往返/白名单/默认；源码守卫 `video_double_tap_seek_guard_test.dart`（`_handleVideoPointerUp` 读 dx 分区 + 调 `_handleDoubleTapSeek` + 保留 149 中带平台分流 + 设置行存在）。
- **备注**：M 级。与 149（BUG-221）双击暂停协调：仅在其上加左右分区，中带仍走 149 的 `if (_isDesktopVideoControls){toggleFullscreen} else {playOrPause}`，149 守卫断言全保留。号撞风险：并发 TODO-176 占 BUG 号——合并时若撞号由 integration owner 改号。
