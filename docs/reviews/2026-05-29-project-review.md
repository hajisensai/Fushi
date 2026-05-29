# 2026-05-29 Project Review — 备份/同步功能 (sync/backup)

## Round 1 — sync 模块全量审查 + 本地备份测试补强

### Scope

- 目录：`hibiki/lib/src/sync/`（26 个文件，约 10100 行）
- 重点：本地全库备份 `BackupService`、同步编排 `SyncManager`/`SyncRepository`、各 backend 实现
  （Google Drive / WebDAV / OneDrive / Dropbox / Box / FTP / SFTP / SMB / Hibiki LAN server+client / fallback）
- UI 接线：`sync_settings_schema.dart`
- 测试：`hibiki/test/sync/`（10 个测试文件）
- 基线：`dart analyze lib/src/sync` 无报错；`flutter test test/sync` 108→109 通过

### Findings

#### HBK-AUDIT-S06 — 本地备份缺端到端 round-trip 测试 — severity: Low — status: FIXED & VERIFIED
- 文件：`hibiki/test/sync/backup_service_test.dart`
- 根因：原测试覆盖 `validateBackup`/`importBackupFiles`/`exportBackup` 各环节，但**没有**“插入真实数据 → 导出 → 导入到全新目录 → 重开 DB → 校验数据一致”的闭环验证。备份的根本意义（数据可恢复）未被证明。
- 影响：`exportBackup` 走 `VACUUM INTO`（失败回退 `wal_checkpoint(TRUNCATE)`+copy），若该路径有缺陷，备份会“看起来成功”但恢复后丢数据，现有测试无法捕获。
- 修复：新增 `export then import round-trip preserves database content` 测试——写入书籍（含 CJK 标题 `かがみの孤城`）+ 阅读统计，导出 zip，导入到独立目录，重开 `HibikiDatabase` 校验书籍/章节数/统计字符数/阅读时长完全一致。
- 验证：`flutter test test/sync` → 109 passed；`dart format` 无变更。

#### HBK-AUDIT-S01 — OAuth 云 backend 为占位桩，UI 仍可选 — severity: Medium — status: OPEN（需产品决策）
- 文件：`onedrive_sync_backend.dart:23`、`dropbox_sync_backend.dart:23`、`box_sync_backend.dart:23`
- 根因：三者 `_clientId = 'YOUR_*'` 占位符，`authenticate()` 检测到前缀即抛 `SyncAuthError('... not configured')`。但 `_backendLabel`/`_BackendSelectorWidget` 把它们和可用 backend 一并列入下拉菜单。
- 影响：用户选择 OneDrive/Dropbox/Box 并点登录 → 永远收到 “not configured” snackbar，无法使用，体验为“假功能”。非崩溃，属优雅降级。
- 修复建议（二选一，需用户拍板）：(a) 配置真实 OAuth client ID/密钥；(b) 在凭据未配置时从下拉菜单隐藏/禁用这三项。Google Drive、WebDAV、FTP/SFTP/SMB、Hibiki LAN 不受影响。

#### HBK-AUDIT-S02 — FTP 连接保活缺口：断链后不重连 — severity: Medium — status: OPEN（已上报，未盲改）
- 文件：`ftp_sync_backend.dart:467` `_ensureConnected`；对比 `sftp_sync_backend.dart:99` `refreshAuth` 有 `isClosed` 检测
- 根因：`_ensureConnected` 仅判断 `_client != null && _connected`。FTP 控制连接被服务器空闲超时/单边关闭后，`_connected` 仍为 `true`，后续操作抛通用错误且被包装成**非 retryable** 的 `SyncBackendError`，`SyncManager` 不会重试，且状态永远卡在 `connected` 直到 `signOut` → 之后每次同步都失败。
- 影响：长时间挂起后首次自动同步大概率失败，需手动登出重连。
- 修复建议：操作失败时调用 `_disconnect()` 复位 `_connected=false`，使下次 `_ensureConnected` 重连（参考 SFTP 的 `isClosed` 思路）。
- 为何未直接修：`FTPConnect` 直接 new、不可注入，无法在 CI 单测复现“控制连接被断开”的原始失败路径；按本仓“声明修好前必须验证原始失败路径”的规则，不盲改可工作代码。建议在有真实 FTP 服务器环境时再修并复测。

#### HBK-AUDIT-S03 — OneDrive 路径段未 URL 编码（非 ASCII 文件名） — severity: High（LATENT，当前不可达） — status: OPEN
- 文件：`onedrive_sync_backend.dart:326`（cover）、`:426`（content upload）、`:572`（`_uploadJson`）
- 根因：`/me/drive/items/$folderId:/$fileName:/content` 直接插入原始 `fileName`。`sanitizeTtuFilename` 故意保留 CJK 与空格，OneDrive Graph 要求 `:/...:/` 之间的段做 percent-encode，否则 400/404。
- 影响：日文书名内容/封面上传会失败。但因 S01（client ID 占位），该路径当前不可达，故为潜伏 bug。
- 修复建议：对 `fileName` 用 `Uri.encodeComponent`。配置 OAuth 前与 S01 一并处理。

#### HBK-AUDIT-S04 — OneDrive/Dropbox 单次上传大小上限 — severity: Medium（LATENT） — status: OPEN
- 文件：`onedrive_sync_backend.dart:417`（简单 PUT，4MB 上限）、`dropbox_sync_backend.dart` `/files/upload`（150MB 上限）
- 根因：内容同步用单次上传端点；有声书（.m4b）远超限额。
- 影响：开启“内容同步”且推送大音频时失败。同样因 S01 当前不可达。
- 修复建议：改用 upload session（Graph `createUploadSession` 分块 / Dropbox `upload_session/*`）。

#### HBK-AUDIT-S05 — `listBooks`/`cacheBookFolderIds` 为死接口方法 — severity: Low — status: OPEN（清理候选）
- 文件：`sync_backend.dart:49,102` + 各 backend 实现
- 根因：全仓搜索 `listBooks(`/`cacheBookFolderIds` 仅出现在接口定义、各 backend override 与测试 stub，`SyncManager`/`sync_auto_trigger`/`sync_compare_dialog` 均未调用。
- 影响：无功能影响；子代理曾就 `cacheBookFolderIds` 用 `f.name`(原始 displayName) 与 `ensureBookFolder` 用 `sanitized` 查导致缓存键不一致提出疑虑——因方法从未被调用，实际无影响。
- 修复建议：确认无未来计划后可从接口移除以减表面积；非必须。

### 结论分级

- 已验证通过的修复：S06（本地备份 round-trip 测试）。
- 代码路径审查发现的风险（未复现/未改）：S01、S02、S05。
- 潜伏 bug（当前不可达，待 OAuth 配置后处理）：S03、S04。
- 本轮**未发现**会导致本地备份丢数据或崩溃的缺陷；`BackupService` 导出/校验/导入逻辑健全。

### Next Scope

- 待用户就 S01 决策（隐藏未配置 backend vs 配置密钥）后处理 S01/S03/S04。
- 若提供真实 FTP 测试环境，修复并复测 S02。
- 可选：为 WebDAV/SFTP backend 增加针对 `SyncManager` 实际调用路径的 mock 集成测试（auth → ensureBookFolder → updateProgressFile → getProgressFile 闭环）。
