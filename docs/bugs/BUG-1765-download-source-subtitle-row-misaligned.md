## BUG-1765 · 下载来源与字幕下拉底边不对齐
- **报告**：2026-08-21（用户截图：下载页资源面板「默认受管视频来源」与「附带字幕」两个下拉底边错位）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_discovery_acquisition_dialogs.dart:1180`——BUG-1713 给左侧来源下拉加了 `helperText`（1191）而右侧字幕下拉没有，两个 `InputDecorator` 总高度不同；外层 `Row` 用默认 `CrossAxisAlignment.center`，右框被向下挤半个 helper 高度，底边错位。
- **[x] ① 已修复** — 该 Row 显式 `crossAxisAlignment: CrossAxisAlignment.start`：两个输入框同高顶对齐（底边自然齐），helper 挂在左框下方不再影响右框。随 worktree-downloads-page-batch-a 批次提交。
- **[x] ② 已加自动化测试** — 源码扫描守卫 `fushi/test/pages/video_discovery_option_row_alignment_guard_test.dart`（该 Row 埋在需要完整 registry/sources 装配的 surface 深处，源扫描是最强可落地层）。已变异实测：删掉对齐行守卫变红，还原经 sha256 逐字节核对。
- **备注**：settings 页同一对 key 的消费（`video_external_provider_settings_section.dart:769`）是纵向单列布局，不受影响。
