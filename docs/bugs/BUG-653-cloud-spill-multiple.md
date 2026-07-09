## BUG-653 · 云盘 per-book 文件溢出根目录并累积多份（TODO-1340，BUG-619 复报）

- **报告**：2026-07-09（用户复报：「云盘同步好像会把文件丢到文件夹外面·并且丢很多份」）。BUG-619（TODO-1329）修过空 title 溢出，用户复报且新增「丢很多份」。
- **真实性**：✅ 真 bug。两半：
  1. **溢出源已在 develop 修复（用户是旧包）**：空 title EPUB 行让 `ensureBookFolder('')` 在路径式后端（webdav/ftp/sftp/dropbox/onedrive）塌缩成同步根 `hibiki-data/`，把 `progress_*/statistics_*/audioBook_*/cover_*` 直接写进根。TODO-1329（`a45bedb37`，**2026-07-08 10:40 才合 develop**）已在写入源头堵死：`sync_backend.dart:56` `requireBookFolderName` 空名抛错、`sync_manager.dart:256` `_syncBookOnce` 空 title 早退、`sync_orchestrator.dart:1383` 空 bookKey 跳过。子代理审计确认**当前 develop 无任何非空 title 写根的活路径**（所有写调用点 folderId 只来自受守卫的 `ensureBookFolder` 或常量 namespace）。当日无 tag 含 `a45bedb37` → 用户几乎必是旧包。
  2. **「丢很多份」根因 = 溢出残留从不清理 + churn 文件名累积**：TODO-1329 只堵新写、**从不清理已溢出到根的历史文件**（其备注明写「已溅到根的历史文件本修复不自动迁移」）。而 per-book 元数据文件名**每次导出都变**（`ttu_filename.dart:29-33`：progress 名带 `updatedAt`、audioBook 名带 `DateTime.now()` 见 `sync_manager.dart:664`），去重探针 `findSyncFileByPrefix`（`sync_utils.dart:33`）**只返回第一个前缀匹配、无孤儿 GC**。多份溢出书 + 跨书 clobber + churn 名 → 根目录里同类文件堆积成多份，且**升级到 1329 新包也不会自愈**（根里的残留没人清）。

### 根因

- 溢出写入源：`sync_manager.dart:274`（`ensureBookFolder`）→ 空 title 塌缩根（TODO-1329 已堵）。
- 累积/残留：无任何代码扫描并清理同步根里错位的 per-book 文件；`sync_utils.dart:33` 单文件去重使多余副本成永久孤儿。用户升级后仍见根里历史残留 + 其重复副本。

### 修复

- **[x] ① 已修复** — 分支 `todo1340-cloud-spill-v2`（commit 见下）。在写入源头（1329）之外补**幂等根目录清扫**，清掉 1329 留下的残留 + 其多份副本，自愈老用户：
  1. `ttu_filename.dart`：新增谓词 `isTtuPerBookFileName`（`^(?:progress|statistics|audioBook|cover)_1_6[._]`）识别「只应存在于书文件夹内」的 per-book 文件名。
  2. `sync_orchestrator.dart`：`run()` 取到 root 后、per-book sweep 前调用新增 `pruneRootSpill(root, report)`：`listChildren(root)` 后删除**每一个**匹配谓词的**非文件夹直接子项**（多份全删，非只删第一个）。书文件夹 / `__dictionaries__` / `__local_audio__` / `__aggregate__`（都是文件夹）与根里的无关文件一律不动；best-effort（列举/删除失败进 `report.errors` 不中断）。`SyncRunReport` 加 `rootSpillFilesRemoved` 计数。契约安全依据：子代理审计确认**无任何代码合法把裸文件写进根**，根只含文件夹 → 根里的 per-book 文件必是溢出残留。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_root_spill_prune_test.dart`：
  - 谓词单测：progress/statistics/audioBook/cover 四型 + 多扩展名命中；书名/`.hibikiaudio`/`.hibikidict`/保留 namespace/错 schema/仅前缀词（`progression.json`）不误伤。
  - `pruneRootSpill` 行为测试（FakeAssetStore + FakeSyncBackend）：根里 4 型溢出 + 1 份重复 progress 全删（`rootSpillFilesRemoved==5`），书文件夹 / 保留 namespace / 无关文件 / **书文件夹内的合法 per-book 文件**全保留；空根幂等 no-op。
  - 回归修复：`sync_orchestrator_conflict_test.dart` 的 fake backend `listChildren` 桩由 `UnimplementedError` 改返空列表（`run()` 现合法调用它扫根）。
  - `flutter test test/sync/` 1196 例全绿；改动文件 `flutter analyze` 净。

- **备注**：
  - **待真机双设备验收**：Windows + Android 各配同一 WebDAV/坚果云等云盘账户 → 制造一本空 title 书或用历史已溢出账户 → 触发同步 → 云盘文件浏览器确认 `hibiki-data/` 根下不再有 `progress_*/audioBook_*/statistics_*/cover_*` 裸文件（多份也清空）、书文件夹内文件完好、正常书进度同步不受影响。
  - **未做的次要 follow-up（非本次报告症状）**：书文件夹**内部**的孤儿累积（audioBook 名用 `DateTime.now()` 每次变 + `findSyncFileByPrefix` 单文件去重 + 无 GC），在多设备并发 / 最终一致 / 上传中途被杀这些竞态下会在书文件夹里留 ≥2 份同前缀孤儿且不自愈。因 progress 文件名时间戳是 conflict resolution 载荷（`sync_manager.dart:292` `parseProgressTimestamp`）不能改稳定名自愈，根治需在 listSyncFiles 层做「删除除最新外所有同前缀文件」的孤儿 GC（触及 7 个后端，风险较高，宜单独审慎推进）。本次范围聚焦用户实际所见的**根目录**溢出+多份（`pruneRootSpill` 已根治该面）。
