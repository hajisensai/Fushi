## BUG-1561 · 互联下载失败态只写进内存永不上屏，任务表只增不减、页面 dispose 后零提示
- **报告**：2026-08-12（用户：互联 UI 层审计）
- **真实性**：✅ 真 bug。
  - 失败出口缺失：`fushi/lib/src/sync/interconnect_download_manager.dart:130-139` 失败时置 `failed` + 存 `error` 后 rethrow，而唯一的 UI 消费点 `fushi/lib/src/pages/implementations/home_video_page.dart:4330-4345`（旧行号）只读 `isRunning` / `progressFor`——`failed` 分支在渲染上根本不存在。下载任务刻意与页面生命周期解耦（TODO-819），失败常发生在用户已离开该页之后，`_downloadRemote`（`home_video_page.dart:1595` 附近）的 `if (!mounted) return;` 把唯一那条 SnackBar 吃掉 → 用户回来看到的还是一张什么都没发生的占位卡。
  - 生命周期缺失：`clearTask` 生产零调用，`_tasks` 只增不减，一次会话下载/重试多少条就永久占多少格。
- **[x] ① 已修复** — 两头：(a) 卡片给失败态一个恒定出口——`RemoteDownloadFailedBadge`（`fushi/lib/src/sync/remote_download_progress_badge.dart`）由 `_remoteDownloadBadge`（`home_video_page.dart:4287`）按 `InterconnectDownloadTask.status` 分流渲染，tooltip 带真实错误文本，重进页面照样在，再点一次下载即重试；(b) 结束态有界保留——`_retainFinished` + `maxFinishedTasks=32`（`interconnect_download_manager.dart:83/153`），重跑同 id 会把上一轮结束态顶掉，running 永不淘汰。随本轮 `fix(interconnect)` 提交。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_download_failure_surface_test.dart`：结束态有界 / 重试顶替 / running 不淘汰 / 错误文本保留（真 manager 行为），以及占位卡按状态分流、卡片不再用裸 `isRunning(video.id)` 判据（源码守卫）。
- **备注**：`rethrow` 保留——页面还活着时那条即时 SnackBar 仍是最快反馈，角标是它的兜底而非替代。
