# SyncAssetStore 资产层地基 — 实现计划（Plan A）

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 按任务逐条实现。步骤用 `- [ ]` 复选框跟踪。

**Goal:** 给所有 7 个同步后端引入统一的 `SyncAssetStore` 资产存取能力（任意命名空间下存/取/列二进制资产 + 通用 JSON），为后续双向并集同步（Plan B）打地基；本计划**不改变现有书籍进度同步行为**。

**Architecture:** 加法式扩展——在 `SyncBackend` 上新增 `SyncAssetStore` 接口方法；多数操作委托到各后端**已存在**的 `uploadContentFile/downloadContentFile/findContentFile/ensureBookFolder`，每个后端只新增 4 个原语：`ensureFolder(parentId,name)`、`listChildren(folderId)`、`getJsonAsset(fileId)`、`putJsonAsset(folderId,name,json)`。先用内存 fake 写契约测试守门，再逐后端实现。

**Tech Stack:** Dart / Flutter 3.44.0；`flutter test`；现有 `WebDavOps`（WebDAV/HibikiServer 共用）、googleapis Drive、MS Graph、Dropbox v2、ftpconnect、dartssh2。

**设计依据：** `docs/specs/2026-06-03-all-backend-asset-sync-design.md`。

---

## 文件结构

| 文件 | 责任 |
|------|------|
| `hibiki/lib/src/sync/sync_asset_store.dart`（新建） | `SyncAssetStore` 抽象接口 + `AssetEntry` 值对象 |
| `hibiki/lib/src/sync/sync_backend.dart`（改） | `SyncBackend` 增加 4 个抽象原语 + 默认资产方法（混入或基类默认实现） |
| `hibiki/lib/src/sync/webdav_ops.dart`（只读引用） | 提供 WebDAV 原语，不改 |
| `hibiki/lib/src/sync/{webdav,hibiki_client}_sync_backend.dart`（改） | 用 `WebDavOps` 实现 4 个原语 |
| `hibiki/lib/src/sync/google_drive_sync_backend.dart` + `google_drive_handler.dart`（改） | Drive REST 实现 4 个原语 |
| `hibiki/lib/src/sync/{onedrive,dropbox,ftp,sftp}_sync_backend.dart`（改） | 各自实现 4 个原语 |
| `hibiki/test/sync/sync_asset_store_contract.dart`（新建） | 可复用契约测试套件（接收一个 `SyncAssetStore` 工厂） |
| `hibiki/test/sync/fake_asset_store.dart`（新建） | 内存 `FakeAssetStore`，跑契约 + 供 Plan B 编排器测试 |

---

## Task 1：定义 `SyncAssetStore` 接口 + `AssetEntry`

**Files:**
- Create: `hibiki/lib/src/sync/sync_asset_store.dart`

- [ ] **Step 1: 写接口文件**

```dart
import 'dart:io';

/// 后端命名空间下的一个条目（资产文件或子命名空间）。
class AssetEntry {
  const AssetEntry({
    required this.id,
    required this.name,
    this.isFolder = false,
    this.sizeBytes,
  });

  /// 后端原生定位符：Drive/OneDrive 的不透明 id、WebDAV 的绝对 href、
  /// Dropbox/FTP/SFTP 的路径字符串。对调用方不透明。
  final String id;

  /// 业务可见名（如 `content.epub` / `<bookKey>` / `<name>.hibikidict`）。
  final String name;

  /// 该条目是子命名空间（文件夹）而非资产文件。
  final bool isFolder;

  /// 字节数；后端不提供时为 null（如 WebDAV PROPFIND 不返回大小）。
  final int? sizeBytes;
}

/// 与业务无关的资产存取层：在"命名空间"（文件夹/前缀）下存/取/列二进制资产，
/// 外加通用 JSON 读写。每个 [SyncBackend] 都实现它。
abstract class SyncAssetStore {
  /// 确保根下存在名为 [name] 的顶层命名空间，返回其原生定位符。
  Future<String> ensureNamespace(String name);

  /// 在 [parentId] 命名空间下确保存在子命名空间 [name]，返回其原生定位符。
  Future<String> ensureFolder(String parentId, String name);

  /// 列出 [namespaceId] 下的直接子项（资产文件 + 子命名空间）。
  Future<List<AssetEntry>> listChildren(String namespaceId);

  /// 在 [namespaceId] 下按名查找资产，未找到返回 null。
  Future<AssetEntry?> findAsset(String namespaceId, String name);

  /// 上传本地 [file] 为 [namespaceId] 下名为 [name] 的资产。
  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  });

  /// 下载 [assetId] 指向的资产到 [destination]。
  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  });

  /// 读取 [assetId] 指向的 JSON 资产；不存在或非 JSON 返回 null。
  Future<Object?> getJsonAsset(String assetId);

  /// 在 [namespaceId] 下写入名为 [name] 的 JSON 资产（覆盖）。
  Future<void> putJsonAsset(String namespaceId, String name, Object? json);
}
```

