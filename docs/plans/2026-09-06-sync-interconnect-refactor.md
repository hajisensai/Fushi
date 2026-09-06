# 同步 / 互联重构计划（A 消重 + B 拆巨类）

基线：`origin/develop`（开工前 fetch，worktree 起点显式写 `origin/develop`）。
目标目录：`fushi/lib/src/sync/`（112 文件 / 50.0k 行）。
铁律：**零行为变化**（wire / 偏好键 / manifest 字节 / 路由面 / 公开 API 语义全部冻结）；一簇一 PR，每 PR 独立可合。

## 冻结面（任何一条动了都是 bug）

- manifest canonical JSON 字节确定性：`collection_manifest.dart` / `video_manifest.dart` / `aggregate_snapshot.dart` / `sync_manifest_codec.dart`（orchestrator 靠字节相等跳过重写）。
- 远端保留名：`__aggregate__` `__collections__` `__dictionaries__` `__tombstones__` `__videos__` `__all__`；`collections.json` `videos.json` `manifest.json` `tags.json` `book_css.json` `manga.json` `backup_meta.json`；`.fushidict` / `.fushiaudio`。
- HTTP 面：`fushi_sync_server.dart:533-627` 全部 `/api/*` 路径 + WebDAV 动词（PROPFIND/PUT/MKCOL/DELETE/HEAD/OPTIONS）+ `yomitan_api_server.dart:304-336`；自定义头 `X-Hibiki-Book-Display-Title[-At]` / `X-Hibiki-Video-Title`。
- 偏好键：`sync_repository.dart:184-1024` 全部 `sync_*` / `interconnect_*`。
- DTO 线格式：`test/sync/remote_dto_wire_format_golden_test.dart` 是金样，动 DTO 必须金样不变。
- `SyncBackend` 抽象（40+ 成员，34 个 importer）与 `SyncRepository`（35 个 importer）签名不动。

## 守卫约束（拆/改名必须连带）

83 个源码扫描守卫钉了 58 个 sync 文件的路径字面量。本计划触碰的：

| 文件 | 钉它的守卫 |
|---|---|
| `backup_service.dart` | `test/media/db_source_pref_key_test.dart`、`test/sync/backup_device_local_leak_guard_test.dart`、`test/sync/backup_import_streaming_guard_test.dart`、`test/tools/fushi_rename_guard_test.dart` |
| `sync_orchestrator.dart` | `test/sync/interconnect_service_config_test.dart`、`server_lifecycle_appmodel_guard_test.dart`、`sync_audiobook_download_wiring_guard_test.dart`、`sync_progress_test.dart`、`test/tools/fushi_rename_guard_test.dart` |
| `fushi_sync_server.dart` | `test/sync/fushi_sync_server_asset_gate_test.dart`、`fushi_sync_server_hardening_test.dart`、`interconnect_profile_transfer_test.dart`、`interconnect_token_display_guard_test.dart`、`pairing/pin_no_plaintext_guard_test.dart` |
| `app_model_library_host_service.dart` | `test/media/audiobook/audio_reference_import_guard_test.dart`、`test/media/media_cover_write_guard_test.dart`、`test/pages/video_delete_reclaim_entry_guard_test.dart`、`test/sync/fushi_library_collections_test.dart` |

规则：代码挪到新文件后，守卫的扫描面必须**跟着挪**（改成扫新文件或扫多个文件），不能只让守卫"仍然能读到旧文件"就算过——那是守卫失效不是守卫通过。每个 PR 的验证项里逐条列出改了哪个守卫、改前故意破坏一次确认它仍会红。

---

## A. 消重（4 个 PR）

### A1. Dropbox ↔ OneDrive PKCE 外壳（PR 1）

**现状**：`dropbox_sync_backend.dart:119-224` ↔ `onedrive_sync_backend.dart:115-210` 五段近逐字：`handleAuthCode` / `_exchangeCode` / `restoreAuth` / `refreshAuth` / `_authHeaders`，外加 `_pendingVerifier`/`_pendingRepo`/`_accessToken`/`_refreshToken` 四个字段。两者已共享 `pkce_oauth.dart` 的 token 交换，但持久化 + 恢复 + 头拼装各写一份，且**两边零 OAuth 单测**（2026-07-24 审查 §三-1）。

