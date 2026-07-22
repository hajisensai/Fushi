## BUG-997 · 覆盖导入视频强行进且无法取消勾选
- **报告**：2026-07-13（用户：qqbotxiaoxiao，附截图：导入确认框无「视频」项 + 导入后视频库出现未选的番剧）
- **真实性**：✅ 真 bug，两处根因：
  1. **导入对话框漏显视频类别**：`summarizeBackupArchive`（`hibiki/lib/src/sync/backup_service.dart`）判断「备份有没有视频」只数打包的视频**文件**（`meta.videoFiles`/`videos/` 目录）。但视频记录（`video_books` 行）随 DB blob 无条件覆盖恢复。备份若有视频行但没打包视频文件（流媒体 http 视频 / 旧版本导出 / 文件已不存在），`videoCount=0` → `summary.has(videos)=false` → 对话框 `presentFor`（`backup.part.dart:912`）不列视频 → 用户看不到、无法取消勾选。
  2. **导入取消勾选视频不剥离行**：`importBackupFiles` 的 step 3c 类别剥离（`backup_service.dart`）只剥了 books / statistics / progress，**没有视频**。即便视频类别显示出来、用户取消勾选，覆盖导入也只跳过文件恢复（`effVideosRoot=null`），video_books 行仍留在换入的 DB 里 → 视频照进。
- **[x] ① 已修复** — 提交 `<pending>`。① `BackupMeta` 新增 `videoBookCount`（导出记录 blob 里实际保留的 video_books 行数：视频未勾选=0）；② `summarizeBackupArchive` 视频计数改为 `meta.videoBookCount ?? dbVideoBookCount ?? 文件回退`；③ `summarizeBackupZip` 对**旧备份**（meta 无 videoBookCount）额外用 `_peekVideoBookCount` 从 DB blob（hibiki.db 小元数据库，经 isolate 流式解出）`SELECT COUNT(*) FROM video_books`，让旧备份也能显示视频 toggle；④ 导入 step 3c 补 `if (!wants(videos)) _retainVideos(dbDirectory, {})`，取消勾选真剥离 video_books 行（cascade）。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/backup_video_import_selectable_test.dart`：导出记 videoBookCount（勾/不勾）；summarizeBackupArchive 三态（meta 计数>0 无文件也显示 / meta=0 隐藏且 peek 不越权 / 旧备份走 dbVideoBookCount）；**summarizeBackupZip 对手工构造的旧备份（视频行+无文件+meta 无字段）DB-peek 出视频**；导入取消勾选视频→行清零、保留→行恢复。既有 80 项备份回归全过。
- **备注**：用户备份是旧版本(2026-07-07)所做、无 videoBookCount 且未打包视频文件，正是 DB-peek 分支覆盖的场景。导出侧新备份取消勾选视频已由 `_retainVideos({})` 剥离 DB 行（既有行为）。待真机验证：导入确认框出现「视频」项且取消勾选后视频不进库。
