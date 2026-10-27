## BUG-3802 · 复习媒体同步每轮全量对账（媒体同步慢）
- **报告**：2026-10-28（用户：为什么媒体同步那么慢）
- **真实性**：✅ 真 bug。`fushi/lib/src/srs/srs_sync_scheduler.dart` `_syncWithBackend` 每轮、每个位置都跑 `srsSyncMedia`（`packages/fushi_engine/lib/srs/srs_media_sync.dart`）：全量列远端媒体目录、逐个 `existsSync` 本机文件、扫三遍笔记引用、每轮重建旧格式索引；配合 BUG-3801 的循环几乎不停。
- **[x] ① 已修复** — 只在这一轮有新操作进出（applied / uploaded / fork / 改用 uid）、该位置本进程还没对账过、或距上次满 `kSrsMediaReconcileInterval`（30 分钟）时对账；用户主动同步（立即同步 / 进复习 tab）全量对账。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_sync_scheduler_test.dart`「媒体对账：没有新操作进出的一轮跳过…」。
- **备注**：`srsSyncMedia` 内部仍是全量算法（列目录 / stat / 三次引用扫描），持久化「已确认在远端的文件集合」做真正增量是后续项。
