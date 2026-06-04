# Sync Compare 远端删除（书籍/词典/有声书逐行删除）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 sync compare data 对话框里，给每一行书籍、词典、有声书都加一个删除按钮，删除「远端」那一份数据（本地保留），所有 7 个同步后端都支持。

**Architecture:** 在资产存取抽象层 `SyncAssetStore` 新增唯一一个幂等删除原语 `deleteAsset(id, {isFolder})`，云后端（Drive/OneDrive/Dropbox/WebDAV/Hibiki server）天然递归删，FTP/SFTP 文件夹手动递归。compare 对话框把远端定位符（书籍文件夹 id、有声书资产 id、词典资产 id）透传到 UI，新增「词典」分组，并在每行挂一个 focus-safe 的 `HibikiOverflowMenu` 删除动作 + 删除确认。

**Tech Stack:** Dart / Flutter 3.44.0；Riverpod；Slang i18n（17 语言，经 `tool/i18n_sync.dart`）；测试用 `FakeAssetStore` + 新建最小 `_FakeSyncBackend`。

---

## 关键事实（动手前必读）

- compare 对话框文件：`hibiki/lib/src/sync/sync_compare_dialog.dart`，对话框 `_SyncCompareDialog`（构造注入 `SyncBackend backend`，可测）。当前**只列书籍**，每行一本书；`__dictionaries__` 被 `isReservedSyncFolderName` 显式排除。
- 资产抽象：`hibiki/lib/src/sync/sync_asset_store.dart`（`SyncAssetStore` / `AssetEntry`）。`SyncBackend`（`sync_backend.dart`）`implements SyncAssetStore`，7 个后端各自实现。
- `AssetEntry.id` 语义随后端而变：Drive/OneDrive=不透明 id；WebDAV=绝对 href；Dropbox/FTP/SFTP=路径串；Hibiki client=服务端路径 id。**对调用方不透明**——UI 只透传，不解析。
- 各后端现有删除能力（均为私有或仅文件级）：
  - Google Drive：**完全没有** delete。`GoogleDriveHandler`（`google_drive_handler.dart`）持有 `drive.DriveApi`，经 `_call<T>(fn)` 调用，要新增 `deleteFile(fileId)` → `api.files.delete(fileId)`（Drive 删文件夹即递归删内容）。
  - WebDAV：`WebDavOps.deleteFile(path)`（`webdav_ops.dart:228`，public，DELETE，对 collection 递归）。
  - Hibiki client：`_ops!.deleteFile(fileId)`（`hibiki_client_sync_backend.dart:301`），服务端 `_handleDelete`（`hibiki_sync_server.dart:502`）对目录 `delete(recursive: true)`、对文件 `delete()`，**递归已具备**。
  - OneDrive：`_deleteItem(fileId)`（`onedrive_sync_backend.dart:723`）→ `_graphDelete('/me/drive/items/$fileId')`，Graph 删文件夹递归。
  - Dropbox：`_deleteFile(path)`（`dropbox_sync_backend.dart:737`）→ `/files/delete_v2`，删文件夹递归。
  - FTP：`_deleteRemoteFileImpl(fileId)`（`ftp_sync_backend.dart:734`）**只删文件**。删文件夹要递归：`listChildren` → 删文件 + 递归子目录 → `_client.deleteDirectory(name)`（`ftpconnect` 的 `FTPConnect.deleteDirectory` 递归删目录）。
  - SFTP：`_deleteIfExists(sftp, path)`（`sftp_sync_backend.dart:632`，`sftp.remove`）**只删文件**。删文件夹要递归：`sftp.listdir` → 删文件 + 递归子目录 → `sftp.rmdir(path)`（`dartssh2`）。
- 词典远端命名空间：`kSyncDictionaryNamespace = '__dictionaries__'`，资产名 `<name>.hibikidict`（`sync_orchestrator.dart:16/23`）。本地词典：`db.getAllDictionaryMetadata()` → `DictionaryMetaRow.name`。
- 有声书远端：每本书文件夹内的 `audiobook.hibikiaudio`（`kSyncAudiobookAssetName`），其 `AssetEntry` 来自 `listSyncFiles(folderId).audioBook`（当前 `_fetchRemoteBookData` 丢弃了它的 id，要补上）。
- i18n：**禁止手改 json**，用 `dart run hibiki/tool/i18n_sync.dart --add <key> <en> <zh>`，再 `dart run slang` + `dart format` 生成文件。复用现成键 `t.dialog_delete` / `t.dialog_cancel`。
- 删除远端是**不可逆的外部副作用**——每个删除动作必须先弹确认框。
- 焦点纪律：每行删除入口用 `HibikiOverflowMenu`（已是 focus-registered，header 在用），**不要**用裸 `IconButton`（gamepad/键盘导航会落不进去，参见 `_choiceRow` 的注释）。
- 测试运行：`cd hibiki && flutter test --no-pub <path>`（本机工具链路径若不在 PATH，见 `CLAUDE.local.md`）。

---

## File Structure

