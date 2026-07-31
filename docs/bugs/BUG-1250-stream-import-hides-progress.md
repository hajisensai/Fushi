## BUG-1250 · 边下边播提前入库把下载任务直接标成已完成并丢失进度
- **报告**：2026-07-29（用户：点边下边播会入库，但进度消失并直接变成已完成）
- **真实性**：✅ 真 bug。`hibiki/lib/src/media/torrent/anime_download_service.dart:247` 的 `importNow()` 复用下载完成处理，把未完成计划写成 `statusImported`；轮询器只跟踪 `statusDownloading`，因此任务立刻退出进度集合并显示完成。
- **[x] ① 已修复** — 本提交：新增与下载状态正交的 `importedEarly` 持久标记；提前入库继续保持 downloading 并发布真实进度，真正下载完成后才转 imported，视频入库不会重复执行。
- **[x] ② 已加自动化测试** — `hibiki/test/torrent/anime_download_plan_test.dart` 覆盖新字段兼容性；`hibiki/test/torrent/anime_download_service_test.dart` 覆盖 20% 提前入库、55% 继续跟踪、100% 完成且只导入一次的完整状态链。
- **备注**：任务 UI 同步显示「已入库 · 下载继续」并隐藏重复的边下边播按钮。定向测试启动前被 `sqlite3` 原生资产下载超时阻断（0 tests ran）；仍需真实下载后端复测原始路径。