- [ ] **Step 2: 静态分析**

Run: `cd hibiki && flutter analyze lib/src/sync/sync_asset_store.dart`
Expected: No issues.

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/src/sync/sync_asset_store.dart
git commit -m "feat(sync): SyncAssetStore interface + AssetEntry"
```

---

## Task 2：内存 `FakeAssetStore` + 契约测试套件

**Files:**
- Create: `hibiki/test/sync/fake_asset_store.dart`
- Create: `hibiki/test/sync/sync_asset_store_contract.dart`

- [ ] **Step 1: 写 FakeAssetStore（内存实现，路径用 `/` 拼接作 id）**

```dart
import 'dart:convert';
import 'dart:io';

import 'package:hibiki/src/sync/sync_asset_store.dart';

/// 内存资产库：命名空间用 `/` 分隔的路径作为 id；文件夹是已知路径集合，
/// 资产是 path->bytes 映射。仅供测试。
class FakeAssetStore implements SyncAssetStore {
  final Set<String> _folders = <String>{''};
  final Map<String, List<int>> _files = <String, List<int>>{};

  String _join(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  @override
  Future<String> ensureNamespace(String name) async {
    _folders.add(name);
    return name;
  }

  @override
  Future<String> ensureFolder(String parentId, String name) async {
    final String path = _join(parentId, name);
    _folders.add(path);
    return path;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    final String prefix = namespaceId.isEmpty ? '' : '$namespaceId/';
    final List<AssetEntry> out = <AssetEntry>[];
    for (final String f in _folders) {
      if (f.isEmpty || f == namespaceId) continue;
      if (f.startsWith(prefix) && !f.substring(prefix.length).contains('/')) {
        out.add(AssetEntry(id: f, name: f.substring(prefix.length), isFolder: true));
      }
    }
    for (final MapEntry<String, List<int>> e in _files.entries) {
      if (e.key.startsWith(prefix) &&
          !e.key.substring(prefix.length).contains('/')) {
        out.add(AssetEntry(
          id: e.key,
          name: e.key.substring(prefix.length),
          sizeBytes: e.value.length,
        ));
      }
    }
    return out;
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    final String path = _join(namespaceId, name);
    if (!_files.containsKey(path)) return null;
    return AssetEntry(id: path, name: name, sizeBytes: _files[path]!.length);
  }

  @override
  Future<void> putAsset(String namespaceId, String name, File file,
      {void Function(double progress)? onProgress}) async {
    _files[_join(namespaceId, name)] = await file.readAsBytes();
    onProgress?.call(1.0);
  }

  @override
  Future<void> getAsset(String assetId, File destination,
      {void Function(double progress)? onProgress}) async {
    final List<int>? bytes = _files[assetId];
    if (bytes == null) throw StateError('asset not found: $assetId');
    await destination.writeAsBytes(bytes, flush: true);
    onProgress?.call(1.0);
  }

  @override
  Future<Object?> getJsonAsset(String assetId) async {
    final List<int>? bytes = _files[assetId];
    if (bytes == null) return null;
    return jsonDecode(utf8.decode(bytes));
  }

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) async {
    _files[_join(namespaceId, name)] = utf8.encode(jsonEncode(json));
  }
}
```

- [ ] **Step 2: 写可复用契约测试套件**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';

/// 对任意 [SyncAssetStore] 实现跑同一组行为断言。后端集成测试可复用
/// （传入真实后端工厂），单测传 FakeAssetStore。
void runAssetStoreContract(
  String label,
  SyncAssetStore Function() create,
) {
  group('SyncAssetStore contract: $label', () {
    late SyncAssetStore store;
    late Directory tmp;

    setUp(() async {
      store = create();
      tmp = await Directory.systemTemp.createTemp('asset_contract_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('put then find then get round-trips bytes', () async {
      final ns = await store.ensureNamespace('books');
      final src = File('${tmp.path}/a.bin')..writeAsBytesSync([1, 2, 3, 4]);
      await store.putAsset(ns, 'a.bin', src);

      final found = await store.findAsset(ns, 'a.bin');
      expect(found, isNotNull);
      expect(found!.name, 'a.bin');

      final dst = File('${tmp.path}/out.bin');
      await store.getAsset(found.id, dst);
      expect(dst.readAsBytesSync(), <int>[1, 2, 3, 4]);
    });

    test('findAsset returns null for missing', () async {
      final ns = await store.ensureNamespace('books');
      expect(await store.findAsset(ns, 'nope.bin'), isNull);
    });

    test('listChildren lists subfolders and files at one level only', () async {
      final books = await store.ensureNamespace('books');
      final sub = await store.ensureFolder(books, 'bookKey');
      final src = File('${tmp.path}/c.epub')..writeAsBytesSync([9]);
      await store.putAsset(sub, 'content.epub', src);
      await store.putJsonAsset(books, 'top.json', <String, int>{'x': 1});

      final topNames = (await store.listChildren(books)).map((e) => e.name).toSet();
      expect(topNames, containsAll(<String>['bookKey', 'top.json']));
      // 不应递归出 content.epub
      expect(topNames.contains('content.epub'), isFalse);

      final subNames = (await store.listChildren(sub)).map((e) => e.name).toSet();
      expect(subNames, contains('content.epub'));
    });

    test('json round-trips', () async {
      final ns = await store.ensureNamespace('dictionaries');
      await store.putJsonAsset(ns, 'm.json', <String, Object?>{'k': 'v', 'n': 2});
      final found = await store.findAsset(ns, 'm.json');
      final decoded = await store.getJsonAsset(found!.id);
      expect(decoded, <String, Object?>{'k': 'v', 'n': 2});
    });
  });
}
```