| 文件 | 改动 | 责任 |
|---|---|---|
| `hibiki/lib/src/sync/sync_asset_store.dart` | Modify | 接口加 `deleteAsset` |
| `hibiki/lib/src/sync/google_drive_handler.dart` | Modify | 加 `deleteFile(fileId)` |
| `hibiki/lib/src/sync/google_drive_sync_backend.dart` | Modify | 实现 `deleteAsset` |
| `hibiki/lib/src/sync/webdav_sync_backend.dart` | Modify | 实现 `deleteAsset` |
| `hibiki/lib/src/sync/hibiki_client_sync_backend.dart` | Modify | 实现 `deleteAsset` |
| `hibiki/lib/src/sync/onedrive_sync_backend.dart` | Modify | 实现 `deleteAsset` |
| `hibiki/lib/src/sync/dropbox_sync_backend.dart` | Modify | 实现 `deleteAsset` |
| `hibiki/lib/src/sync/ftp_sync_backend.dart` | Modify | 实现 `deleteAsset`（文件夹递归） |
| `hibiki/lib/src/sync/sftp_sync_backend.dart` | Modify | 实现 `deleteAsset`（文件夹递归） |
| `hibiki/lib/src/sync/sync_compare_dialog.dart` | Modify | 透传远端 id + 词典分组 + 删除 UI |
| `hibiki/test/sync/fake_asset_store.dart` | Modify | `FakeAssetStore.deleteAsset` |
| `hibiki/test/sync/sync_asset_store_contract.dart` | Modify | 删除契约用例 |
| `hibiki/test/sync/sync_compare_delete_test.dart` | Create | 对话框删除 widget 测试 |
| `hibiki/lib/i18n/strings*.i18n.json` + `strings.g.dart` | Modify（经工具） | 新 i18n 键 |

---

## Phase 1：删除原语（接口 + Fake + 契约）

### Task 1：`SyncAssetStore.deleteAsset` 接口

**Files:**
- Modify: `hibiki/lib/src/sync/sync_asset_store.dart`

- [ ] **Step 1：在 `SyncAssetStore` 末尾（`putJsonAsset` 之后、类闭合 `}` 之前）加方法声明**

```dart
  /// 删除 [id] 指向的资产或命名空间。[isFolder] 为 true 时按"文件夹"语义递归删除
  /// 其下全部内容。幂等：目标不存在视为成功（不抛）。
  ///
  /// 删除是不可逆的远端副作用，调用方必须已向用户确认。
  Future<void> deleteAsset(String id, {bool isFolder = false});
```

- [ ] **Step 2：确认编译失败面**

Run: `cd hibiki && flutter analyze lib/src/sync/sync_asset_store.dart`
Expected: 接口本身通过；但全工程 analyze 会因 7 个后端 + FakeAssetStore 未实现该抽象方法报错（这是预期，后续 Task 补齐）。先不全量 analyze。

- [ ] **Step 3：提交**

```bash
git add hibiki/lib/src/sync/sync_asset_store.dart
git commit -m "feat(sync): add deleteAsset primitive to SyncAssetStore"
```

### Task 2：`FakeAssetStore.deleteAsset` + 契约测试

**Files:**
- Modify: `hibiki/test/sync/fake_asset_store.dart`
- Modify: `hibiki/test/sync/sync_asset_store_contract.dart`

- [ ] **Step 1：先写契约测试（失败）**

打开 `hibiki/test/sync/sync_asset_store_contract.dart`，找到它定义契约用例的 `group`/函数（它对传入的 `SyncAssetStore Function()` 工厂跑一组 `test(...)`）。在该组末尾追加：

```dart
    test('deleteAsset removes a file (idempotent)', () async {
      final store = makeStore();
      final ns = await store.ensureNamespace('books');
      final tmp = await _writeTemp('hello');
      await store.putAsset(ns, 'a.txt', tmp);
      expect(await store.findAsset(ns, 'a.txt'), isNotNull);

      final asset = (await store.findAsset(ns, 'a.txt'))!;
      await store.deleteAsset(asset.id);
      expect(await store.findAsset(ns, 'a.txt'), isNull);

      // Idempotent: deleting again does not throw.
      await store.deleteAsset(asset.id);
    });

    test('deleteAsset removes a folder recursively', () async {
      final store = makeStore();
      final ns = await store.ensureNamespace('books');
      final sub = await store.ensureFolder(ns, 'bookA');
      final tmp = await _writeTemp('content');
      await store.putAsset(sub, 'content.epub', tmp);

      await store.deleteAsset(sub, isFolder: true);
      final children = await store.listChildren(ns);
      expect(children.where((c) => c.name == 'bookA'), isEmpty);
    });
```

> 若该文件没有 `makeStore` / `_writeTemp` 这类既有 helper，用文件里实际的工厂名与临时文件写法（读文件确认；多数契约文件已有 `Directory.systemTemp` 写临时文件的 helper）。

- [ ] **Step 2：跑测试确认失败**

Run: `cd hibiki && flutter test --no-pub test/sync/fake_asset_store_test.dart`
Expected: FAIL —— `FakeAssetStore` 未实现 `deleteAsset`（编译错误）。

- [ ] **Step 3：实现 `FakeAssetStore.deleteAsset`**

在 `hibiki/test/sync/fake_asset_store.dart` 的 `putJsonAsset` 之后加：