**改法**：新增 `pkce_oauth_backend_mixin.dart`：
```dart
mixin PkceOAuthBackendMixin on SyncBackend {
  PkceOAuthFlow get oauth;                       // 各自的 client id / endpoint
  String get redirectUri;                        // 各自的 custom scheme
  Future<String?> loadStoredRefreshToken(SyncRepository repo);
  Future<void> storeRefreshToken(SyncRepository repo, String? token);
  Future<void> fetchUserEmail();                 // 各自 API 不同，保留抽象
  // 共享实现：handleAuthCode / exchangeCode / restoreAuth / refreshAuth /
  // bearerJsonHeaders；字段 accessToken / refreshToken / pendingVerifier / pendingRepo
}
```
- 两个后端各删五段 + 四字段，`signOut` 不合（Dropbox 有 revoke 调用，OneDrive 没有——这是真实差异）。
- 桌面 loopback 分支（`_startDesktopFlow` 类的东西）两边是否也逐字？实施时 diff 一次决定进不进 mixin；不进则明说。

**测试**：新增 `test/sync/pkce_oauth_backend_mixin_test.dart`——用 fake `PkceOAuthFlow`（子类覆写 `exchangeCode`/`refreshTokens`）覆盖：① exchangeCode 后 refresh token 落 repo；② restoreAuth 刷新失败 → 两个 token 清空、返回 false（HBK-AUDIT-159 的行为）；③ refresh 响应缺 refresh_token 时保留旧值；④ 无 pending flow 调 handleAuthCode 抛 `SyncAuthError`。这是补上审查点名的零覆盖，不是顺手加。

**爆炸半径**：`oauth_backend_config_test.dart` / `oauth_proxy_and_browser_timeout_test.dart` 定向重跑；无守卫钉这两个文件。

### A2. WebDAV 路径后端三件套（PR 2）

**现状**：`webdav_sync_backend.dart:116-175` ↔ `interconnect_sync_backend.dart:456-` 的 `listBooks` / `ensureBookFolder`（含封面上传）/ `listSyncFiles` 逐字相同，都打同一个 `WebDavOps`。interconnect 这三处**不**调 `_ensureResolved`（只 `findOrCreateRootFolder` :445 调），所以抽出来零时序变化。

**改法**：新增 `webdav_path_backend_mixin.dart`：
```dart
mixin WebDavPathBackendMixin on SyncBackend {
  WebDavOps get davOps;
  // listBooks / ensureBookFolder / listSyncFiles 共享实现（用 rootFolderIdCache / folderIdCache）
}
```
- `findOrCreateRootFolder` **不合**：webdav 有 Fushi 改名迁移三段，interconnect 没有，这是真实差异。
- sftp / ftp **不合**：原语不同（`listdir` vs `changeDirectory`+`listDirectoryContent`+`_opLock`+`_resetConnection`），硬合是 6 个抽象方法换 80 行，不值。计划里明说"审查报告 §三-2 的四后端 mixin 提案缩到两后端"。
- interconnect 其余 51 处 `_ensureResolved()` 一处不动。

**测试**：`webdav_metadata_in_book_folder_guard_test.dart` 若扫 `webdav_sync_backend.dart` 里的 `ensureBookFolder` 文本，改扫 mixin 文件。定向：`test/sync/webdav_*`、`interconnect_sync_backend*`、BUG-845 相关（`ensureFolderIdTrailingSlash`）。

### A3. 两台服务器的六条重复路由（PR 3）

**现状**：`fushi_sync_server.dart` 与 `yomitan_api_server.dart` 都服务 `/api/lookup/dictionary` `/api/lookup/audio` `/api/lookup/audio/file` `/api/mine` `/api/mine/forward` `/api/duplicate` `/api/extension/status` `/api/anki/note-type/{read,styling,templates}`。payload 已共享（`fushi_remote_api_handlers.dart` 的 `build*Response`），重复的是：JSON 读体 + 405 门 + 各 handler 壳 + **单词音频短命 token 存储**（`yomitan_api_server.dart:172` 自述"与 FushiSyncServer 同款模型"）。