- [ ] **Step 3: 写驱动测试跑 fake**

Create inline at bottom of `sync_asset_store_contract.dart` is not allowed (no `main`); instead add `hibiki/test/sync/fake_asset_store_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'fake_asset_store.dart';
import 'sync_asset_store_contract.dart';

void main() {
  runAssetStoreContract('FakeAssetStore', FakeAssetStore.new);
}
```

- [ ] **Step 4: 跑测试，应通过**

Run: `cd hibiki && flutter test test/sync/fake_asset_store_test.dart`
Expected: PASS（4 个契约用例）。

- [ ] **Step 5: Commit**

```bash
git add hibiki/test/sync/fake_asset_store.dart hibiki/test/sync/sync_asset_store_contract.dart hibiki/test/sync/fake_asset_store_test.dart
git commit -m "test(sync): FakeAssetStore + reusable asset-store contract"
```

---

## Task 3：`SyncBackend` 声明 `SyncAssetStore`

**Files:**
- Modify: `hibiki/lib/src/sync/sync_backend.dart`

- [ ] **Step 1: 让 `SyncBackend` 实现 `SyncAssetStore`**

在 `sync_backend.dart` 顶部加 `import 'package:hibiki/src/sync/sync_asset_store.dart';`，把抽象类签名改为：

```dart
abstract class SyncBackend implements SyncAssetStore {
  // ...现有所有成员保持不变...
}
```

不在此处给默认实现——每个后端各自实现 4 个原语（`ensureNamespace`/`ensureFolder`/`listChildren`/`findAsset` 已有同名或近似的 `findContentFile`；`putAsset`/`getAsset` 委托 `uploadContentFile`/`downloadContentFile`；`getJsonAsset`/`putJsonAsset` 各自实现）。

- [ ] **Step 2: 静态分析（预期 7 个后端报"未实现 SyncAssetStore 成员"——这是下面任务要补的清单）**

Run: `cd hibiki && flutter analyze lib/src/sync/sync_backend.dart`
Expected: 报错列出各后端缺失的抽象方法。记录这份清单，作为 Task 4-9 的验收基准。