```dart
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    // 文件资产：直接移除。
    _files.remove(id);
    if (isFolder) {
      // 递归移除该命名空间及其全部子项（路径前缀匹配）。
      final String prefix = '$id/';
      _folders.removeWhere((String f) => f == id || f.startsWith(prefix));
      _files.removeWhere((String k, List<int> _) => k.startsWith(prefix));
    }
  }
```

- [ ] **Step 4：跑测试确认通过**

Run: `cd hibiki && flutter test --no-pub test/sync/fake_asset_store_test.dart test/sync/sync_asset_store_contract.dart`
Expected: PASS

- [ ] **Step 5：提交**

```bash
git add hibiki/test/sync/fake_asset_store.dart hibiki/test/sync/sync_asset_store_contract.dart
git commit -m "test(sync): cover deleteAsset contract in FakeAssetStore"
```

---

## Phase 2：7 个后端实现 `deleteAsset`

> 每个 Task 改一个后端，改完单独 analyze 该文件；7 个全改完再全量 analyze。

### Task 3：Google Drive

**Files:**
- Modify: `hibiki/lib/src/sync/google_drive_handler.dart`
- Modify: `hibiki/lib/src/sync/google_drive_sync_backend.dart`

- [ ] **Step 1：`GoogleDriveHandler` 加 `deleteFile`**

在 `google_drive_handler.dart` 类内（与其它 `_call` 包裹的方法并列）加：

```dart
  /// 永久删除 [fileId]（文件或文件夹；文件夹递归删内容）。不存在时 Drive 返回 404，
  /// 由调用方按幂等吞掉。
  Future<void> deleteFile(String fileId) async {
    await _call<void>((api) => api.files.delete(fileId));
  }
```

- [ ] **Step 2：`GoogleDriveSyncBackend` 实现 `deleteAsset`**

在 `google_drive_sync_backend.dart` 的 Cache 区或 asset 区附近加（`@override`）：

```dart
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _wrapVoidErrors(() async {
        // Drive 删文件夹即递归删内容，文件/文件夹同一 API；isFolder 无需分支。
        try {
          await _drive.deleteFile(id);
        } on GoogleDriveError catch (e) {
          if (e.isNotFoundError) return; // 幂等：已不存在
          rethrow;
        }
      });
```

> 确认 `GoogleDriveError` 有 `isNotFoundError`（或类似 404 判别）。若没有，用其现有的 404 判别字段；都没有就 `catch (_) {}` 吞 404 之外的也兜底但记 `developer.log`（次选）。先读 `google_drive_handler.dart` 里 `GoogleDriveError` 定义确认。

- [ ] **Step 3：analyze**

Run: `cd hibiki && flutter analyze lib/src/sync/google_drive_handler.dart lib/src/sync/google_drive_sync_backend.dart`
Expected: 无新错误。

- [ ] **Step 4：提交**

```bash
git add hibiki/lib/src/sync/google_drive_handler.dart hibiki/lib/src/sync/google_drive_sync_backend.dart
git commit -m "feat(sync): Google Drive deleteAsset"
```

### Task 4：WebDAV

**Files:**
- Modify: `hibiki/lib/src/sync/webdav_sync_backend.dart`

- [ ] **Step 1：实现 `deleteAsset`**（`_ops!.deleteFile` 的 DELETE 对文件与 collection 都递归）

```dart
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    await _ensureClient();
    try {
      await _ops!.deleteFile(id); // DELETE 对 collection 递归
    } catch (e) {
      // 幂等：404/已删除当作成功。其它错误按后端约定包装/吞。
      developer.log('WebDAV deleteAsset failed: $id',
          error: e, name: 'WebDavSync');
    }
  }
```

> 确认文件顶部已 import `dart:developer as developer`；没有就加。`_ensureClient()` 用文件里实际的连接确保方法名（读文件确认，可能叫 `_ensureAuthenticated` 之类）。

- [ ] **Step 2 / 3：analyze + 提交**

```bash
cd hibiki && flutter analyze lib/src/sync/webdav_sync_backend.dart
git add hibiki/lib/src/sync/webdav_sync_backend.dart
git commit -m "feat(sync): WebDAV deleteAsset"
```

### Task 5：Hibiki client（服务端已支持递归 DELETE）

**Files:**
- Modify: `hibiki/lib/src/sync/hibiki_client_sync_backend.dart`

- [ ] **Step 1：实现 `deleteAsset`**

```dart
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    await _ensureOps();
    try {
      await _ops!.deleteFile(id); // 服务端 _handleDelete 对目录 recursive 删
    } catch (e) {
      developer.log('Hibiki client deleteAsset failed: $id',
          error: e, name: 'HibikiClientSync');
    }
  }
```

> `_ensureOps()` 用文件里实际确保 `_ops` 已就绪的方法名（读文件确认；可能在每个 op 开头调用同一个 helper）。确认 `developer` 已 import。

- [ ] **Step 2 / 3：analyze + 提交**

```bash
cd hibiki && flutter analyze lib/src/sync/hibiki_client_sync_backend.dart
git add hibiki/lib/src/sync/hibiki_client_sync_backend.dart
git commit -m "feat(sync): Hibiki client deleteAsset"
```

