## BUG-272 · 备份导出Win临时目录删除竞争errno145
- **报告**：2026-06-14（用户：TODO-298）
- **真实性**：✅ 真 bug — `hibiki/lib/src/sync/backup_service.dart:409` `_deleteDirectoryIfPresent`
  - `exportBackup` 在 `_stripCredentials`/`_stripDictionaryState` 用 `HibikiDatabase` 打开 temp DB 副本处理后，`finally` 里 `_deleteDirectoryIfPresent(tmpDir)` 递归删 `Directory.systemTemp` 下的导出临时目录。
  - strip 流程的连接生命周期**本身是对的**：`_stripCredentials`/`_stripDictionaryState` 都在 `try { ... } finally { await db.close(); }` 里关了连接，删目录前连接已 close。
  - 真因是 **Windows 平台时序竞争**：`db.close()` 返回后 OS（及 Defender/搜索索引器异步扫描刚写盘的 `hibiki.db` 副本）仍会短暂持有文件句柄，紧接着的递归 delete 撞 `ERROR_DIR_NOT_EMPTY(145)`（子文件仍被锁致目录非空）/`ERROR_SHARING_VIOLATION(32)`/`ERROR_ACCESS_DENIED(5)`。
  - 旧实现只 `catch (PathNotFoundException)`，**不容忍瞬时 FS-busy** → 备份导出偶发 `FileSystemException: 目录不是空的, errno=145` 失败。与 BUG-050（词典导入 `publishImportedDir` 的 Win rename 锁）同族外部平台行为。
- **[x] ① 已修复** — `hibiki/lib/src/sync/backup_service.dart`：把 `_deleteDirectoryIfPresent` 重构为薄包装 + 纯逻辑核心 `deleteDirectoryWithRetry`（依赖全注入，仿 BUG-050 `publishImportedDir` 范式）：Windows-only 对瞬时 FS-busy 码（5/32/145，`_isWindowsTransientFsBusy`）有界重试（默认 `maxAttempts=10`，退避 `50*attempt` ms 给句柄释放窗口）；非 Windows 或非瞬时码**直接 rethrow**（不吞真错误）；重试用尽仍失败则 rethrow（不静默留残目录）；`PathNotFoundException` 现有容忍保留。提交 `<HASH>`
- **[x] ② 已加自动化测试** — `hibiki/test/sync/backup_delete_retry_test.dart`（10 例行为测试）：happy path 一次成功不重试 / 目录不存在不调 delete / `PathNotFoundException` 吞掉 / Win errno 145 两次后成功救回（验有界重试）/ Win errno 32、5 重试救回 / Win 持续 145 用尽 `maxAttempts` 后抛出 / 非 Win errno 145 直接抛 / Win 非瞬时 errno 13 直接抛。注入可控 `exists`/`delete`/`sleep` 伪文件系统，host 验逻辑（真机 Win 真实备份导出待用户复测不再偶发 errno145）。提交 `<HASH>`
- **备注**：连接生命周期已确认正确（strip 流程 try/finally close），无需额外修连接关闭；本修复是不可控外部平台行为（AV/索引器/OS 延迟句柄释放）下的有界重试兼容层，POSIX 一次删成不进重试分支。`test/sync` 合跑有预存 WinFS flaky（多文件共享 systemTemp + drift 多实例），按 CLAUDE.md 单跑验证：新测试单跑 10 绿、各 backup 文件单跑全绿。
