## BUG-454 · 导入备份清空未导出的词典
- **报告**：2026-06-28（用户：导出备份时没勾选导出词典，导入该备份后已有词典被清空）
- **真实性**：✅ 真 bug。覆盖式导入（`importBackupFiles`）在备份不含词典时把本机词典连库带文件一起清空。两条破坏路径：
  - **库元数据**（主因）：导出未勾词典时 `_stripDictionaryState` 删掉导出 DB 副本里的全部 `dictionary_metadata` + `dictionary_history` 行（`hibiki/lib/src/sync/backup_service.dart:510-520`、由 `:339-341` 触发）；导入时整库覆盖 `currentDb.writeAsBytes(dbFile.content)`（`hibiki/lib/src/sync/backup_service.dart:651`）→ 本机词典元数据归零。
  - **资源文件**：UI 永远传 `dictionaryResourceDirectory`（`hibiki/lib/src/sync/sync_settings_schema/backup.part.dart:321`），导入恒调 `_restoreDictionaryResources`，该函数**无条件**删整个词典资源目录（`hibiki/lib/src/sync/backup_service.dart:1279-1281`）后按空计划恢复 0 个文件 → 词典文件也没了。
  - 正确语义：备份不含某类数据时应**保留**本机现有数据（选择性合并），而非全替换清空。这正是用户要的优化。
  - merge 导入路径（`mergeImportBackupFiles`）本就 copy-if-absent 不删，不受影响；本 bug 仅覆盖式导入。
- **[x] ① 已修复** — `hibiki/lib/src/sync/backup_service.dart`：覆盖式导入时探测「备份 DB 是否携带词典元数据」，备份无词典则 (a) 跳过 `_restoreDictionaryResources` 的目录清空，(b) 从 pre-restore.bak 把本机 `dictionary_metadata` + `dictionary_history` 行回填进刚覆盖的 DB。提交 `f9515501f`
- **[x] ② 已加自动化测试** — `hibiki/test/sync/backup_import_preserve_test.dart`：构造「带词典的本机 + 不含词典的备份」→ 覆盖式导入 → 断言本机词典元数据/历史/资源文件仍在；并加一条「备份含词典则按备份替换」反向用例守住替换语义。提交 `f9515501f`
- **备注**：与本地不入库 `docs/REGRESSION_BUGS.md` 区分。采番撞 origin/develop 的 BUG-453（win-global-lookup-render），renumber 至 454。
