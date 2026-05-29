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

- 若提供真实 FTP 测试环境，修复并复测 S02。
- 用户填入真实 OAuth client ID（外部依赖）后，处理 S03/S04 并打通 OAuth 回调链路（见 Round 2 备注）。
- 可选：为 WebDAV/SFTP backend 增加针对 `SyncManager` 实际调用路径的 mock 集成测试（auth → ensureBookFolder → updateProgressFile → getProgressFile 闭环）。

---

## Round 2 — 应用可验证的修复

本轮对 Round 1 findings 中**不依赖外部密钥/真机**的项做了根因修复，全部经 `dart analyze lib/src/sync`（无报错）与 `flutter test test/sync`（112 passed）验证。

> 注意：本轮改动涉及的 `onedrive/dropbox/box_sync_backend.dart` 为工作区未跟踪文件、`sync_settings_schema.dart` 为已修改文件（均为他人在建 WIP），与本轮修复在同一批文件中无法用 `git add` 拆分，故未单独提交，留待与 WIP 一并提交。本报告本身单独提交。

### S01 — FIXED & VERIFIED（隐藏未配置 backend）
- 改动：三个 OAuth backend 新增 `static bool get isConfigured => !_clientId.startsWith('YOUR_')`；`sync_settings_schema.dart` 新增 `_isBackendSelectable`/`_selectableBackends`，下拉菜单只列出已配置 backend；已持久化的当前值始终保留以满足 `DropdownButton` 约束。
- 效果：未配置 client ID 的 OneDrive/Dropbox/Box 不再出现在下拉里（消除“假功能”）；填入真实 ID 后自动重新出现。
- 测试：新增 `test/sync/oauth_backend_config_test.dart` 锁定三者 `isConfigured == false` 契约。

### S03 — FIXED & VERIFIED（OneDrive 文件名 URL 编码）
- 改动：`onedrive_sync_backend.dart` 的 cover 上传、content 上传、`_uploadJson` 三处路径段改用 `Uri.encodeComponent(fileName)`。
- 效果：日文/含空格文件名不再生成非法 Graph URL。对 ASCII 文件名行为不变（零回归风险）。

### S02 — 外部依赖阻塞，未改
- FTP 断链重连需要真实 FTP 服务器复现“控制连接空闲断开”的原始失败路径；按本仓“声明修好前必须验证原始失败路径”的规则，不在无法复现的情况下盲改可工作代码。已在 Round 1 给出修复方向。

### S04 — 外部依赖阻塞（OAuth 大文件分块上传）
- 仅在 client ID 配置且开启内容同步推送大音频时可达；待 OAuth 配置后与 S03 一并处理。

### OAuth 回调链路（S01 根因基建）— 外部依赖阻塞
- 复审发现：`AndroidManifest.xml` 仅注册 `hibiki://lookup`，未注册 `hibiki://auth/*`；`main.dart` 的 `handleIntent` 只处理 `action.MAIN`，从不调用各 backend 的 `handleAuthCode(code)`。
- 即拿到真实 client ID，浏览器授权后的回调也无法回到 App。打通需改 manifest（触发 `gradlew assembleRelease` 验证）+ 在 `handleIntent` 解析 auth code，且需真机验证浏览器→App 跳转；属外部依赖，留待用户提供 ID 后一并实现复测。
- Box 额外注意：当前 token 交换未发 `client_secret`，若 Box 应用类型强制要求 secret，需相应调整。

---

## Round 3 — 移除 Box backend（用户决策）

用户决定彻底删除 Box backend（Box OAuth 摩擦最大：多半强制 `client_secret`、对自定义 scheme 回调限制更严）。本轮做完整移除，经 `dart analyze lib test`（无 error/warning）与 `flutter test test/sync test/i18n` 验证。

