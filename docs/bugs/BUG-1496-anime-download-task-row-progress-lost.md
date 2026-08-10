## BUG-1496 · 下载任务行百分比/确定进度环依赖 downloadStats，「立即导入」一跑就整列消失
- **报告**：2026-08-01（用户：develop 全量体检既有红，主行=2453 第③组）
- **真实性**：✅ 真 bug。根因两处：
  - `hibiki/lib/src/pages/implementations/anime_download_dialog.dart:2206`（`_buildPlanRow` 只订阅 `service.downloadStats`）+ `:2213`（`_buildPlanRowInner` 用 `stats?.progress` 当唯一进度来源）——BUG-1494（`708704bbf`）把任务行从 `downloadProgress` 换到 `downloadStats` 之后，百分比与确定进度环的存活条件从「有进度」收紧成「有完整观测值」。
  - `hibiki/lib/src/media/torrent/anime_download_service.dart:420`（`_importNowUnlocked`）调 `_publishProgress` 只传进度、`stats` 走默认空 map，而 `_publishProgress:285` 是无条件覆盖 → **「立即导入」路径把全表的 `downloadStats` 清空**，直到下一轮 tick（内置引擎 3s、外接 qb 20s）才恢复。期间任务行退成不定进度环 + 无百分比，与 `downloadProgress:271-274` 注释声明的契约（「UI 任务行订阅它换成确定进度环 + 百分比」）以及 `downloadStats:275` 注释声明的「键集合与 downloadProgress 一致」都相矛盾。
- **[x] ① 已修复** — 进度只认 `downloadProgress`（恒发布的规范通道），`downloadStats` 退回「有就补速度/流量，没有也不影响百分比」的增强位；同时让 `_importNowUnlocked` 带上它手里已有的 `TorrentSnapshot`，不再清空别的计划的观测值。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/anime_download_dialog_embedded_push_test.dart`（既有 `early task 在 800x600/窄屏…` 用例恢复为真判据，且补一条「有 stats 时百分比后接速度/流量」）+ `hibiki/test/torrent/anime_download_service_progress_test.dart` 新增「importNow 不清空 downloadStats」用例。
- **备注**：原 `find.text('55%')` 断言之所以红，正是因为该契约被打破；修复后只喂 `downloadProgress` 就能渲染出纯 `55%`，断言无需改动即恢复绿——这是「测试判据本来是对的，是功能坏了」的直接证据。