- [ ] **Step 3: 不提交**（等后端实现齐了一起绿）。本步只确认编译错误集合符合预期。

---

## Task 4：WebDAV 家族实现（WebDavSyncBackend + HibikiClientSyncBackend）

> 这两个后端都持有 `WebDavOps? _ops`，folder/file id 都是**绝对 href**。实现可直接复用 `WebDavOps` 原语。两个后端实现体一致，分别加。

**Files:**
- Modify: `hibiki/lib/src/sync/webdav_sync_backend.dart`
- Modify: `hibiki/lib/src/sync/hibiki_client_sync_backend.dart`

- [ ] **Step 1: 在 WebDavSyncBackend 加资产方法**

在类内（`_ops` 为其 `WebDavOps` 句柄；如该后端用别的字段名，按实际句柄名替换）加：

```dart
  String get _root => '${_ops!.baseUrl}/ttu-reader-data/';

  @override
  Future<String> ensureNamespace(String name) async {
    await _ensureReady(); // 该后端已有的"确保已认证/已解析"私有方法；若名称不同按实际替换
    final String path = '$_root${Uri.encodeComponent(name)}/';
    await _ops!.ensureCollection(path);
    return path;
  }

  @override
  Future<String> ensureFolder(String parentId, String name) async {
    final String path = '$parentId${Uri.encodeComponent(name)}/';
    await _ops!.ensureCollection(path);
    return path;
  }

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    final List<DavEntry> entries = await _ops!.propfindChildren(namespaceId);
    return entries
        .where((DavEntry e) => e.href != namespaceId)
        .map((DavEntry e) => AssetEntry(
              id: e.href,
              name: _basename(e.displayName),
              isFolder: e.isCollection,
            ))
        .toList();
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    final String path = '$namespaceId${Uri.encodeComponent(name)}';
    if (!await _ops!.headFile(path)) return null;
    return AssetEntry(id: path, name: name);
  }

  @override
  Future<void> putAsset(String namespaceId, String name, File file,
      {void Function(double progress)? onProgress}) {
    // 复用既有内容上传：folderId=namespaceId, fileName=name
    return uploadContentFile(
        folderId: namespaceId, fileName: name, file: file, onProgress: onProgress);
  }

  @override
  Future<void> getAsset(String assetId, File destination,
      {void Function(double progress)? onProgress}) {
    return downloadContentFile(
        fileId: assetId, destination: destination, onProgress: onProgress);
  }

  @override
  Future<Object?> getJsonAsset(String assetId) => _ops!.downloadJson(assetId);

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _ops!.uploadJson(namespaceId, name, json);

  String _basename(String n) =>
      n.endsWith('/') ? n.substring(0, n.length - 1) : n;
```

加 `import 'package:hibiki/src/sync/sync_asset_store.dart';`。`DavEntry` 来自 `webdav_ops.dart`（已在该后端可见或补 import）。
注意：`_ensureReady`/`_ops` 是占位名——实现前**先读该后端文件**确认"确保已认证并建好 `_ops`"的真实私有方法名（WebDavSyncBackend 可能是 `_requireOps()`/直接断言；HibikiClientSyncBackend 是 `_ensureResolved()`）。

- [ ] **Step 2: 在 HibikiClientSyncBackend 加同样的方法**

HibikiClient 的"确保就绪"方法是已存在的 `_ensureResolved()`，root 是 `'${_ops!.baseUrl}/ttu-reader-data/'`（见 `findOrCreateRootFolder`）。把 Step 1 的同一组方法贴入，`ensureNamespace` 内调 `await _ensureResolved();`。

- [ ] **Step 3: 静态分析**