### Task 6：OneDrive

**Files:**
- Modify: `hibiki/lib/src/sync/onedrive_sync_backend.dart`

- [ ] **Step 1：实现 `deleteAsset`**（`_deleteItem` → Graph DELETE，文件夹递归；id 为 item id）

```dart
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    try {
      await _deleteItem(id);
    } catch (e) {
      developer.log('OneDrive deleteAsset failed: $id',
          error: e, name: 'OneDriveSync');
    }
  }
```

> 注意：`AssetEntry.id` 对 OneDrive 是不透明 item id（`listChildren` 产出的）。`_deleteItem` 接收的就是 item id，匹配。确认 `developer` 已 import。`_graphDelete` 已对 404 容忍则更好；否则此处 catch 兜底幂等。

- [ ] **Step 2 / 3：analyze + 提交**

```bash
cd hibiki && flutter analyze lib/src/sync/onedrive_sync_backend.dart
git add hibiki/lib/src/sync/onedrive_sync_backend.dart
git commit -m "feat(sync): OneDrive deleteAsset"
```

### Task 7：Dropbox

**Files:**
- Modify: `hibiki/lib/src/sync/dropbox_sync_backend.dart`

- [ ] **Step 1：实现 `deleteAsset`**（`_deleteFile` → `/files/delete_v2`，删文件夹递归；id 为路径）

```dart
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) async {
    try {
      await _deleteFile(id); // delete_v2 对文件夹递归
    } catch (e) {
      developer.log('Dropbox deleteAsset failed: $id',
          error: e, name: 'DropboxSync');
    }
  }
```

> `_deleteFile` 已 `// Ignore not-found on delete`，幂等 OK。确认 `developer` 已 import。

- [ ] **Step 2 / 3：analyze + 提交**

```bash
cd hibiki && flutter analyze lib/src/sync/dropbox_sync_backend.dart
git add hibiki/lib/src/sync/dropbox_sync_backend.dart
git commit -m "feat(sync): Dropbox deleteAsset"
```

### Task 8：FTP（文件夹递归）

**Files:**
- Modify: `hibiki/lib/src/sync/ftp_sync_backend.dart`

- [ ] **Step 1：实现 `deleteAsset` + 递归 helper**

在类内加（`deleteAsset` 复用已有 `_opLock` 串行化，与 `listChildren` 一致）：

```dart
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _opLock.withLock(() async {
        await _ensureConnected();
        try {
          if (isFolder) {
            await _deleteDirRecursive(id);
          } else {
            await _deleteRemoteFileImpl(id);
          }
        } catch (e) {
          // 幂等 + 非致命：记录但不抛（与现有删除策略一致）。
        }
      });

  /// 递归删除 FTP 目录 [path]：先删子文件、递归删子目录，最后删空目录本身。
  Future<void> _deleteDirRecursive(String path) async {
    await _client!.changeDirectory(path);
    final List<FTPEntry> entries = await _client!.listDirectoryContent();
    for (final FTPEntry e in entries) {
      if (e.name == '.' || e.name == '..') continue;
      final String childId = '$path/${e.name}';
      if (e.type == FTPEntryType.dir) {
        await _deleteDirRecursive(childId);
      } else {
        await _deleteRemoteFileImpl(childId);
      }
    }
    // 回到父目录再删空目录（ftpconnect deleteDirectory 递归删目录树）。
    await _client!.changeDirectory(_parentPath(path));
    await _client!.deleteDirectory(_fileName(path));
  }
```

> `_deleteRemoteFileImpl` 内部已 `changeDirectory(parent)` + `deleteFile(name)`，递归里调用它前后会切目录，逻辑自洽。`FTPEntry` / `FTPEntryType` 来自 `package:ftpconnect`（文件已 import）。`_fileName` 若不存在则参照 `_parentPath` 加一个：`static String _fileName(String p) { final i = p.lastIndexOf('/'); return i < 0 ? p : p.substring(i + 1); }`（读文件确认是否已有）。

- [ ] **Step 2 / 3：analyze + 提交**

```bash
cd hibiki && flutter analyze lib/src/sync/ftp_sync_backend.dart
git add hibiki/lib/src/sync/ftp_sync_backend.dart
git commit -m "feat(sync): FTP deleteAsset with recursive folder delete"
```

### Task 9：SFTP（文件夹递归）

**Files:**
- Modify: `hibiki/lib/src/sync/sftp_sync_backend.dart`

- [ ] **Step 1：实现 `deleteAsset` + 递归 helper**

```dart
  @override
  Future<void> deleteAsset(String id, {bool isFolder = false}) =>
      _guarded(() async {
        final sftp = await _ensureConnected();
        try {
          if (isFolder) {
            await _deleteDirRecursive(sftp, id);
          } else {
            await _deleteIfExists(sftp, id);
          }
        } on SftpStatusError catch (e) {
          if (e.code == SftpStatusCode.noSuchFile) return; // 幂等
          rethrow;
        }
      });

  /// 递归删除 SFTP 目录 [path]：删子文件 + 递归子目录，最后 rmdir 空目录。
  Future<void> _deleteDirRecursive(SftpClient sftp, String path) async {
    final entries = await sftp.listdir(path);
    for (final e in entries) {
      if (e.filename == '.' || e.filename == '..') continue;
      final String childId = '$path/${e.filename}';
      if (e.attr.isDirectory) {
        await _deleteDirRecursive(sftp, childId);
      } else {
        await _deleteIfExists(sftp, childId);
      }
    }
    await sftp.rmdir(path);
  }
```