**改法**：
1. 新增 `remote_audio_token_store.dart`：`RemoteAudioTokenStore`（mint / take / prune / 容量上限），两台服务器各删自己那份。
2. 新增 `remote_lookup_routes.dart`：`RemoteLookupRoutes`，构造注入 `FushiRemoteLookupService? / FushiRemoteMiningService? / RemoteAudioTokenStore / now`，暴露 `Future<shelf.Response?> tryHandle(shelf.Request, String method, String path)`——不是它的路径返回 null。两台服务器 `_handleRequest` 顶部先问它。
3. **鉴权不合**：sync server 是 Basic + peer token，yomitan 是 x-api-key 多来源；都留在各自 middleware。
4. 实施第一步是 **diff 两边六个 handler 的正文**——若发现语义分叉（如 yomitan 侧有 `_onExtensionSeen` / `_onLookupActivity` 副作用），分叉部分留在调用方钩子里，不悄悄统一。

**测试**：`yomitan_api_server_test.dart`（4 个文件）+ `fushi_sync_server_*`（含 asset_gate / hardening）定向重跑；`fushi_sync_server_hardening_test` 若断言音频 token 上限/过期文本，改扫 store 文件。

### A4. 五个后端的重试层——先查再定（不单独 PR）

**现状**：只有 Google Drive 有 `retryTransientSync` 包裹（`google_drive_handler.dart:136`）；ftp 抛 `SyncBackendError(isRetryable: true)`。

**门槛**：grep `isRetryable` 的消费方。若 `sync_orchestrator` / `sync_auto_trigger` 已在 op 层重试 → 后端层再包 = 双重重试（4×4），**不加**，只在 A2 的 PR 描述里记一句结论。若无人消费 → 那是独立 bug（"transient 错误一次即败"），走 `dart run tool/bug.dart new` 开 BUG 单另做，**不混进重构 PR**（它是行为变化）。

---

## B. 拆五个巨类（4 个 PR，每类一 PR）

拆分手法统一用本仓库既有习惯——**`part` 文件**（`reader_fushi/` 8 个 part、`video_fushi/` 18 个 part 都是这么做的）：类不变、私有字段共享、公开 API 零变化、调用方零改动。真正按职责拆成独立类只在"职责之间没有共享私有状态"时做（B1 的备份是这种；B2/B3/B4 不是）。

### B1. `backup_service.dart` 4625 行 → 导出 / 恢复分家（PR 4）

**现状**：`BackupService` 一个纯 static 类 ~150 方法、≥9 种关心点，导出与导入/合并同住。对外 12 个方法名、~27 个调用点（`createBackup`×4、`restoreBackup`×4、`mergeRestoreBackup`×6、`recoverPendingRestore`×4、`previewMergeRestore`×2，其余各 1）。

**切法**（按调用方向，不按"看起来像"）：
| 去向 | 内容 |
|---|---|
| `backup_service.dart`（保留名，导出侧） | `BackupCategory` / `BackupMeta` / `BackupContentSummary` / `createBackup` / `validateBackup` / `summarizeBackupFile` / `defaultFilename` / `settingsPrefPredicate` / `archiveBooksPrefix`；私有：DB VACUUM/复制、isolate 写 ZIP、剥密钥（`_stripCredentials*`）、按类别删行（`_stripExcludedDataCategories` / `_stripOrphanUserDataTables`） |
| `backup_restore_service.dart`（新，`BackupRestoreService`） | `restoreBackup` / `mergeRestoreBackup` / `previewMergeRestore` / `recoverMergeRestore` / `recoverPendingRestore` / `importBackupFiles` / `mergeImportBackupFiles` / `previewMergeImport` / `recoverMergeImport` / `recoverPendingImport`；私有：流式解包、设备本地表回填、崩溃恢复 |
| `backup_path_rebase.dart`（新，顶层函数） | `_rebase*` 五族（书/视频/字体/本地音频/播放列表，:3896-4284）——纯函数、无状态，是最干净的一刀 |
| `backup_fs_retry.dart`（新，顶层函数） | `deleteDirectoryWithRetry` / `renameDirectoryWithRetry` |

- **两侧都用的私有 helper** → 放 `backup_common.dart` 顶层函数并公开（加 `@internal` 语义注释），不允许一份留 export 一份复制到 restore。
- 调用点直接改到新类名，**不留 `BackupService.restoreBackup` 转发外壳**。
- `_BackupExtractRequest` 跟流式解包走。