Run: `cd hibiki && flutter analyze lib/src/sync/webdav_sync_backend.dart lib/src/sync/hibiki_client_sync_backend.dart`
Expected: 这两个后端不再报缺失 SyncAssetStore 成员。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/sync/webdav_sync_backend.dart hibiki/lib/src/sync/hibiki_client_sync_backend.dart hibiki/lib/src/sync/sync_backend.dart
git commit -m "feat(sync): WebDAV-family SyncAssetStore impl"
```

---

## Task 5：Google Drive 实现

**Files:**
- Modify: `hibiki/lib/src/sync/google_drive_sync_backend.dart`
- Modify: `hibiki/lib/src/sync/google_drive_handler.dart`

- [ ] **Step 1: 先读这两个文件**，确认 `GoogleDriveHandler` 现有私有方法：创建文件夹（`ensureBookFolder` 内部用的 create-folder 逻辑）、按父列子项（`listBooks`/`listSyncFiles` 内部的 files.list 查询）、上传/下载 JSON（`updateProgressFile`/`getProgressFile` 内部的字节读写）。Drive 一切按**不透明 folderId/fileId** 定位，文件夹靠 `name + mimeType='application/vnd.google-apps.folder' + 'parent' in parents` 查询。

- [ ] **Step 2: 在 `GoogleDriveHandler` 加通用原语**（公开方法，供 backend 委托）：

```dart
  /// 在 [parentId] 下按名查/建子文件夹，返回 folderId。
  Future<String> ensureChildFolder(String parentId, String name) async {
    final existing = await _findChildFolder(parentId, name); // 复用现有按名查询逻辑
    if (existing != null) return existing;
    return _createFolder(name, parentId);                    // 复用 ensureBookFolder 内的建夹逻辑
  }

  /// 列出 [parentId] 直接子项（文件 + 文件夹）。
  Future<List<DriveFile>> listChildren(String parentId);     // files.list q="'parentId' in parents and trashed=false"，返回含 mimeType

  Future<Object?> downloadJsonById(String fileId);           // media GET → utf8 → jsonDecode
  Future<void> uploadJsonInFolder(String parentId, String name, Object? json); // 查同名→有则 update 无则 create，media=utf8(jsonEncode)
```

上面 4 个方法的内部实现**从现有 `ensureBookFolder`/`listBooks`/`listSyncFiles`/`getProgressFile`/`updateProgressFile` 抽取/复用**（它们已经做过建夹、列子项、按名查、上传下载 JSON 的 Drive API 调用）。`listChildren` 与 `listBooks` 的差别仅是不过滤 mimeType。`DriveFile` 需带上是否文件夹的判断（按 `mimeType == 'application/vnd.google-apps.folder'`）。

- [ ] **Step 3: 在 `GoogleDriveSyncBackend` 实现 SyncAssetStore（委托 handler）**

```dart
  @override
  Future<String> ensureNamespace(String name) async {
    final root = await findOrCreateRootFolder();
    return _drive.ensureChildFolder(root, name);
  }

  @override
  Future<String> ensureFolder(String parentId, String name) =>
      _drive.ensureChildFolder(parentId, name);

  @override
  Future<List<AssetEntry>> listChildren(String namespaceId) async {
    final files = await _drive.listChildren(namespaceId);
    return files
        .map((DriveFile f) => AssetEntry(
              id: f.id,
              name: f.name,
              isFolder: f.isFolder, // handler 给 DriveFile 补的字段
            ))
        .toList();
  }

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) async {
    final f = await findContentFile(namespaceId, name);
    return f == null ? null : AssetEntry(id: f.id, name: f.name);
  }

  @override
  Future<void> putAsset(String namespaceId, String name, File file,
          {void Function(double progress)? onProgress}) =>
      uploadContentFile(
          folderId: namespaceId, fileName: name, file: file, onProgress: onProgress);

  @override
  Future<void> getAsset(String assetId, File destination,
          {void Function(double progress)? onProgress}) =>
      downloadContentFile(
          fileId: assetId, destination: destination, onProgress: onProgress);

  @override
  Future<Object?> getJsonAsset(String assetId) => _drive.downloadJsonById(assetId);

  @override
  Future<void> putJsonAsset(String namespaceId, String name, Object? json) =>
      _drive.uploadJsonInFolder(namespaceId, name, json);
```

（`_drive` 是 `GoogleDriveSyncBackend` 持有的 `GoogleDriveHandler` 字段；按实际字段名替换。`_wrapErrors` 包装沿用现有模式。）

- [ ] **Step 4: 静态分析**

Run: `cd hibiki && flutter analyze lib/src/sync/google_drive_sync_backend.dart lib/src/sync/google_drive_handler.dart`
Expected: 不再报 Drive 后端缺失成员。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/sync/google_drive_sync_backend.dart hibiki/lib/src/sync/google_drive_handler.dart
git commit -m "feat(sync): Google Drive SyncAssetStore impl"
```