> `_guarded` / `_ensureConnected` / `_deleteIfExists` 均为文件内既有；`SftpStatusError` / `SftpStatusCode` 来自 `package:dartssh2`（已 import）。`sftp.rmdir` 为 dartssh2 API。

- [ ] **Step 2：analyze + 全量后端 analyze**

```bash
cd hibiki && flutter analyze lib/src/sync/sftp_sync_backend.dart
cd hibiki && flutter analyze lib/src/sync
```
Expected: 7 后端 + 接口 + fake 全部实现，无 "missing concrete implementation" 错误。

- [ ] **Step 3：提交**

```bash
git add hibiki/lib/src/sync/sftp_sync_backend.dart
git commit -m "feat(sync): SFTP deleteAsset with recursive folder delete"
```

---

## Phase 3：compare 对话框 —— 透传远端 id + 词典分组 + 删除 UI

### Task 10：书籍 entry 透传远端 folder id 与有声书资产 id

**Files:**
- Modify: `hibiki/lib/src/sync/sync_compare_dialog.dart`

- [ ] **Step 1：扩展 `SyncCompareEntry`**

在 `SyncCompareEntry` 构造与字段里加两个可空字段（`sync_compare_dialog.dart:18-41`）：构造参数加 `this.remoteFolderId, this.remoteAudioBookId,`；字段加：

```dart
  /// 远端书籍文件夹的原生定位符（删除整本远端书用）；本端独有书为 null。
  final String? remoteFolderId;

  /// 远端有声书资产（audiobook.hibikiaudio）的原生定位符；无远端有声书为 null。
  final String? remoteAudioBookId;
```

- [ ] **Step 2：`_RemoteBookData` 带出有声书资产 id**

在 `_RemoteBookData`（`:179-191`）加字段 `final String? audioBookId;` 并在构造里加 `this.audioBookId,`。在 `_fetchRemoteBookData`（`:193-240`）：声明 `String? audioBookId;`，在 `if (syncFiles.audioBook != null)` 分支里（`:218`）赋 `audioBookId = syncFiles.audioBook!.id;`（与 `audioPosSec` 同处），并在 `return _RemoteBookData(...)` 里带上 `audioBookId: audioBookId,`。

- [ ] **Step 3：`_fetchCompareData` 把远端 folder id / audiobook id 灌进 entry**

`_fetchCompareData` 里建立 `title -> 远端 folder id` 的映射。已有 `remoteByTitle`（`DriveFile`，含 `.id`）。在构造 entry（`:157-168`）处补：

```dart
    final remote = remoteByTitle[title] ?? remoteByTitle[sanitizeTtuFilename(title)];
    entries.add(SyncCompareEntry(
      title: title,
      bookId: local?.id,
      remoteFolderId: remote?.id,
      remoteAudioBookId: remoteData?.audioBookId,
      // ...其余字段不变...
    ));
```

- [ ] **Step 4：analyze**

Run: `cd hibiki && flutter analyze lib/src/sync/sync_compare_dialog.dart`
Expected: 无错误（字段可空，旧路径不受影响）。

- [ ] **Step 5：提交**

```bash
git add hibiki/lib/src/sync/sync_compare_dialog.dart
git commit -m "feat(sync): surface remote folder/audiobook ids in compare entries"
```

### Task 11：词典 entry 模型与抓取

**Files:**
- Modify: `hibiki/lib/src/sync/sync_compare_dialog.dart`

- [ ] **Step 1：新增词典 entry 类**（放在 `SyncCompareEntry` 之后）

```dart
/// 一条词典对比项：按词典名对齐本端与远端的存在性。
class SyncDictEntry {
  SyncDictEntry({
    required this.name,
    required this.hasLocal,
    this.remoteAssetId,
  });

  final String name;
  final bool hasLocal;

  /// 远端词典资产（`<name>.hibikidict`）定位符；远端没有则 null。
  final String? remoteAssetId;

  bool get hasRemote => remoteAssetId != null;
}
```

- [ ] **Step 2：新增词典抓取函数**（放在 `_fetchCompareData` 之后）

```dart
Future<List<SyncDictEntry>> _fetchDictEntries(
  HibikiDatabase db,
  SyncBackend backend, {
  required bool includeLocalOnly,
}) async {
  final String ns = await backend.ensureNamespace(kSyncDictionaryNamespace);
  final List<AssetEntry> remote = await backend.listChildren(ns);
  const String suffix = '.hibikidict';

  final Map<String, String> remoteByName = <String, String>{};
  for (final AssetEntry e in remote) {
    if (e.isFolder || !e.name.endsWith(suffix)) continue;
    remoteByName[e.name.substring(0, e.name.length - suffix.length)] = e.id;
  }
  final Set<String> localNames = <String>{
    for (final DictionaryMetaRow d in await db.getAllDictionaryMetadata()) d.name,
  };

  final Set<String> allNames = <String>{...localNames, ...remoteByName.keys};
  final List<SyncDictEntry> out = <SyncDictEntry>[
    for (final String n in allNames)
      SyncDictEntry(
        name: n,
        hasLocal: localNames.contains(n),
        remoteAssetId: remoteByName[n],
      ),
  ];
  // 门控：远端项始终保留（要删它）；纯本地项（无远端可删）只在词典同步选项
  // 开启时才显示，避免选项关闭时用无关本地词典刷屏。
  out.removeWhere((SyncDictEntry e) => !e.hasRemote && !includeLocalOnly);
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}
```