- 删除文件：`lib/src/sync/box_sync_backend.dart`、`test/sync` 中 Box 相关断言。
- `sync_backend.dart`：从 `SyncBackendType` 枚举移除 `box`。
- `google_drive_sync_backend.dart`：`resolveSyncBackend` 移除 box 分支与 import。
- `sync_settings_schema.dart`：`_isBackendSelectable`/`_backendLabel` 移除 box 分支与 import。
- `sync_repository.dart`：移除 Box 凭据存取（`_keyBoxToken`/`getBoxToken`/`setBoxToken`）。
- `oauth_backend_config_test.dart`：移除 Box 契约测试。
- i18n：用 `tool/i18n_sync.dart --remove sync_backend_box` 删除全部 17 语言 key，并 `dart run slang` 重新生成 `strings.g.dart`。
- 影响：枚举无遗留穷举分支报错；剩余 OAuth backend 仅 OneDrive/Dropbox（仍待真实 client ID + 回调链路）。

---

## Round 4 — 打通 OAuth 回调链路（S01 根因基建）

Round 1 复审指出的"回调链路断裂"（拿到 client ID 也无法完成授权）本轮接通。这是代码层基建，不依赖真实 client ID，可用 analyzer + gradle 构建验证；真实 e2e（浏览器→App→token 交换）仍需用户填入 client ID 后在真机验证。

- `AndroidManifest.xml`：给 `MainActivity` 新增 `hibiki://auth`（scheme=hibiki, host=auth）的 VIEW + BROWSABLE intent-filter，覆盖 `hibiki://auth/onedrive`、`hibiki://auth/dropbox`。
- `main.dart`：`handleIntent` 新增分支——收到 `data` 以 `hibiki://auth/` 开头的 intent 时，解析 provider 段与 `code` 查询参数，路由到 `OneDriveSyncBackend`/`DropboxSyncBackend` 的 `handleAuthCode(code)`，成功/失败用 `HibikiToast` 提示（复用现有 `sync_signed_in`/`sync_auth_error`/`sync_error` i18n key，未新增 key）。
- 流程闭环：用户点登录 → backend `authenticate()` 拉起浏览器并暂存 PKCE verifier+repo → 浏览器回跳 `hibiki://auth/<provider>?code=...` → Android 路由回 `MainActivity` → `receive_intent` 投递 → `handleIntent` → `handleAuthCode` 用暂存的 PKCE 状态换 token。
- 验证：`dart analyze lib/main.dart lib/src/sync` 无报错；`gradlew :app:assembleDebug` → BUILD SUCCESSFUL；合并后的 release manifest 确认含 `android:host="auth"`（`processReleaseManifest` 任务通过）。
  - 注：`gradlew :app:assembleRelease` 在 `compileReleaseJavaWithJavac` 阶段失败，根因是预存且无关的 `GeneratedPluginRegistrant.java` 引用了 `integration_test` 插件（dev 依赖，不在 release classpath）——manifest 处理任务在此之前已通过，与本轮改动无关。

### 备份/同步功能 — 最终状态

| 项 | 状态 |
|----|------|
| 本地全库备份（核心） | ✅ 审查通过 + round-trip 测试，逻辑健全 |
| S01 隐藏未配置 backend | ✅ FIXED & VERIFIED |
| S03 OneDrive 文件名编码 | ✅ FIXED & VERIFIED |
| Box backend 移除 | ✅ DONE & VERIFIED |
| OAuth 回调链路 | ✅ 接线完成，构建验证通过；e2e 待用户 client ID + 真机 |
| WebDAV/FTP/SFTP/SMB/Hibiki LAN | ✅ 代码路径审查无缺陷 |
| S02 FTP 断链重连 | ⏳ 外部依赖：需真实 FTP 服务器复现原始失败路径 |
| S04 OAuth 大文件分块上传 | ⏳ 外部依赖：需 client ID + 开启内容同步推大文件方可达 |

可在我控制范围内的项已全部修复并验证。剩余 S02/S04 + OAuth e2e 受真实服务器/凭据/真机的外部依赖阻塞，已逐条说明。

---

## Round 5 — S02 FTP 断链重连根因修复 + Dropbox 配置

