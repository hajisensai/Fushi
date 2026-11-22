## BUG-5212 · resume-missing-host-torrent
- **报告**：2026-11-22（用户：下载中心全选批量「继续」，提示「已处理 128 项 · 13 项不支持此操作 · 1 项失败」）
- **真实性**：✅ 真 bug。失败那条是 2026-11-21 迁到 `fushi_host`（VM102）之前就暂停、进度 0 的任务，种子从没移植到服务端（VM102 的 131 个 `.resume` 里没有它）。`packages/fushi_engine/lib/media/video/download/video_download_pipeline_service.dart` `_resumeJob` 只对 `embedded` 后端在种子丢失时回退 enqueue 重建，其它后端一律抛 `The torrent is no longer available in the original backend`；`retryJob` 同样只对 `embedded` 回退。13 项「不支持」是 8 条漫画任务 + 5 条没有可继续 / 续做种动作的视频任务，属正常。
- **[x] ① 已修复** — 用户显式「继续」/「重试」时，download 阶段的种子从原后端消失就回到 enqueue，在**同一个**已校验身份（kind / profile / fingerprint）的后端上按任务原选资源重建，不限内置引擎；后端身份不符仍拒绝。自动观察路径（`_observeDownload`）不变，仍只对内置引擎自动重建。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/download/video_download_pipeline_service_test.dart` 组 `fushi_host task missing from the host`：批量继续回 enqueue 并在同一后端 add、重试回 enqueue、后端身份变了仍拒绝。
- **备注**：失败原因目前只进 `debugPrint`，批量提示里看不到是哪条、为什么失败。
