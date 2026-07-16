## BUG-845 · WebDAV book folderId 缺尾斜杠致进度文件溢出根目录并删除对端 in-folder 副本

- **报告**：2026-07-16（用户复报：「webdav 同步数据，手机端这本书还是坏的会同步到文件外，依旧会把平板端这本书正常同步到文件夹内的文件给清掉」，附真机截图 `hibiki-data/屍人荘の殺人`）。BUG-619 / BUG-653（TODO-1329/1340）修过「空 title 溢出」，用户复报仍溢出且删对端。
- **真实性**：✅ 真 bug，且是 BUG-619/653 未覆盖的**另一条溢出源**。截图关键新信号：溢出文件名是 `屍人荘の殺人audioBook_1_6_<ts>_<pos>.json`（**书名前缀 + audioBook 名连体**，97 B，时间戳每次变、堆多份），不是 BUG-619 的裸 `audioBook_1_6_*`。

### 根因

路径式后端把 per-book folderId 当**裸路径前缀**用：子文件地址 = `folderId + Uri.encodeComponent(fileName)`，**不插分隔符**（`webdav_ops.dart:222` `uploadJson`；`webdav_sync_backend.dart:216` `uploadContentFile` / `:269` `findContentFile`）。所以 folderId **必须以 `/` 结尾**，否则 `folderId + fileName` 会把两者**粘连**成书文件夹的兄弟：`<root>/屍人荘の殺人` + `audioBook_1_6_….json` → `<root>/屍人荘の殺人audioBook_1_6_….json`，文件落到**同步根**、书名黏在文件名前。

`ensureBookFolder` 在**创建**文件夹时拼的是带尾斜杠的 `<root>/<sanitized>/`（`webdav_sync_backend.dart:109`），但 folderId 还有另外两条**不带斜杠**的入缓存路径：
- `cacheBookFolderIds(listBooks(...))`（`webdav_sync_backend.dart:301`）：`listBooks` 存 `DriveFile(id: e.href)`（`:93`），href 来自 PROPFIND；**部分 WebDAV 服务器（坚果云 / Nutstore 等）对 collection href 不带尾斜杠**。调用点在同步比较弹窗 `sync_compare_dialog.dart:167` / 远端书客户端 `cloud_remote_book_client.dart:65`。
- `restoreCache(getFolderCache())`（`webdav_sync_backend.dart:283` ← `sync_manager.dart:_restoreDriveCache`）：无尾斜杠的 id 经 `sync_repository.dart:139 setFolderCache`（jsonEncode 原样入 `preferences.sync_folder_cache`）**往返持久化**，重启后再灌回。

`ensureBookFolder` 命中缓存时**原样返回**缓存值（`webdav_sync_backend.dart:105-107`），没规范化。于是 folderId 无尾斜杠 → 每次导出：
1. `updateAudioBookFile`（`:195`）先 `uploadJson(folderId, fileName)` 把新 audioBook 写到 `<root>/屍人荘の殺人audioBook_….json`（**根 · 连体名 · 错位**）；
2. 再 `deleteFile(fileId)`，而 `fileId` 来自 `listSyncFiles(folderId)`（`sync_manager.dart:280`）在书文件夹内拾到的**对端（平板）正常 in-folder 副本**——PROPFIND 不带尾斜杠也能解析该 collection，照样列出并删。
→ 净效果：**对端 in-folder 正常文件被删，根目录多一份连体孤儿**；audioBook 名带 `DateTime.now()` 每次变 + `findSyncFileByPrefix` 单文件去重 → 根里连体孤儿**堆多份**（「丢很多份」）。互联后端 `HibikiClientSyncBackend`（复用 `WebDavOps` 同款连体 concat）结构同型（其 server 通常回带斜杠 href，暴露面较低）。其余后端安全：ftp/sftp/dropbox 用显式 `/` 分隔、onedrive/google_drive 用不可变 item id + parent 引用，均不做裸路径粘连。

