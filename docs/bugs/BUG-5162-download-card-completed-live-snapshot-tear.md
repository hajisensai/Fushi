## BUG-5162 · 已完成任务卡片：色调/速度/操作读 DB lifecycle，状态文案/进度读引擎实时快照，引擎回退时显示「完成色 + 下载中 4%」
- **报告**：2026-11-21（用户转来第三方报告 `fushi_download_stuck_bug_report.md` 的 Bug 3）
- **真实性**：✅ 真（代码路径确认，未在设备上复现画面）。`fushi/lib/src/pages/implementations/video_download_jobs_panel.dart`（a11db40c13f）：`_tone`（:1591）、`_compactMetrics` 的 `running`（:1641）、`_quickAction`（:1683）与统一视图 `status`（:931）按 `job.lifecycle` 取；`_progress`（:1069）与 `_torrentStatusLabel`（:1845）优先取实时 `TorrentSnapshot`；组头 `downloadGroupProgress`（`fushi/lib/src/media/downloads/download_task_browser.dart:66`）把 `completed` 记满。引擎回退时两套来源同屏矛盾。
- **[ ] ① 未修复** — 待拍板：哪个来源说了算 / 是否新增「异常 / 待校验」状态，属于 UI 行为取舍，已列为拍板事项 `review-download-card-completed-tear`。BUG-5071 / BUG-5161 修掉了引擎回退的两条主来源。
- **[ ] ② 未加自动化测试** — 随①一起补。
- **备注**：