> 顶部需 import `kSyncDictionaryNamespace`（来自 `sync_orchestrator.dart`）。确认 import；`AssetEntry` 来自 `sync_asset_store.dart`（已间接，必要时显式 import）。

- [ ] **Step 3：State 持有词典列表并在 `_load` 一起抓**

`_SyncCompareDialogState` 加字段 `List<SyncDictEntry>? _dicts;`。在 `_load()`（`:315`）先读同步选项（决定本地项是否显示），再把两次抓取并行：

```dart
      final repo = SyncRepository(widget.db);
      final bool dictSyncOn = await repo.isSyncDictionaryEnabled();
      final results = await Future.wait([
        _fetchCompareData(widget.db, widget.backend),
        _fetchDictEntries(widget.db, widget.backend,
            includeLocalOnly: dictSyncOn),
      ]);
      final entries = results[0] as List<SyncCompareEntry>;
      final dicts = results[1] as List<SyncDictEntry>;
      // ...原 choices 构造不变...
      if (mounted) {
        setState(() {
          _entries = entries;
          _dicts = dicts;
          _choices = choices;
        });
      }
```

- [ ] **Step 4：analyze + 提交**

```bash
cd hibiki && flutter analyze lib/src/sync/sync_compare_dialog.dart
git add hibiki/lib/src/sync/sync_compare_dialog.dart
git commit -m "feat(sync): fetch dictionary compare entries"
```

### Task 12：i18n 键

**Files:**
- Modify（经工具）: `hibiki/lib/i18n/strings*.i18n.json`、`hibiki/lib/i18n/strings.g.dart`

- [ ] **Step 1：加键**

```bash
cd hibiki
dart run tool/i18n_sync.dart --add sync_compare_dictionaries "Dictionaries" "词典"
dart run tool/i18n_sync.dart --add sync_compare_delete_book "Delete book on remote" "删除远端书籍"
dart run tool/i18n_sync.dart --add sync_compare_delete_audiobook "Delete audiobook on remote" "删除远端有声书"
dart run tool/i18n_sync.dart --add sync_compare_delete_dict "Delete dictionary on remote" "删除远端词典"
dart run tool/i18n_sync.dart --add sync_compare_delete_confirm "Delete \"{name}\" from the remote? Local data is kept. This cannot be undone." "确定从远端删除「{name}」吗？本地数据保留，此操作不可撤销。"
dart run tool/i18n_sync.dart --add sync_compare_deleted "Deleted from remote" "已从远端删除"
```

- [ ] **Step 2：重新生成 + 格式化**

```bash
cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart
```

- [ ] **Step 3：完整性测试 + 提交**

```bash
cd hibiki && flutter test --no-pub test/i18n/i18n_completeness_test.dart
git add hibiki/lib/i18n
git commit -m "i18n(sync): add compare remote-delete keys"
```

### Task 13：删除 UI（书籍行 overflow + 词典分组 + 确认 + 乐观刷新）

**Files:**
- Modify: `hibiki/lib/src/sync/sync_compare_dialog.dart`

- [ ] **Step 1：删除确认 + 执行 helper**

在 `_SyncCompareDialogState` 内加：

```dart
  Future<bool> _confirmDelete(String name) async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (ctx) => HibikiDialogFrame(
        maxWidth: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.sync_compare_delete_confirm(name: name)),
            const SizedBox(height: 16),
            OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.dialog_cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(t.dialog_delete),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return ok ?? false;
  }

  /// 删除远端某项；成功后调用 [onSuccess] 做乐观本地移除并 setState。
  Future<void> _deleteRemote({
    required String name,
    required String id,
    required bool isFolder,
    required VoidCallback onSuccess,
  }) async {
    if (!await _confirmDelete(name)) return;
    try {
      await widget.backend.deleteAsset(id, isFolder: isFolder);
      if (!mounted) return;
      setState(onSuccess);
      showSyncMessage(context, t.sync_compare_deleted);
    } catch (e) {
      if (mounted) showSyncMessage(context, friendlySyncError(e));
    }
  }
```

> `showAppDialog` / `HibikiDialogFrame` / `showSyncMessage` / `friendlySyncError` / `t` 均文件内已用。

- [ ] **Step 2：书籍行加删除 overflow**

在 `_buildEntry` 的标题 `Row`（`:640-658`）末尾、冲突图标之后插入一个 focus-safe 的 overflow（仅当有可删的远端项时显示）。用 `HibikiOverflowMenu<String>`，value 用 `'book'` / `'audiobook'`：