**守卫**：4 个（见上表）逐个看它扫什么：`backup_device_local_leak_guard`（设备本地表回填 → 跟 restore 走）、`backup_import_streaming_guard`（流式解包 → 跟 restore 走）、`db_source_pref_key`（看它扫的符号在哪侧）、`fushi_rename_guard`（只是文件名列表，加新文件）。`backup_delete_retry_test` / `backup_rename_retry_test` 改 import。

**测试**：`test/sync/backup_*`（≥5 个大文件，最大 1600 行）全部定向重跑 + `test/tools/`。

### B2. `sync_orchestrator.dart` 3335 行 → 按域 part（PR 5）

**现状**：一个类 ~50 方法，每域一对 `syncX`（云）/`_syncXLive`（互联）；10 个 `@visibleForTesting …ForTest` 纯转发（:788-3025）。

**改法**：`sync_orchestrator/` 下 part：`books.part.dart`、`book_progress.part.dart`、`videos.part.dart`、`audiobooks.part.dart`、`local_audio.part.dart`、`dictionaries.part.dart`、`collections.part.dart`、`tombstones.part.dart`、`aggregate.part.dart`；主文件留构造、字段、sweep 驱动（`runSync` 类的入口）、`SyncConflict` / `SyncRunReport` / `SyncAuthFailure` 等值类型（或把值类型移 `sync_run_report.dart`，看 importer 数决定）。

- **不**做"每域一个类 + `SyncContext`"：那是重写，~15 个共享字段要么塞 context 对象要么构造爆炸，在 3335 行、上百测试覆盖的核心上风险与收益不成比例。这条作为拆完 part 之后**可选**的第二步，本计划不做。
- `…ForTest` 10 个：逐个看，纯转发（`syncXLiveForTest(a) => _syncXLive(a)`）的删掉、把 `_syncXLive` 改公开 `syncXLive` + `@visibleForTesting`；带默认参数填充的保留。测试调用点用 sed 批改（实施时先 grep 计数，写进 PR 描述）。

**守卫**：5 个（见上表），`server_lifecycle_appmodel_guard` 可能扫"不 import AppModel"——part 文件继承主文件 import，守卫改成扫目录。

### B3. `fushi_sync_server.dart` 3194 行 → 抽认证 / 配对 / WebDAV / 流 token（PR 6）

**现状**：八合一（路由链 / 认证 / 配对状态机 / 临时 token / 库 REST / Range 流 / WebDAV / TLS）。构造注入 5 个服务 + SecurityContext。

**改法**（这四块没有共享私有状态，可以真拆成类；库 REST 与 server 共享 `_libraryService` 等字段，用 part）：
| 去向 | 内容 |
|---|---|
| `fushi_server_auth.dart`（新，`FushiServerAuthenticator`） | `_validateAuth` / `_validatePeerAuth` / `_basicPassword` / `_peerTokens` 缓存 / `invalidatePeerTokenCache` / `_constantTimeEquals`（:444-528） |
| `fushi_server_pairing.dart`（新，`FushiPairingHandler`） | `_handlePair` / `_handlePairV2` / `_handlePairConfirm` / `_pairSessions` / `FushiPinRateLimiter` 持有 / `_prunePairSessions` / `onPairRequest` / `onPairPinGenerated` 回调（:693-900, :2672） |
| `fushi_server_dav.dart`（新，`FushiDavHandler`） | 路径穿越围栏 + `_serializeDavWrite` 写链 + PROPFIND/GET/PUT/MKCOL/DELETE/HEAD/OPTIONS + XML 转义（:630-680, :2706-2862） |
| `remote_audio_token_store.dart`（A3 已建）+ `fushi_server_stream_tokens.dart` | `_RemoteAudioToken` 并入 store；`_VideoStreamToken` 同型另建 `VideoStreamTokenStore`（:2353-2670）；Range 解析 `ByteRange` 随流走 |
| `fushi_sync_server/library_*.part.dart` | `_handleLibraryDictionaries` / Books / LocalAudio / Audiobooks / Videos / Aggregate / Activity / Collections（:1411-2609） |
| 主文件 | 构造、生命周期（bind/close/TLS）、middleware 装配、`_handleRequest` 分发链、`FushiPairRequest` / `FushiPairedPeerRegistration` / `SyncServerPortInUseException` 等公开类型 |

