## BUG-2993 · 下载任务菜单实时刷新后旧「删除」被重映射成「补对齐」
- **报告**：2026-10-06（Codex 第六轮审查 HBK-AUDIT-036，分支 `codex/sh-style-review-1006` `44de74851db`，复现 `fushi/test/media/downloads/download_task_menu_refresh_repro.dart`）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/media/downloads/download_task_card.dart:231`：`FushiOverflowMenu<int>` 的菜单值是数组下标，`onSelected: (int index) => widget.menuActions[index].onSelected()` 却按**刷新后**的 `widget.menuActions` 取动作；动作表由 `video_download_jobs_panel.dart` `_menuActions`（约 :1451）按任务能力实时生成）
- **[x] ① 已修复** — `DownloadTaskMenuAction` 加稳定 `id`（open-location / details / pair-audiobook / delete），菜单值改为 id；`_dispatchMenuAction` 选中时在**当前**动作表里按 id 查找再执行，找不到（能力消失、busy 时 `_menuActions` 整表清空）就丢弃这次选择
- **[x] ② 已加自动化测试** — `fushi/test/media/downloads/download_task_menu_stable_action_test.dart`（真 `VideoDownloadJobsPanel` + 实时 job 流：active→completed 时旧「删除」仍走删除确认、补对齐 0 次；completed→active 时旧「补对齐」被丢弃）；修复前 2 例全红、修复后 2 例全绿
- **备注**：Mihon / LNReader 的 `InstalledOnlineSourceRow` 菜单不走 `DownloadTaskCard`，不在本次范围。

### 根因

菜单弹出后浮层持有的是打开时那一刻的条目快照（值 = 下标 0..n-1），而任务卡仍随
`watchJobs()` 实时重建。音频任务从 active 变 completed 时 `videoDownloadJobNeedsAudiobookPairing`
转真，「补对齐」插到「删除」之前；用户在旧菜单里点「删除」（下标 0），回调却在新表里取下标 0
= 「补对齐」，直接执行了另一个动作，且跳过了删除确认。