```dart
              if (entry.remoteFolderId != null || entry.remoteAudioBookId != null)
                HibikiOverflowMenu<String>(
                  iconWidget: const Icon(Icons.delete_outline, size: 18),
                  tooltip: t.dialog_delete,
                  onSelected: (sel) {
                    if (sel == 'book' && entry.remoteFolderId != null) {
                      _deleteRemote(
                        name: entry.title,
                        id: entry.remoteFolderId!,
                        isFolder: true,
                        onSuccess: () => _entries!.remove(entry),
                      );
                    } else if (sel == 'audiobook' &&
                        entry.remoteAudioBookId != null) {
                      final int i = _entries!.indexOf(entry);
                      _deleteRemote(
                        name: entry.title,
                        id: entry.remoteAudioBookId!,
                        isFolder: false,
                        onSuccess: () {
                          if (i >= 0) {
                            _entries![i] = _copyWithoutAudio(entry);
                          }
                        },
                      );
                    }
                  },
                  items: [
                    if (entry.remoteFolderId != null)
                      HibikiPopupMenuItem<String>(
                        label: t.sync_compare_delete_book,
                        icon: Icons.menu_book_outlined,
                        value: 'book',
                      ),
                    if (entry.remoteAudioBookId != null)
                      HibikiPopupMenuItem<String>(
                        label: t.sync_compare_delete_audiobook,
                        icon: Icons.headphones_outlined,
                        value: 'audiobook',
                      ),
                  ],
                ),
```

加一个不可变 copy helper（清掉有声书 id，本地静态函数即可）：

```dart
  static SyncCompareEntry _copyWithoutAudio(SyncCompareEntry e) =>
      SyncCompareEntry(
        title: e.title,
        bookId: e.bookId,
        remoteFolderId: e.remoteFolderId,
        remoteAudioBookId: null,
        localProgress: e.localProgress,
        localUpdatedAt: e.localUpdatedAt,
        remoteProgress: e.remoteProgress,
        remoteUpdatedAt: e.remoteUpdatedAt,
        localStatsCount: e.localStatsCount,
        remoteStatsCount: e.remoteStatsCount,
        localAudioPosMs: e.localAudioPosMs,
        remoteAudioPosSec: e.remoteAudioPosSec,
      );
```

> 确认 `HibikiOverflowMenu` / `HibikiPopupMenuItem` 已可用（header 已在用，同文件）。

- [ ] **Step 3：词典分组渲染**

在 `build()` 的 `body = ListView(children: [...])`（`:480-493`）里，书籍 section 之后追加词典 section：

```dart
          if (_dicts != null && _dicts!.isNotEmpty) ...[
            const Divider(height: 16),
            _sectionHeader(t.sync_compare_dictionaries, theme),
            for (final d in _dicts!) _buildDictEntry(d, theme),
          ],
```

并加 `_buildDictEntry`：

```dart
  Widget _buildDictEntry(SyncDictEntry d, ThemeData theme) {
    return HibikiCard(
      color: Colors.transparent,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
      child: Row(
        children: [
          Icon(Icons.menu_book_outlined,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(d.name,
                style: theme.textTheme.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          Text(
            d.hasRemote ? t.sync_compare_remote : t.sync_compare_local,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          if (d.hasRemote)
            HibikiOverflowMenu<String>(
              iconWidget: const Icon(Icons.delete_outline, size: 18),
              tooltip: t.dialog_delete,
              onSelected: (_) => _deleteRemote(
                name: d.name,
                id: d.remoteAssetId!,
                isFolder: false,
                onSuccess: () => _dicts!.remove(d),
              ),
              items: [
                HibikiPopupMenuItem<String>(
                  label: t.sync_compare_delete_dict,
                  icon: Icons.delete_outline,
                  value: 'dict',
                ),
              ],
            ),
        ],
      ),
    );
  }
```

- [ ] **Step 4：空态处理**

当前 `_entries!.isEmpty` 才显示 `sync_compare_empty`。改为「书籍与词典都空」才算空：把 `else if (_entries!.isEmpty)` 改为 `else if (_entries!.isEmpty && (_dicts?.isEmpty ?? true))`。

- [ ] **Step 5：analyze + 格式化**

```bash
cd hibiki && flutter analyze lib/src/sync/sync_compare_dialog.dart && dart format lib/src/sync/sync_compare_dialog.dart
```
Expected: 无错误。

- [ ] **Step 6：提交**

```bash
git add hibiki/lib/src/sync/sync_compare_dialog.dart
git commit -m "feat(sync): per-row remote delete for books/audiobooks/dictionaries in compare dialog"
```

---

## Phase 4：测试与验证

### Task 14：对话框删除 widget 测试

**Files:**
- Create: `hibiki/test/sync/sync_compare_delete_test.dart`

- [ ] **Step 1：写测试（最小 `_FakeSyncBackend` 记录 deleteAsset 调用）**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
// 视实际路径补齐 import：sync_compare_dialog.dart、sync_backend.dart、
// sync_asset_store.dart、ttu_models.dart、hibiki_core、测试用 DB 工厂等。

