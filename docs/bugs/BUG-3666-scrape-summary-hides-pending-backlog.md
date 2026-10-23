## BUG-3666 · scrape-summary-hides-pending-backlog
- **报告**：2026-10-23（用户：「怎么没让我决策的，又说没刮削出来」→「全部根本性修复，然后pr」）
- **真实性**：✅ 真 bug。后台任务完成卡写「已应用 12 个，待手动确认 0 个，已跳过 178 个」，而库里 17 部等确认、用户以为没东西要决策。根因 `fushi/lib/src/media/video/metadata/video_source_scrape_dialog.dart` `_reportRows`：复用书籍批量的 `scrape_all_done`，「待手动确认」只数本批新增（早在清单里的作品后台补刮不重问），「已跳过」填的是 `protectedArtifacts`（受保护未覆盖的 sidecar 文件数）而不是作品数。
- **[x] ① 已修复** — 视频面板改用 `video_source_scrape_report_summary`（作品数与文件数分开说）；待确认清单非空时结果卡加「待确认清单里还有 N 部」与「去确认」按钮直达「待确认」页签。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_source_scrape_ui_test.dart`（finished report points at the pending backlog：结果卡显示积压并一键切到「待确认」页签）。
- **备注**：同批还有 BUG-3662（CLI candidates 只过滤不搜）。本机数据已用 CLI 手工改绑修复。