---

## Task 6-9：OneDrive / Dropbox / FTP / SFTP 实现

> 模式同 Task 5：**先读该后端文件**，把它现有的"建夹 / 列子项 / 按名查 / 上传下载字节 / 上传下载 JSON"私有逻辑抽成 4 个原语，再实现 SyncAssetStore（`putAsset`/`getAsset` 委托现有 `uploadContentFile`/`downloadContentFile`；`findAsset` 委托 `findContentFile`）。各后端定位符差异见设计文档 §3 表。

每个后端一个独立任务，步骤一致：

- [ ] **Task 6 OneDrive**（`onedrive_sync_backend.dart`，MS Graph 不透明 item id；建夹 `POST /items/{parent}/children`，列子项 `GET /items/{id}/children`，JSON 走 `content` 端点）。实现 4 原语 + SyncAssetStore，`flutter analyze` 该文件通过，commit `feat(sync): OneDrive SyncAssetStore impl`。
- [ ] **Task 7 Dropbox**（`dropbox_sync_backend.dart`，path 字符串 id；建夹 `create_folder_v2`，列 `list_folder`，上传 `upload`，下载 `download`）。同上，commit `feat(sync): Dropbox SyncAssetStore impl`。
- [ ] **Task 8 FTP**（`ftp_sync_backend.dart`，home 锚定路径；所有操作走现有 `AsyncMutex _opLock`；建夹 `makeDirectory`，列 `listDirectoryContent`，JSON 经临时文件）。同上，commit `feat(sync): FTP SyncAssetStore impl`。
- [ ] **Task 9 SFTP**（`sftp_sync_backend.dart`，home 相对路径；所有操作包在现有 `_guarded()`；`SftpClient.mkdir`/`listdir`/`open`）。同上，commit `feat(sync): SFTP SyncAssetStore impl`。

每个任务收尾：`cd hibiki && flutter analyze lib/src/sync/<file>` 通过。

---

## Task 10：全后端编译 + 现有同步测试零回归

**Files:** 无（验收任务）

- [ ] **Step 1: 全量分析**

Run: `cd hibiki && flutter analyze lib/src/sync`
Expected: No issues（所有后端都实现了 SyncAssetStore）。

- [ ] **Step 2: 跑现有同步测试，证明书籍进度同步零破坏**

Run: `cd hibiki && flutter test test/sync`
Expected: 全绿（现有 `sync_repository_test` / `sync_manager_folder_cache_test` / `sync_merge_test` / `ttu_*_test` / `hibiki_p2p_roundtrip_test` / `sync_asset_package_service_test` + 新增 `fake_asset_store_test` 均通过）。

- [ ] **Step 3: 格式化**

Run: `cd hibiki && dart format .`
Expected: 仅本计划新增/改动文件被格式化。

- [ ] **Step 4: Commit（如 format 有改动）**

```bash
git add -u hibiki/lib/src/sync hibiki/test/sync
git commit -m "style(sync): dart format asset-store changes"
```

---

## 自检（Plan A 对照设计 §3）

- 设计 §3 的 9 个 `SyncAssetStore` 方法 → Task 1 定义、Task 4-9 在 7 个后端实现：覆盖。
- "现有方法委托/保留，零破坏" → Task 3 用 `implements` 加法式扩展，Task 10 Step 2 用现有测试守门：覆盖。
- 后端异构定位符（href/id/path）→ `AssetEntry.id` 不透明承载，各后端 Task 自述差异：覆盖。
- 契约测试可复用（Plan B 编排器用 fake）→ Task 2：覆盖。
- 占位名风险：Task 4/5/6-9 明确要求"先读文件确认真实私有方法名"，非编造调用——这是现有代码集成的诚实做法，不是 TBD。

**范围说明（不静默截断）：** Plan A 只建地基与 7 后端的 AssetStore 能力 + fake 契约。**远端真实读写正确性**（各后端 put/get/list 在真服务器上的行为）靠 Plan B 的设备复测覆盖（单测用 fake，无网络）。新布局 `books/<bookKey>/`、双向并集编排、接收远端书/有声书/词典、新 toggle、i18n、compare UI 全部在 **Plan B**。