void main() {
  testWidgets('book row delete calls deleteAsset on remote folder id',
      (tester) async {
    final fake = _FakeSyncBackend()
      ..books = [DriveFile(id: 'folderX', name: 'BookA')];

    // 用注入 fake backend 的 _SyncCompareDialog（经测试可见构造或
    // showSyncCompareDialog 的可测变体）搭建对话框；
    // pump 后点删除 overflow → 选"删除远端书籍" → 确认。
    // 断言：
    expect(fake.deletedIds, contains('folderX'));
    expect(fake.deletedFolderFlags['folderX'], isTrue);
  });

  testWidgets('dictionary row delete calls deleteAsset on remote asset id',
      (tester) async {
    // fake.dictAssets = [AssetEntry(id: '__dictionaries__/JMdict.hibikidict',
    //   name: 'JMdict.hibikidict')];
    // 点词典行删除 → 确认 → 断言 deletedIds 含该 asset id 且 isFolder=false。
  });
}
```

> 实现要点：`_SyncCompareDialog` 是私有类。两条路径任选其一——(a) 把它改成包级可见（去掉前导下划线）或加 `@visibleForTesting` 构造导出；(b) 在测试里走 `showSyncCompareDialog` 的注入变体。**优先 (b) 的最小侵入**：给 `showSyncCompareDialog` 加一个 `@visibleForTesting SyncBackend? backendOverride` 可选参，测试传 fake，生产路径不变。`_FakeSyncBackend implements SyncBackend`，只需让 `listBooks`/`listChildren`/`ensureNamespace`/`findOrCreateRootFolder`/`isAuthenticated`/`listSyncFiles` 返回固定数据，`deleteAsset` 记录 `deletedIds` 与 `deletedFolderFlags`，其余方法抛 `UnimplementedError`（测试路径不触达）。

- [ ] **Step 2：跑测试确认失败再实现到通过**

Run: `cd hibiki && flutter test --no-pub test/sync/sync_compare_delete_test.dart`
Expected: 先 FAIL（未注入/未实现），补齐后 PASS。

- [ ] **Step 3：提交**

```bash
git add hibiki/test/sync/sync_compare_delete_test.dart hibiki/lib/src/sync/sync_compare_dialog.dart
git commit -m "test(sync): compare dialog per-row remote delete widget test"
```

### Task 15：全量验证

- [ ] **Step 1：format + analyze + 全量测试**

```bash
cd hibiki && dart format . && flutter analyze && flutter test --no-pub
```
Expected: analyze 0 error；测试全绿（注意工作区有并发 agent，关注本特性相关文件）。

- [ ] **Step 2：设备复测（声明"修好"前必做，按 CLAUDE.md）**

在真机/模拟器：进设置 → 同步 → compare data，对一本远端书、一个远端词典分别走删除→确认，确认远端真的没了（再次打开 compare 该行消失），本地仍在。留截图证据。后端至少覆盖默认在用的 Hibiki 互联；其它后端按可达性补测。

- [ ] **Step 3：code review**

按 CLAUDE.md：spawn code-reviewer subagent，显式 `model: "opus"`，审实现是否符合计划、边界与向后兼容（旧 entry 字段可空、删除幂等、focus 可达）。

---

## Self-Review 检查

- **Spec 覆盖**：书籍删除（Task 10+13）✓；词典删除（Task 11+13）✓；有声书删除（Task 10 透传 + Task 13 overflow 'audiobook'）✓；「同名书籍」—— remote 按 folder name 建行，同名远端文件夹是各自独立行，逐行删除天然覆盖 ✓；仅删远端（`deleteAsset` 只动后端，本地行/库不动）✓；全部后端（Task 3-9）✓。
- **本地项门控（用户要求）**：纯本地词典行只在 `isSyncDictionaryEnabled()` 为真时显示（Task 11 `includeLocalOnly`）；远端词典行始终显示（删除目标）。有声书在本设计中**没有纯本地行**——删除是书籍行内"删远端有声书"二级动作，仅当远端存在该资产（`remoteAudioBookId != null`）时出现，故"音频本地仅开选项才显示"天然满足（关选项时也不会冒出无关本地音频行）。
- **占位符**：无 TODO/TBD；各后端代码体完整。少量 "读文件确认实际 helper 名" 是因后端各自连接 helper 命名不一，已标注确认点（`_ensureClient`/`_ensureOps`/`_fileName` 等），非占位。
- **类型一致**：`deleteAsset(String id, {bool isFolder = false})` 全后端 + fake 签名一致；UI 调用 `widget.backend.deleteAsset(id, isFolder: ...)` 一致；`SyncDictEntry.remoteAssetId` / `SyncCompareEntry.remoteFolderId` / `remoteAudioBookId` 命名贯穿一致。

## 风险点

- FTP/SFTP 递归删除是新增逻辑，真实服务器行为（权限、非空目录、隐藏项）需设备/服务器复测；递归删失败已吞为非致命并提示，不会破坏既有同步。
- 删除是不可逆外部副作用 —— 已强制确认框；文案明确「本地保留、不可撤销」。
- Google Drive 需确认 `GoogleDriveError` 的 404 判别字段名（Task 3 标注），否则幂等吞错可能掩盖真错。
- 向后兼容：新增字段全可空、新增接口方法有默认参数，旧同步路径（compare/orchestrator/manager）零改动。
```