- `_handleRequest` 的 30 臂 if 链：抽完后剩 ~15 臂，改成"精确匹配 map + 前缀列表"两张表，**匹配顺序按现状逐条保留**（精确先、前缀按声明序）。
- `fushi_server_controller.dart` 调 `invalidatePeerTokenCache` 等 → 经 server 转发到 authenticator（这是 server 的公开 API，不动签名）。

**守卫**：`pin_no_plaintext_guard_test`（配对 PIN 不明文 → 改扫 `fushi_server_pairing.dart`）、`interconnect_token_display_guard`（token 显示 → 看扫哪段）、`hardening_test`（token 上限/TTL → store 文件）、`asset_gate_test`、`interconnect_profile_transfer_test`。本文件是并发热点（源码里自述"本文件是共享热点"），**这条 PR 开工前 fetch、完工当天合**，不隔夜。

### B4. `app_model_library_host_service.dart` 2079 行 → 改名 + 按域 part（PR 7）

**现状**：一个类 implements 7 个接口；名字里的 `AppModel` 是谎言——它不 import `app_model.dart`，状态经 17 个回调注入。与 `fushi_library_host_service.dart` 是接口/实现关系，不是重复。

**改法**：
- 改名 `LocalLibraryHostService`，文件 `local_library_host_service.dart`（"host" 是术语表定案词，"local" 不在淘汰表）。
- `local_library_host_service/` 下 part 按接口/域：`books.part.dart`、`videos.part.dart`（含 sidecar 字幕发现 + ffmpeg 封面）、`audiobooks.part.dart`、`local_audio.part.dart`、`dictionaries.part.dart`、`collections.part.dart`、`tombstones.part.dart`、`aggregate.part.dart`、`profile.part.dart`。7 个接口保留（它们是消费方契约）。
- `fushi_library_host_service.dart`（1987 行 DTO + 接口）**不拆**：它是 23 个 importer 的公开面，1620 行 DTO 只是长不是混，且金样已钉。

**守卫**：4 个（上表）改路径；`app_model.dart` 与全仓 importer 改类名（实施时 grep 计数）。

### B5. `fushi_library_host_service.dart` — 明确不做

理由见 B4。

---

## PR 顺序与合并纪律

```
PR1 A1 OAuth mixin        独立
PR2 A2 WebDAV mixin       独立
PR3 A3 路由 + token store  独立           ─┐
PR6 B3 sync_server 拆      依赖 PR3（store） ─┘ 串行
PR4 B1 backup 分家         独立
PR5 B2 orchestrator part   独立
PR7 B4 host service 改名   独立
```
- 每 PR：`dart format`（**新文件用 `--language-version=3.6`，存量文件只 format 改动行、绝不整文件**，本机 3.44 是 tall style）→ 全量 `flutter analyze`（含 test）→ 定向 `flutter test <目标> --no-pub` → 守卫整批（51 条目录枚举型）→ 合入前 `dart run tool/flutter_test_failures.dart --no-pub --output-dir <私有目录>` 只认 `FLUTTER TEST VERDICT` 行。
- 挪代码 PR 的自检：`git diff --stat` 删行 ≈ 加行（±新 mixin/类的声明开销）；多出来的加行逐条解释。
- 每 PR 开工前 `git fetch` + 从 `origin/develop` 切，完工当天合；不在 `fushi_sync_server.dart` 这种热点上隔夜。
- 不 bump 版本号（纯重构、不发版）。

## 风险

1. **守卫失效比守卫红更危险**：挪走代码后旧守卫扫旧文件仍"通过"（扫描面空了）。每个 PR 对改过的守卫做一次"故意破坏 → 红 → 还原"。
2. **A3 的 handler 可能已语义分叉**：先 diff 再合，分叉留钩子，不悄悄统一。
3. **并发 agent 冲突**：`fushi_sync_server.dart` / `sync_orchestrator.dart` 是高频修改文件，part 拆分会与任何在途 PR 冲突。开工前 `gh pr list` 看有没有在途 PR 碰这两个文件；有就等它合完再拆。
4. **`ForTest` 清理的 180 文件 grep 命中是全仓的**，实施时只改 orchestrator 那 10 个的调用方，其余不碰。