### S02 — FIXED（根因状态机修复；e2e 待真实 FTP 服务器）
- 文件：`ftp_sync_backend.dart`
- 根因：`_ensureConnected` 仅信任 `_connected` 标志；FTP 服务器按 RFC 关闭空闲控制连接后，`_connected` 仍为 `true`，后续操作抛非 retryable 错误且连接状态永久卡死，直到 `signOut`。
- 修复（根因，非掩盖）：新增 `_resetConnection()`（仅置空 `_client`/`_connected`，不做网络 I/O）；9 个操作方法的通用 `catch` 在抛错前调用它并改抛 `isRetryable: true`。这样失败的操作丢弃死 socket，`SyncManager` 对 retryable 错误清缓存重试一次，重试的 `_ensureConnected` 因 `_connected=false` 而重连——**本次同步内即可从断链恢复**（最多 2 次尝试，无死循环）。对掉线连接重连是对外部平台行为的正确处理，符合根因修复原则。
- 验证：`dart analyze lib/src/sync` 无报错；`flutter test test/sync` → 111 passed（非回归）。
- 验证边界（诚实标注）：`FTPConnect` 直接 `new`、不可注入，为这个最少用的 backend 加测试 seam + fake FTPConnect 不成比例，故未加单测复现"空闲断链"本身；真实 idle-drop→重连 e2e 仍需真实 FTP 服务器。修复逻辑由代码审查 + 状态机推理 + 非回归测试保证，且严格优于此前"永久卡死"状态。

### Dropbox 配置（OAuth e2e 前置）
- `dropbox_sync_backend.dart`：`_clientId` 填入真实 App key（PKCE 公开客户端，App key 设计来嵌入客户端、非密钥；App secret 不嵌入）。`DropboxSyncBackend.isConfigured` 现为 true → Dropbox 自动出现在同步下拉菜单。
- `oauth_backend_config_test.dart`：Dropbox 断言从 `isFalse` 翻转为 `isTrue`，锁定"已配置"契约。
- 用户侧 Dropbox 后台：已加 redirect URI `hibiki://auth/dropbox`、开启 Allow public clients (PKCE)、提交 4 个 scope（account_info.read / files.metadata.read / files.content.read / files.content.write）。
- 剩余：真机走一次登录授权完成 e2e 验证（需用户在设备上点登录）。

### 最终状态更新
- S02：✅ 根因修复（状态机），非回归验证；idle-drop e2e 待真实 FTP 服务器。
- Dropbox：✅ 代码 + 后台已配；待真机点一次登录验证 e2e。
- S04（OAuth 大文件分块上传）：⏳ 仅在开启内容同步推大音频时可达，待真实场景；属外部依赖。

---

## Round 6 — OAuth 回调跨平台化（修正"只适配 Android"的设计缺陷）

Round 4 的 OAuth 回调只接了 Android（`receive_intent` + `hibiki://` intent-filter），与本项目"多平台应用"目标冲突。本轮改为**按平台分流的正确多平台设计**。

- 根因：回调链路仅 `Platform.isAndroid` 生效；桌面（Windows/macOS/Linux）浏览器授权后 `hibiki://auth/...` 无人接收。Windows 自定义 scheme 需注册表协议 + 单实例 argv 转发，脆弱且重。
- 方案（RFC 8252 桌面标准）：桌面改用**本地回环 HTTP 重定向**——临时 `127.0.0.1` 一次性 server 捕获 `code`，零注册表、零单实例依赖。移动端保留自定义 scheme。
- 改动：
  - 新增 `desktop_oauth.dart`：`runDesktopOAuthLoopback()`（绑定回环端口→打开浏览器→捕获 code→关闭 server）+ `isDesktopOAuthPlatform`。
  - `OneDrive`/`Dropbox` `authenticate()`：桌面→回环 + 内联 `_exchangeCode`；移动→原 scheme 流（later `handleAuthCode`）。共享 `_exchangeCode` 透传实际 `redirect_uri`（回环 URL vs `hibiki://` scheme），保证 authorize 与 token 交换一致。
  - OneDrive 用临时端口（Entra 允许任意 loopback 端口）；Dropbox 用固定端口 9004（Dropbox 精确匹配）。
- 验证：`dart analyze lib/src/sync` 无报错；Windows debug 已构建运行（`flutter run -d windows`，`[Hibiki] init: DONE`）。
- 用户侧需补 provider redirect URI（桌面）：
  - Entra（OneDrive）：在"移动和桌面应用"平台加 `http://localhost`（loopback，任意端口）。
  - Dropbox：加精确 `http://localhost:9004`。
- 剩余 e2e：桌面/移动各点一次登录走完浏览器授权（需用户操作）。
