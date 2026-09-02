## BUG-2065 · macOS iCloud Documents 迁移到本地目录时 rename 超时并回滚
- **报告**：2026-09-02（用户从 `~/Documents/Fushi/data` 迁到 `~/.fushi`，详细诊断显示 `Directory.rename` 返回 `Operation timed out, errno = 60`）
- **真实性**：✅ 真 bug。`fushi/lib/src/storage/data_root_migrator.dart:488-490` 的 rename 失败回退只接受跨卷 `EXDEV` 与权限层 `EPERM/EACCES`；macOS iCloud File Provider 接管的 Documents 跨域 rename 会返回 `ETIMEDOUT=60`，未命中 `_shouldCopyAfterRenameFailure`，因此在逐文件 copy+verify 仍可用时直接回滚。
- **[x] ① 已修复** —（本提交）macOS 上 `Directory.rename` 返回 `ETIMEDOUT=60` 时改走既有 copy+verify 延迟删源路径；其它平台的 errno 60 不改变语义。
- **[x] ② 已加自动化测试** — `fushi/test/storage/data_root_migrator_test.dart` 增加 macOS errno 60 正向与非 macOS 负向断言；完整迁移套件 27 项通过，覆盖 copy/verify、DB rebase、提交后删源和失败回滚。
- **备注**：copy 回退沿用 TODO-1324 的延迟删源语义：复制与字节校验、DB rebase、位置提交全部成功前不删旧根；任一步失败仍完整回滚。