- 既有 `pruneRootSpill`（BUG-653）用 `isTtuPerBookFileName`**先头锚 `^audioBook_1_6_`**，**匹配不到**书名前缀的 `屍人荘の殺人audioBook_1_6_…`，历史残留永不清。

### 修复

- **[x] ① 已修复** — 分支 `worktree-webdav-folder-slash-spill`（commit 见末）。防御纵深，令不变量「缓存里每个 folderId 都以 `/` 结尾」**由构造保证**：
  1. 新增单一归一函数 `ensureFolderIdTrailingSlash(folderId)`（`sync_backend.dart`）：缺尾斜杠则补。
  2. `WebDavSyncBackend` + `HibikiClientSyncBackend` 三处入缓存点全归一：`cacheBookFolderIds`（服务器 href 入口）、`restoreCache`（毒持久化 id 入口，**顺带自愈老用户已污染的 `sync_folder_cache`**，含 rootFolderId）、`ensureBookFolder` 命中缓存的返回值（兜底）。`evictFolderId` 比较入参也先归一，避免尾斜杠差异漏逐出。写入源头（`updateAudioBookFile`/`uploadContentFile`）不再可能收到无斜杠 folderId → 不再溢出、不再误删对端 in-folder 副本。
  3. 残留自愈：`ttu_filename.dart` 的 spill 谓词 `_ttuPerBookFilePattern` 去掉先头锚 `^`（改 `(?:progress|statistics|audioBook|cover)_1_6[._]` 任意位置匹配），令 `pruneRootSpill` 同时清掉裸（BUG-619）与**书名前缀**（本 bug）两形态的根残留；`type_1_6[._]` 标记足够特异，只 Hibiki per-book 文件带它，且调用方仍要求「非文件夹的根直接子项」（`sync_orchestrator.dart:1999` `e.isFolder` 守卫在前），书文件夹/保留 namespace 绝不误删。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/sync/sync_folder_id_slash_test.dart`（新）：`ensureFolderIdTrailingSlash` 纯函数；`WebDavSyncBackend` / `HibikiClientSyncBackend` 用无斜杠 href 喂 `cacheBookFolderIds` / `restoreCache` → `cachedFolderIds` / `cachedRootFolderId` 均带尾斜杠；`ensureBookFolder` 命中缓存返回带斜杠，且模拟 `folderId + audioBookFileName(...)` 落在书文件夹**内**（含 `/audioBook_`）、**不**粘连成 `屍人荘の殺人audioBook_`（根溢出）。
  - `hibiki/test/sync/sync_root_spill_prune_test.dart`（扩）：谓词组加书名前缀四型命中 + 近似负例（`屍人荘の殺人progression.json` 仍 false）；新增 `pruneRootSpill` 用例：书文件夹完好，根里多份书名前缀 audioBook + cover 全清（`rootSpillFilesRemoved==3`）、in-folder 合法文件不动。既有 BUG-619 裸溢出用例 + TODO-1346 文件夹/本地 DB 安全守卫全绿（去锚不改其判定）。
  - `flutter analyze` 5 个改动 lib 文件 0 issue；`flutter test test/sync/sync_folder_id_slash_test.dart test/sync/sync_root_spill_prune_test.dart test/sync/ttu_filename_test.dart` 38 例全绿。

- **备注**：
  - **待真机双设备验收（用户 WebDAV/坚果云）**：手机 + 平板同账户 → 触发有声书进度同步 → 云盘文件浏览器确认：`hibiki-data/` 根下不再新增 `<书名>audioBook_1_6_*` 连体文件；书文件夹 `hibiki-data/屍人荘の殺人/` 内 `audioBook_*.json` 正常更新且**不再被对端删**；已升级到本包并跑过一次同步后，历史根残留（含连体多份）被 `pruneRootSpill` 清空。
  - `test/sync/sync_settings_visibility_test.dart` 的 `auto-sync is gated on the hosting role` 一例在**本分支 base（develop `bb66190c3`）即失败**（`sync.content` gating，与本改动无关，已 stash 本改动复核确认），非本次引入。
