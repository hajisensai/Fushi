# 互联「实时直读对端库」同步 实现计划（废除 `__dictionaries__` 暂存，保持双向）

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现。步骤用 `- [ ]` 复选框跟踪。
> 始终用中文回复。函数/新增 Dart helper 必须有类型签名。每个任务 TDD：先写失败测试→跑红→最小实现→跑绿→提交。
> 提交只 stage 本任务文件，禁止 `git add -A`（本工作区可能有并发 agent 改动）。

**Goal:** 让 Hibiki 互联（LAN 直连，且仅互联）的库同步**直接对端实时库**收发，client 经新增 HTTP 端点直读/直写 host 的真实词典（Phase 1）/书籍（Phase 2）/有声书+本地音频（Phase 3），彻底不经 `__dictionaries__` 等暂存目录 → 无暂存副本、无暂存孤儿、保持双向。

**Architecture:** host 的 `HibikiSyncServer` 从「被动 WebDAV 文件服务器」升级为「库感知服务」：新增 `/api/capabilities` 能力探测 + `/api/library/<asset>` 系列端点，把 host **实时库**即时 export/import/delete（经注入的 `HibikiLibraryHostService`，由 `AppModel` 实现并经 `HibikiSyncServerController` 注入，所有库变动经 `runExclusiveWithSync` 串行）。client 的 `SyncOrchestrator` 在每类资产同步顶部探测能力：互联且 host 支持 live → 走 `_syncXxxLive`（经 `HibikiClientSyncBackend` 新增的 live 方法直读端点），否则走现有暂存路径（云后端 + 旧 peer 完全不变）。删除传播（BUG-086 A 已落地）在 live 下改走 `DELETE` 端点。

**Tech Stack:** Dart/Flutter 3.44；shelf（host HTTP）；现有 `WebDavOps`（client HTTP）；Drift（库元数据）；`SyncAssetPackageService`（即时打包/解包，已存在且流式）；`flutter_test`。

**关联：** 取代 `docs/specs/2026-06-06-hibiki-interconnect-live-dict-sync-plan.md`（原 dict-only 草案，本计划是其落地 + 扩到全资产的分阶段版）。BUG-086（暂存孤儿，A 删除传播已落地）。真机/双设备验证后台环境无法做，**每阶段末由用户真机验证再进下一阶段**。

---

## 核心约束（决定方案形状，不可违背）

1. **后端无关不破坏**：云后端（GoogleDrive/WebDAV/Dropbox/OneDrive/FTP/SFTP）与旧版 peer **完全走现有暂存路径，零改动**。live 分支仅在 `_backend is HibikiClientSyncBackend && 探测到 host 支持 live` 时进入。（Never break userspace）
2. **无旧设备，互联恒走 live**（用户确认无旧 peer，故不做向后兼容探测/回退——消除为旧设备而设的特例）：分流只按后端类型 `_backend is HibikiClientSyncBackend` 判定，互联永远走 live 端点；client 不探测 `/api/capabilities`。`_syncDictionariesStaged` 暂存路径**仅为云后端（非 HibikiClient）保留**，不再服务互联。若 host 端点意外 404（我们两端同代码、库服务恒注入，正常不会），client live 方法按 `checkStatus` 自然抛错（loud fail，不静默回退），便于发现而非掩盖。
3. **鉴权复用**：所有 `/api/library/*`、`/api/capabilities` 端点经现有 `_authMiddleware`（HTTP Basic + 配对 token）自动鉴权——它已覆盖除 `api/pair` 外所有路径（`hibiki_sync_server.dart:147-163`），无需新鉴权代码，但要写测试守住「未鉴权 401」。
4. **host 库变动串行**：host 经端点 import/delete 自己的库，必须与 host 自身可能在跑的同步/查词串行——经 `runExclusiveWithSync`（`sync_auto_trigger.dart:56`）。
5. **流式不入内存**：export/import 大词典/大书/大音频必须流式（host 端 `file.openRead()`，client 端 `request.addStream` / 边读边写 sink）——复用 `SyncAssetPackageService` 既有 isolate 流式打包与 `HibikiClientSyncBackend.uploadContentFile/downloadContentFile` 的流式范式。
6. **删除语义仍显式**：live 双向 union 仍分不清「对端删了 X」与「本端新增 X」；本计划只消除**暂存副本/孤儿**，删除双向传播仍依赖 A（删本地→`DELETE` 端点）。二者正交。

---

## File Structure（Phase 1 触及/新建文件）

- **新建** `hibiki/lib/src/sync/hibiki_library_host_service.dart` — host 侧库服务抽象 `HibikiLibraryHostService` + 数据类 `RemoteDictionaryInfo` + 纯 diff 函数 `computeDictionarySyncDiff`。抽象不依赖 `AppModel`（可在测试用 fake 实现）。
- **新建** `hibiki/lib/src/sync/app_model_library_host_service.dart` — `AppModelLibraryHostService implements HibikiLibraryHostService`，用 `HibikiDatabase` + `dictionaryResourceRoot` + `SyncAssetPackageService` + 注入的删除/刷新回调实现，所有库变动经 `runExclusiveWithSync`。
- **修改** `hibiki/lib/src/sync/hibiki_sync_server.dart` — 新增 `_libraryService` 字段（可空，注入）；`_handleRequest` 路由加 `/api/capabilities` 与 `/api/library/dictionaries...`；新增 handler。
- **修改** `hibiki/lib/src/sync/hibiki_server_controller.dart` — 构造 `HibikiSyncServer` 时注入 `libraryService`（新增工厂 `HibikiLibraryHostService Function()? libraryServiceFactory`）。
- **修改** `hibiki/lib/src/sync/hibiki_client_sync_backend.dart` — 新增 live 方法：`supportsLiveDictionaries()`（探测 + 会话级缓存）、`listRemoteDictionaries()`、`getRemoteDictionary()`、`putRemoteDictionary()`、`deleteRemoteDictionary()`。
- **修改** `hibiki/lib/src/sync/sync_orchestrator.dart` — `syncDictionaries` 拆 `_syncDictionariesStaged`（现有体）+ 顶部分流 `_syncDictionariesLive`。
- **修改** `hibiki/lib/src/models/app_model.dart` — ① 构造 controller 时传 `libraryServiceFactory`；② `_propagateDictionaryDeleteToRemote` 在 `backend is HibikiClientSyncBackend && supportsLiveDictionaries()` 时走 `deleteRemoteDictionary` 端点而非暂存 `deleteRemoteDictionaryAsset`。
- **测试**：`hibiki/test/sync/hibiki_library_host_service_test.dart`、`hibiki/test/sync/hibiki_sync_server_library_test.dart`、`hibiki/test/sync/hibiki_client_live_dict_test.dart`、`hibiki/test/sync/sync_orchestrator_live_dict_test.dart`。

---

## Phase 1 — 地基 + 词典实时直读（本计划详写，可独立交付）

### Task 1：纯 diff 函数 + host 服务抽象 + 数据类

**Files:**
- Create: `hibiki/lib/src/sync/hibiki_library_host_service.dart`
- Test: `hibiki/test/sync/hibiki_library_host_service_test.dart`

- [ ] **Step 1: 写失败测试**（纯函数 diff：按名 union，删除交给 A）

```dart
// hibiki/test/sync/hibiki_library_host_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

void main() {
  group('computeDictionarySyncDiff', () {
    test('union by name: pull remote-only, push local-only, skip shared', () {
      final DictionarySyncDiff diff = computeDictionarySyncDiff(
        localNames: <String>{'JMdict', '明镜'},
        remoteNames: <String>{'明镜', 'NHK'},
      );
      expect(diff.toPull, <String>{'NHK'});
      expect(diff.toPush, <String>{'JMdict'});
    });

    test('empty both sides -> empty diff', () {
      final DictionarySyncDiff diff = computeDictionarySyncDiff(
        localNames: <String>{},
        remoteNames: <String>{},
      );
      expect(diff.toPull, isEmpty);
      expect(diff.toPush, isEmpty);
    });
  });
}
```

- [ ] **Step 2: 跑红**

Run: `cd hibiki && flutter test test/sync/hibiki_library_host_service_test.dart`
Expected: FAIL（`computeDictionarySyncDiff` / `DictionarySyncDiff` 未定义）

- [ ] **Step 3: 最小实现**

```dart
// hibiki/lib/src/sync/hibiki_library_host_service.dart
import 'dart:io';

/// host 实时词典的清单条目（不含 contentHash：Phase 1 按名 union，与现有暂存
/// 路径同语义，避免引入跨设备哈希一致性的新风险；overwrite-by-hash 列为 follow-up）。
class RemoteDictionaryInfo {
  const RemoteDictionaryInfo({required this.name, required this.type});
  final String name;
  final String type;

  Map<String, Object?> toJson() => <String, Object?>{'name': name, 'type': type};

  static RemoteDictionaryInfo fromJson(Map<String, Object?> json) =>
      RemoteDictionaryInfo(
        name: json['name']?.toString() ?? '',
        type: json['type']?.toString() ?? '',
      );
}

/// 按名 union 的 diff 结果。删除不在此处推断（交给 BUG-086 A 的删除传播）。
class DictionarySyncDiff {
  const DictionarySyncDiff({required this.toPull, required this.toPush});
  final Set<String> toPull; // 对端有∧本端无
  final Set<String> toPush; // 本端有∧对端无
}

DictionarySyncDiff computeDictionarySyncDiff({
  required Set<String> localNames,
  required Set<String> remoteNames,
}) {
  return DictionarySyncDiff(
    toPull: remoteNames.difference(localNames),
    toPush: localNames.difference(remoteNames),
  );
}

/// host 侧「库感知」服务：把 host 的实时库即时 export/import/delete/list。
/// 抽象不依赖 AppModel，便于测试用 fake 注入。所有实现里的库变动必须串行
/// （经 runExclusiveWithSync）——见 AppModelLibraryHostService。
abstract class HibikiLibraryHostService {
  /// host 当前实时词典清单（从 DictionaryMeta 表读，不是从任何暂存目录）。
  Future<List<RemoteDictionaryInfo>> listDictionaries();

  /// 即时把名为 [name] 的实时词典打包成 .hibikidict 临时文件，返回该文件。
  /// 调用方负责删除返回的临时文件（及其父临时目录）。词典不存在抛 [StateError]。
  Future<File> exportDictionary(String name);

  /// 把 [packageFile]（.hibikidict）导入 host 实时库（幂等：同名覆盖资源 + upsert 元数据）。
  Future<void> importDictionary(File packageFile);

  /// 从 host 实时库删除名为 [name] 的词典（DB 元数据 + 资源目录）。
  Future<void> deleteDictionary(String name);
}
```

- [ ] **Step 4: 跑绿**

Run: `cd hibiki && flutter test test/sync/hibiki_library_host_service_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/hibiki_library_host_service.dart hibiki/test/sync/hibiki_library_host_service_test.dart
git commit -m "feat(sync): host library service abstraction + dictionary diff (interconnect live phase1)"
```

---

### Task 2：`AppModelLibraryHostService` 实现（host 用真实库 export/import/delete/list）

**Files:**
- Create: `hibiki/lib/src/sync/app_model_library_host_service.dart`
- Test: `hibiki/test/sync/hibiki_library_host_service_test.dart`（追加，用真实 `SyncAssetPackageService` + 内存 DB + 临时目录）

- [ ] **Step 1: 写失败测试**（端到端 round-trip：源库 export → 清单/删除可见）

```dart
// 追加到 hibiki/test/sync/hibiki_library_host_service_test.dart：
// 顶部 import：
//   import 'dart:io';
//   import 'package:drift/native.dart';
//   import 'package:hibiki/src/sync/app_model_library_host_service.dart';
//   import 'package:hibiki/src/sync/sync_asset_package_service.dart';
//   import 'package:hibiki_core/hibiki_core.dart';
//   import 'package:path/path.dart' as p;
// 参考既有 test/sync/sync_asset_package_service_test.dart:40-80 如何用内存 DB
// (HibikiDatabase(NativeDatabase.memory())) 建 DictionaryMeta + 资源目录 + blobs.bin。

  group('AppModelLibraryHostService dictionaries', () {
    late Directory tmp;
    late HibikiDatabase db;
    late Directory dictRoot;
    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('hibiki_lib_host');
      db = HibikiDatabase(NativeDatabase.memory());
      dictRoot = Directory(p.join(tmp.path, 'dicts'))..createSync(recursive: true);
    });
    tearDown(() async {
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    test('list reflects DictionaryMeta; export builds a package; delete removes', () async {
      await db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
        name: 'JMdict', formatKey: 'yomitan', order: 0,
        type: const Value('term'),
      ));
      Directory(p.join(dictRoot.path, 'JMdict')).createSync(recursive: true);
      File(p.join(dictRoot.path, 'JMdict', 'blobs.bin')).writeAsBytesSync(<int>[1, 2, 3]);

      final AppModelLibraryHostService svc = AppModelLibraryHostService(
        db: db,
        dictionaryResourceRoot: dictRoot,
        packages: SyncAssetPackageService(db: db),
        refreshDictionaryCache: () async {},
        runExclusive: (Future<void> Function() body) => body(), // 测试不串行
      );

      final List<RemoteDictionaryInfo> list = await svc.listDictionaries();
      expect(list.map((RemoteDictionaryInfo d) => d.name), <String>['JMdict']);

      final File pkg = await svc.exportDictionary('JMdict');
      expect(pkg.existsSync(), isTrue);
      expect(pkg.lengthSync(), greaterThan(0));

      await svc.deleteDictionary('JMdict');
      expect(await svc.listDictionaries(), isEmpty);
      expect(Directory(p.join(dictRoot.path, 'JMdict')).existsSync(), isFalse);

      pkg.parent.deleteSync(recursive: true);
    });
  });
```

- [ ] **Step 2: 跑红**

Run: `cd hibiki && flutter test test/sync/hibiki_library_host_service_test.dart`
Expected: FAIL（`AppModelLibraryHostService` 未定义）

- [ ] **Step 3: 最小实现**

```dart
// hibiki/lib/src/sync/app_model_library_host_service.dart
import 'dart:io';

import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_package_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// 用真实 Hibiki 库实现 host 库服务。库变动经注入的 [runExclusive] 串行
/// （生产传 runExclusiveWithSync），并经 [refreshDictionaryCache] 刷新内存词典缓存。
class AppModelLibraryHostService implements HibikiLibraryHostService {
  AppModelLibraryHostService({
    required HibikiDatabase db,
    required Directory dictionaryResourceRoot,
    required SyncAssetPackageService packages,
    required Future<void> Function() refreshDictionaryCache,
    required Future<void> Function(Future<void> Function() body) runExclusive,
  })  : _db = db,
        _dictionaryResourceRoot = dictionaryResourceRoot,
        _packages = packages,
        _refreshDictionaryCache = refreshDictionaryCache,
        _runExclusive = runExclusive;

  final HibikiDatabase _db;
  final Directory _dictionaryResourceRoot;
  final SyncAssetPackageService _packages;
  final Future<void> Function() _refreshDictionaryCache;
  final Future<void> Function(Future<void> Function() body) _runExclusive;

  static const String _dictionaryAssetSuffix = '.hibikidict';

  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async {
    final List<DictionaryMetaRow> rows = await _db.getAllDictionaryMetadata();
    return <RemoteDictionaryInfo>[
      for (final DictionaryMetaRow r in rows)
        RemoteDictionaryInfo(name: r.name, type: r.type ?? ''),
    ];
  }

  @override
  Future<File> exportDictionary(String name) async {
    final List<DictionaryMetaRow> rows = await _db.getAllDictionaryMetadata();
    final bool exists = rows.any((DictionaryMetaRow r) => r.name == name);
    if (!exists) throw StateError('dictionary not found: $name');
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_dict_export');
    final File out = File(p.join(tmpDir.path, '$name$_dictionaryAssetSuffix'));
    await _packages.exportDictionaryPackage(
      dictionaryName: name,
      dictionaryResourceRoot: _dictionaryResourceRoot,
      outputFile: out,
    );
    return out;
  }

  @override
  Future<void> importDictionary(File packageFile) async {
    await _runExclusive(() async {
      await _packages.importDictionaryPackage(
        packageFile: packageFile,
        dictionaryResourceRoot: _dictionaryResourceRoot,
      );
      await _refreshDictionaryCache();
    });
  }

  @override
  Future<void> deleteDictionary(String name) async {
    await _runExclusive(() async {
      await _db.deleteDictionaryMeta(name);
      final Directory dir =
          Directory(p.join(_dictionaryResourceRoot.path, name));
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      await _refreshDictionaryCache();
    });
  }
}
```

> 注：`DictionaryMetaRow.type` 若非空则去掉 `?? ''`。执行时先 `flutter analyze` 确认真实可空性。

- [ ] **Step 4: 跑绿**

Run: `cd hibiki && flutter test test/sync/hibiki_library_host_service_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/app_model_library_host_service.dart hibiki/test/sync/hibiki_library_host_service_test.dart
git commit -m "feat(sync): AppModel-backed host library service for live dictionary sync"
```

---

### Task 3：host 端点 — `/api/capabilities` + `/api/library/dictionaries`（GET 列表 / GET 单个 / PUT / DELETE）

**Files:**
- Modify: `hibiki/lib/src/sync/hibiki_sync_server.dart`
- Test: `hibiki/test/sync/hibiki_sync_server_library_test.dart`

- [ ] **Step 1: 写失败测试**（真实 server bind loopback + 注入 fake `HibikiLibraryHostService`，HTTP 打端点）

```dart
// hibiki/test/sync/hibiki_sync_server_library_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/hibiki_sync_server.dart';

class _FakeLibraryService implements HibikiLibraryHostService {
  final List<RemoteDictionaryInfo> dicts = <RemoteDictionaryInfo>[
    const RemoteDictionaryInfo(name: 'JMdict', type: 'term'),
  ];
  final List<String> deleted = <String>[];
  final List<String> imported = <String>[];

  @override
  Future<List<RemoteDictionaryInfo>> listDictionaries() async => dicts;
  @override
  Future<File> exportDictionary(String name) async {
    final File f = File(
        '${Directory.systemTemp.createTempSync().path}/$name.hibikidict');
    f.writeAsStringSync('PKG:$name');
    return f;
  }
  @override
  Future<void> importDictionary(File packageFile) async =>
      imported.add(await packageFile.readAsString());
  @override
  Future<void> deleteDictionary(String name) async => deleted.add(name);
}

void main() {
  late HibikiSyncServer server;
  late _FakeLibraryService lib;
  const String token = 'test-token';
  late String base;
  String authHeader() => 'Basic ${base64Encode(utf8.encode('hibiki:$token'))}';

  setUp(() async {
    lib = _FakeLibraryService();
    server = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_srv').path,
      port: 0, token: token, allowLan: false, libraryService: lib,
    );
    await server.start();
    base = 'http://127.0.0.1:${server.port}';
  });
  tearDown(() async => server.stop());

  test('GET /api/capabilities reports liveDictionaries true', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/capabilities'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final Map<String, dynamic> json = jsonDecode(
        await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    expect((json['liveLibrary'] as Map)['dictionaries'], true);
    c.close();
  });

  test('GET /api/library/dictionaries lists host dictionaries', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/dictionaries'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    final List<dynamic> json =
        jsonDecode(await res.transform(utf8.decoder).join()) as List<dynamic>;
    expect((json.first as Map)['name'], 'JMdict');
    c.close();
  });

  test('GET /api/library/dictionaries/<name> streams package bytes', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/dictionaries/JMdict'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 200);
    expect(await res.transform(utf8.decoder).join(), 'PKG:JMdict');
    c.close();
  });

  test('PUT /api/library/dictionaries/<name> imports body', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.putUrl(Uri.parse('$base/api/library/dictionaries/NHK'));
    req.headers.set('authorization', authHeader());
    req.add(utf8.encode('PKG:NHK'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 201, 204));
    expect(lib.imported, contains('PKG:NHK'));
    c.close();
  });

  test('DELETE /api/library/dictionaries/<name> deletes', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.deleteUrl(Uri.parse('$base/api/library/dictionaries/JMdict'));
    req.headers.set('authorization', authHeader());
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, anyOf(200, 204));
    expect(lib.deleted, contains('JMdict'));
    c.close();
  });

  test('unauthenticated request to /api/library is 401', () async {
    final HttpClient c = HttpClient();
    final HttpClientRequest req =
        await c.getUrl(Uri.parse('$base/api/library/dictionaries'));
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 401);
    c.close();
  });

  test('library endpoints 404 when no service injected', () async {
    final HibikiSyncServer bare = HibikiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync().path,
      port: 0, token: token, allowLan: false, // libraryService: null
    );
    await bare.start();
    final HttpClient c = HttpClient();
    final HttpClientRequest req = await c.getUrl(Uri.parse(
        'http://127.0.0.1:${bare.port}/api/library/dictionaries'));
    req.headers.set('authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}');
    final HttpClientResponse res = await req.close();
    expect(res.statusCode, 404);
    c.close();
    await bare.stop();
  });
}
```

- [ ] **Step 2: 跑红**

Run: `cd hibiki && flutter test test/sync/hibiki_sync_server_library_test.dart`
Expected: FAIL（构造器无 `libraryService` 命名参数 / 端点未实现）

- [ ] **Step 3: 实现**（改 `hibiki_sync_server.dart`）

3a. 顶部加 `import 'package:hibiki/src/sync/hibiki_library_host_service.dart';`；`import 'dart:async';`（若无）。

3b. 构造器加命名参数 `HibikiLibraryHostService? libraryService,`，初始化列表加 `_libraryService = libraryService`，类内加字段 `final HibikiLibraryHostService? _libraryService;`。

3c. `_handleRequest` 在 `/api/mine` 分支后、真实文件路径处理（`final fsPath = ...`）前，加路由：

```dart
    if (reqPath == '/api/capabilities') {
      if (method != 'GET') return shelf.Response(405);
      return _handleCapabilities();
    }
    if (reqPath == '/api/library/dictionaries' ||
        reqPath.startsWith('/api/library/dictionaries/')) {
      return _handleLibraryDictionaries(request, method, reqPath);
    }
```

3d. 新增 handlers：

```dart
  shelf.Response _handleCapabilities() {
    final bool dict = _libraryService != null;
    return _jsonResponse(<String, dynamic>{
      'liveLibrary': <String, dynamic>{
        'dictionaries': dict,
        'books': false, // Phase 2 落地时改真值
        'audio': false, // Phase 3 落地时改真值
      },
    });
  }

  Future<shelf.Response> _handleLibraryDictionaries(
      shelf.Request request, String method, String reqPath) async {
    final HibikiLibraryHostService? svc = _libraryService;
    if (svc == null) return shelf.Response.notFound('Library service off');

    if (reqPath == '/api/library/dictionaries') {
      if (method != 'GET') return shelf.Response(405);
      final List<RemoteDictionaryInfo> list = await svc.listDictionaries();
      return shelf.Response.ok(
        jsonEncode(<Map<String, Object?>>[
          for (final RemoteDictionaryInfo d in list) d.toJson()
        ]),
        headers: <String, String>{'Content-Type': 'application/json'},
      );
    }

    final String name = Uri.decodeComponent(
        reqPath.substring('/api/library/dictionaries/'.length));
    if (name.isEmpty) return shelf.Response.notFound('Missing dictionary name');

    switch (method) {
      case 'GET':
        File file;
        try {
          file = await svc.exportDictionary(name);
        } on StateError {
          return shelf.Response.notFound('Dictionary not found');
        }
        final int length = file.lengthSync();
        // 流式回传，body 写完后删临时文件（及其父临时目录）。
        final Stream<List<int>> body = file.openRead().transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleDone: (EventSink<List<int>> out) {
              out.close();
              try {
                file.parent.deleteSync(recursive: true);
              } catch (_) {/* best-effort temp cleanup */}
            },
          ),
        );
        return shelf.Response.ok(body, headers: <String, String>{
          'Content-Type': 'application/octet-stream',
          'Content-Length': '$length',
        });
      case 'PUT':
        final Directory tmpDir =
            Directory.systemTemp.createTempSync('hibiki_dict_in');
        final File tmp = File(p.join(tmpDir.path, '$name.hibikidict'));
        final IOSink sink = tmp.openWrite();
        try {
          await request.read().forEach(sink.add);
          await sink.close();
          await svc.importDictionary(tmp);
          return shelf.Response(200);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {/* best-effort */}
          return shelf.Response(500, body: 'Import failed: $e');
        } finally {
          try {
            tmpDir.deleteSync(recursive: true);
          } catch (_) {/* best-effort */}
        }
      case 'DELETE':
        await svc.deleteDictionary(name);
        return shelf.Response(204);
      default:
        return shelf.Response(405);
    }
  }
```

- [ ] **Step 4: 跑绿**

Run: `cd hibiki && flutter test test/sync/hibiki_sync_server_library_test.dart`
Expected: PASS（含 401、404-when-null 守卫）

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/hibiki_sync_server.dart hibiki/test/sync/hibiki_sync_server_library_test.dart
git commit -m "feat(sync): host live dictionary endpoints + capabilities probe"
```

---

### Task 4：client live 方法（探测 + 列表 + get/put/delete 端点）

**Files:**
- Modify: `hibiki/lib/src/sync/hibiki_client_sync_backend.dart`
- Test: `hibiki/test/sync/hibiki_client_live_dict_test.dart`

- [ ] **Step 1: 写失败测试**（client 连真 server 跑 round-trip + 旧 host 探测回退）

```dart
// hibiki/test/sync/hibiki_client_live_dict_test.dart
// 起真实 HibikiSyncServer（注入 _FakeLibraryService，可从 Task3 复用同款 fake），
// 用 HibikiClientSyncBackend.withProbe((url, token) async => true) 强制 reachable，
// 经 SyncRepository 配置 setHibikiClientUrls([HibikiClientUrl(url: base, enabled: true)])
//   + setHibikiClientToken(token)，再 restoreAuth(repo) + authenticate(repo: repo)。
// 断言：
//   - listRemoteDictionaries().map((d)=>d.name) 含 'JMdict'
//   - getRemoteDictionary('JMdict', dest) 写出 'PKG:JMdict'
//   - putRemoteDictionary('NHK', file) 后 fake.imported contains 'PKG:NHK'
//   - deleteRemoteDictionary('JMdict') 后 fake.deleted contains 'JMdict'
// repo 用内存 DB：SyncRepository(HibikiDatabase(NativeDatabase.memory()))；
// HibikiClientUrl 来自 sync_repository.dart（按其真实构造签名）。
```

- [ ] **Step 2: 跑红**

Run: `cd hibiki && flutter test test/sync/hibiki_client_live_dict_test.dart`
Expected: FAIL（live 方法未定义）

- [ ] **Step 3: 实现**（在 `HibikiClientSyncBackend` 末尾加 live 区，复用 `_ops`/`_ensureResolved`）

```dart
  // ── Live library (interconnect-only) ──────────────────────────────
  // host 升级为「库感知」后，client 直读对端实时词典，彻底不经 __dictionaries__。
  // 无旧设备，互联恒走 live（无能力探测）；分流由 orchestrator 按后端类型判定。

  /// host 根 origin（folder 路径是 `${baseUrl}/$kSyncRootFolderName/`，故 /api 在 `${baseUrl}/api/...`）。
  String get _apiBase => _ops!.baseUrl;

  Future<List<RemoteDictionaryInfo>> listRemoteDictionaries() async {
    await _ensureResolved();
    final HttpClientRequest req =
        await _ops!.buildRequest('GET', '$_apiBase/api/library/dictionaries');
    final HttpClientResponse res = await req.close();
    _ops!.checkStatus(res.statusCode, 'GET /api/library/dictionaries');
    final String bodyStr = await res.transform(utf8.decoder).join();
    final List<dynamic> arr = jsonDecode(bodyStr) as List<dynamic>;
    return <RemoteDictionaryInfo>[
      for (final dynamic e in arr)
        RemoteDictionaryInfo.fromJson((e as Map).cast<String, Object?>()),
    ];
  }

  Future<void> getRemoteDictionary(String name, File destination,
      {void Function(double progress)? onProgress}) async {
    await _ensureResolved();
    await downloadContentFile(
      fileId: '$_apiBase/api/library/dictionaries/${Uri.encodeComponent(name)}',
      destination: destination,
      onProgress: onProgress,
    );
  }

  Future<void> putRemoteDictionary(String name, File file,
      {void Function(double progress)? onProgress}) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest('PUT',
        '$_apiBase/api/library/dictionaries/${Uri.encodeComponent(name)}');
    final int length = await file.length();
    req.headers.set('Content-Type', 'application/octet-stream');
    req.headers.set('Content-Length', '$length');
    int sent = 0;
    await req.addStream(file.openRead().map((List<int> chunk) {
      sent += chunk.length;
      onProgress?.call(length > 0 ? sent / length : 0);
      return chunk;
    }));
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'PUT /api/library/dictionaries/$name');
  }

  Future<void> deleteRemoteDictionary(String name) async {
    await _ensureResolved();
    final HttpClientRequest req = await _ops!.buildRequest('DELETE',
        '$_apiBase/api/library/dictionaries/${Uri.encodeComponent(name)}');
    final HttpClientResponse res = await req.close();
    await res.drain<void>();
    _ops!.checkStatus(res.statusCode, 'DELETE /api/library/dictionaries/$name');
  }
```

顶部确保 `import 'dart:convert';`、`import 'package:hibiki/src/sync/hibiki_library_host_service.dart';`。无探测缓存字段、不改 `clearCache()`。

> 校验点：`WebDavOps.buildRequest(method, path)` 接受绝对 URL（既有 `uploadContentFile`/`downloadContentFile` 传绝对 href 已证）。

- [ ] **Step 4: 跑绿**

Run: `cd hibiki && flutter test test/sync/hibiki_client_live_dict_test.dart`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/hibiki_client_sync_backend.dart hibiki/test/sync/hibiki_client_live_dict_test.dart
git commit -m "feat(sync): client live dictionary endpoint methods + capability probe"
```

---

### Task 5：orchestrator 分流 `_syncDictionariesLive` + 暂存路径改名保留

**Files:**
- Modify: `hibiki/lib/src/sync/sync_orchestrator.dart`
- Test: `hibiki/test/sync/sync_orchestrator_live_dict_test.dart`

- [ ] **Step 1: 写失败测试**（live：toPull import、toPush put、绝不创建 `__dictionaries__`；旧 host fallback 建暂存）

```dart
// hibiki/test/sync/sync_orchestrator_live_dict_test.dart
// 用例 A（live）：起真实 HibikiSyncServer（fake library：host 有 [明镜]）；
//   本地内存 DB 有 [JMdict] + 资源目录；HibikiClientSyncBackend.withProbe→true 指向 server，
//   经 repo 配置 url+token+auth。构造 SyncOrchestrator（参考既有 sync_orchestrator_test.dart:150-170
//   的构造参数：db/backend/dictionaryResourceRoot/audioDatabaseRoot/tempDir/syncDictionary:true...）。
//   跑 orchestrator.run()（或暴露的 syncDictionaries 入口）后断言：
//     - 本地 DB 现含 '明镜'（pull import 成功）
//     - fake library.imported 含 'JMdict' 的包内容（push 成功）
//     - server 的 sync-data 目录下【不存在】 __dictionaries__ 文件夹
// 用例 B（云后端不走 live）：用一个非 HibikiClient 的 fake/内存后端跑 syncDictionaries，
//   断言仍走 _syncDictionariesStaged（创建 __dictionaries__ 命名空间），证明云后端路径未破坏。
//   （现有 sync_orchestrator_test.dart 已覆盖 staged 主体，此处只补「互联=live、云=staged」分流断言。）
```

- [ ] **Step 2: 跑红**

Run: `cd hibiki && flutter test test/sync/sync_orchestrator_live_dict_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**（拆分 + 分流）

3a. 把现有 `syncDictionaries` 方法体整体重命名为 `_syncDictionariesStaged`（签名不变，仅改名）。

3b. 新增分流入口 + live 实现，顶部加 `import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';`、`import 'package:hibiki/src/sync/hibiki_library_host_service.dart';`：

```dart
  /// Union-syncs dictionaries. 互联（HibikiClient）→ 直读对端实时库（无暂存）；
  /// 云后端 → 走现有 __dictionaries__ 暂存路径（不变）。无旧设备故无能力探测。
  Future<void> syncDictionaries(SyncRunReport report) async {
    final SyncBackend b = _backend;
    if (b is HibikiClientSyncBackend) {
      await _syncDictionariesLive(report, b);
      return;
    }
    await _syncDictionariesStaged(report);
  }

  /// 互联直读对端实时词典：按名 union，绝不创建/读写 __dictionaries__。
  Future<void> _syncDictionariesLive(
      SyncRunReport report, HibikiClientSyncBackend backend) async {
    final List<DictionaryMetaRow> localDicts =
        await _db.getAllDictionaryMetadata();
    final List<RemoteDictionaryInfo> remoteDicts =
        await backend.listRemoteDictionaries();

    final DictionarySyncDiff diff = computeDictionarySyncDiff(
      localNames: <String>{
        for (final DictionaryMetaRow d in localDicts) d.name
      },
      remoteNames: <String>{
        for (final RemoteDictionaryInfo d in remoteDicts) d.name
      },
    );

    final int total = diff.toPull.length + diff.toPush.length;
    int index = 0;

    for (final String name in diff.toPull) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await backend.getRemoteDictionary(name, tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: name,
                fileFraction: f));
        await _packages.importDictionaryPackage(
          packageFile: tmp,
          dictionaryResourceRoot: _dictionaryResourceRoot,
        );
        report.dictionariesImported++;
      } catch (e) {
        report.errors.add('pull dictionary "$name": $e');
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }

    for (final String name in diff.toPush) {
      _emit(SyncPhase.dictionaries,
          itemIndex: index, itemTotal: total, title: name);
      File? tmp;
      try {
        tmp = _tmpFile(_dictionaryAssetSuffix);
        await _packages.exportDictionaryPackage(
          dictionaryName: name,
          dictionaryResourceRoot: _dictionaryResourceRoot,
          outputFile: tmp,
        );
        await backend.putRemoteDictionary(name, tmp,
            onProgress: (double f) => _emit(SyncPhase.dictionaries,
                itemIndex: index,
                itemTotal: total,
                title: name,
                fileFraction: f));
        report.dictionariesExported++;
      } catch (e) {
        report.errors.add('push dictionary "$name": $e');
      } finally {
        _safeDelete(tmp);
      }
      index++;
    }
  }
```

> 注：`_tmpFile`/`_safeDelete`/`_dictionaryAssetSuffix`/`_emit`/`_packages`/`_dictionaryResourceRoot` 均为现有私有成员（见现 `_syncDictionariesStaged`/`syncDictionaries` 体），直接复用。

- [ ] **Step 4: 跑绿**

Run: `cd hibiki && flutter test test/sync/sync_orchestrator_live_dict_test.dart test/sync/sync_orchestrator_test.dart`
Expected: PASS（含旧暂存路径回归）

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/sync_orchestrator.dart hibiki/test/sync/sync_orchestrator_live_dict_test.dart
git commit -m "feat(sync): orchestrator routes interconnect dictionaries to live path (no staging)"
```

---

### Task 6：注入接线（controller + AppModel）+ 删除传播走 live

**Files:**
- Modify: `hibiki/lib/src/sync/hibiki_server_controller.dart`
- Modify: `hibiki/lib/src/models/app_model.dart`
- Test: `hibiki/test/sync/server_lifecycle_appmodel_guard_test.dart`（追加源码守卫）+ `hibiki/test/sync/dictionary_delete_propagation_test.dart`（追加 live 分支）

- [ ] **Step 1: 写失败测试**

源码守卫（host 真机注入无法 headless 验，故守住接线不回退）：

```dart
// 追加到 hibiki/test/sync/server_lifecycle_appmodel_guard_test.dart：
test('controller forwards libraryService into HibikiSyncServer', () {
  final String src =
      File('lib/src/sync/hibiki_server_controller.dart').readAsStringSync();
  expect(src.contains('libraryService:'), isTrue,
      reason: 'controller 必须把库服务注入 server，否则 host 端点恒 404');
});
test('AppModel wires AppModelLibraryHostService into the controller', () {
  final String src = File('lib/src/models/app_model.dart').readAsStringSync();
  expect(src.contains('AppModelLibraryHostService'), isTrue);
  expect(src.contains('libraryServiceFactory'), isTrue);
});
```

删除传播 live 分支（复用 `dictionary_delete_propagation_test.dart` 范式）：起真实 server + fake library，client 配置指向它，调 `_propagateDictionaryDeleteToRemote` 等价入口（或直接验 backend 选择），断言 live 时调 `deleteRemoteDictionary`（fake.deleted 命中）而非 `deleteAsset(__dictionaries__)`。

- [ ] **Step 2: 跑红**

Run: `cd hibiki && flutter test test/sync/server_lifecycle_appmodel_guard_test.dart test/sync/dictionary_delete_propagation_test.dart`
Expected: FAIL

- [ ] **Step 3: 实现**

3a. `hibiki_server_controller.dart`：顶部 `import 'package:hibiki/src/sync/hibiki_library_host_service.dart';`；构造器加 `HibikiLibraryHostService Function()? libraryServiceFactory,` + 字段 `final HibikiLibraryHostService Function()? _libraryServiceFactory;` + 初始化；`start()` 里构造 `HibikiSyncServer(... libraryService: _libraryServiceFactory?.call())`。

3b. `app_model.dart` 顶部 `import 'package:hibiki/src/sync/app_model_library_host_service.dart';`、`import 'package:hibiki/src/sync/sync_asset_package_service.dart';`、`import 'package:hibiki/src/sync/sync_auto_trigger.dart';`（如未导入）。构造 `HibikiSyncServerController(...)` 处加：

```dart
  libraryServiceFactory: () => AppModelLibraryHostService(
    db: _database,
    dictionaryResourceRoot: dictionaryResourceDirectory,
    packages: SyncAssetPackageService(db: _database),
    refreshDictionaryCache: () => _reloadDictionaryCache(), // ← 用 AppModel 真实刷新词典缓存方法
    runExclusive: runExclusiveWithSync,
  ),
```

> 执行时确认 AppModel 内刷新词典内存缓存的真实方法名（搜 `dictionaryCache` / `reloadDict` / `_loadDictionaries` / `refreshDictionaries`），替换 `_reloadDictionaryCache()`；若无则用 `DictionaryRepository` 的对应刷新或留空 `() async {}`（导入后下次查词自然 miss→FFI 重载，确认现有 import 路径如何刷新缓存后对齐）。

3c. `_propagateDictionaryDeleteToRemote(String name)` 现体（用 `deleteRemoteDictionaryAsset(backend, name)`）前加分流：

```dart
    if (backend is HibikiClientSyncBackend) {
      await backend.deleteRemoteDictionary(name);
      return;
    }
    // 云后端暂存删除路径不变：
    await deleteRemoteDictionaryAsset(backend, name);
```

（顶部确保已 `import 'package:hibiki/src/sync/hibiki_client_sync_backend.dart';`。）

- [ ] **Step 4: 跑绿**

Run: `cd hibiki && flutter test test/sync/`
Expected: PASS（全 sync 目录绿）

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/hibiki_server_controller.dart hibiki/lib/src/models/app_model.dart hibiki/test/sync/server_lifecycle_appmodel_guard_test.dart hibiki/test/sync/dictionary_delete_propagation_test.dart
git commit -m "feat(sync): wire host library service + route dict delete propagation to live endpoint"
```

---

### Task 7：全量验证 + analyze + 格式化

- [ ] **Step 1:** `cd hibiki && dart format .`
- [ ] **Step 2:** `cd hibiki && flutter analyze`（Expected: 0；CI 把 warning/info 也当致命，必须全清）
- [ ] **Step 3:** `cd hibiki && flutter test`（Expected: 全绿；若有 develop 预存红，对照 base 确认非本改动引入）
- [ ] **Step 4: 提交**（仅当格式化产生改动）

```bash
git add -u hibiki/lib hibiki/test
git commit -m "style(sync): dart format for interconnect live dictionary sync"
```

- [ ] **Step 5: 真机验证（交用户）** — 双设备互联：手机↔电脑，跑词典 live 双向同步、删除双向传播、与「旧 host（不注入库服务）」fallback 回暂存、断网中断恢复。证据存 `.codex-test/`。**用户验证通过前不进 Phase 2。**

---

## Phase 2 — 书籍内容实时直读（后续独立计划，待 Phase 1 真机验证后展开）

复用 Phase 1 模式扩到书籍：
- host 服务加 `listBooks()`（`db.getAllEpubBooks()` → `[{title, hasContent}]`）、`exportBook(title)`（`repackageExtractedEpub` 即时打包 `extractDir`→.epub，`sync_manager.dart:27-42`）、`importBook(epubFile)`（`EpubImporter` 路径）。
- host 端点 `/api/library/books`（GET 列表 / GET `<title>` 流式 epub / PUT 导入 / DELETE）；capabilities `books: true`。
- client `supportsLiveBooks()` + 对应方法；orchestrator 把 `importRemoteBooks`（`sync_orchestrator.dart:256`）在互联 live 时改走端点（不经书文件夹 + .epub 暂存）。
- **保持现有 per-book 轻量元数据（进度/统计/有声书位置，`SyncManager`）路径不变**，live 只接管「内容文件（epub/音频）」收发。
- 全 TDD + 真机验证。

## Phase 3 — 有声书 + 本地音频实时直读（后续独立计划）

- host 服务加 audiobook / local-audio 的 list/export/import/delete（复用 `SyncAssetPackageService.exportAudioDatabasePackage`/`importAudioDatabasePackage`/`exportLocalAudioPackage`/`importLocalAudioPackage`）。
- host 端点 `/api/library/audiobooks`、`/api/library/localaudio`；capabilities `audio: true`。
- client 方法 + orchestrator `syncLocalAudioPackages`（`sync_orchestrator.dart:395`）与有声书包同步的 live 分支（替换 `__local_audio__` 等暂存命名空间）。
- **大文件**：音频 GB 级，host export 即时打包 + 流式回传，client 边下边写；进度回调贯通；超时按既有 8s/GB clamp 范式。
- 全 TDD + 真机验证。

---

## Self-Review（对照核心约束自查）

- **无旧设备，互联恒 live**（约束 2）：Task 5 分流纯按 `is HibikiClientSyncBackend`；云后端走 `_syncDictionariesStaged`（Task 5 用例 B + 现有 `sync_orchestrator_test.dart` 覆盖）。Task 3 `/api/capabilities` 端点保留作信息用途但 client 不依赖它。✅
- **鉴权**（约束 3）：Task 3「unauthenticated → 401」覆盖（复用现有 `_authMiddleware`，无新鉴权代码）。✅
- **host 库变动串行**（约束 4）：`AppModelLibraryHostService.importDictionary/deleteDictionary` 经 `_runExclusive`，Task 6 注入 `runExclusiveWithSync`。✅
- **流式**（约束 5）：host GET `file.openRead()`+Content-Length（transformer onDone 删临时）；PUT `request.read().forEach(sink.add)`；client put `addStream`、get 复用 `downloadContentFile` 边下边写。✅
- **删除正交**（约束 6）：Task 6 `_propagateDictionaryDeleteToRemote` live 走 `DELETE` 端点，union diff 不推断删除。✅
- **不破坏云后端/旧 peer**（约束 1）：live 仅 `_backend is HibikiClientSyncBackend && 探测` 才进；`_syncDictionariesStaged` 原样保留；Task 5 回归旧 `sync_orchestrator_test.dart`。✅
- **类型一致**：`RemoteDictionaryInfo`/`DictionarySyncDiff`/`computeDictionarySyncDiff`/`HibikiLibraryHostService`(listDictionaries/exportDictionary/importDictionary/deleteDictionary)/`AppModelLibraryHostService` 在 Task1-2 定义、Task3-6 一致引用；client 方法名 `listRemoteDictionaries`/`getRemoteDictionary`/`putRemoteDictionary`/`deleteRemoteDictionary` 在 Task4 定义、Task5-6 一致引用（已去掉 `supportsLiveDictionaries` 探测）。✅
- **占位扫描**：Task 3 GET 临时清理给了最终 transformer 实现；其余步骤含真实代码或明确「执行时按真实类型/方法名校验」的具体校验点（非 TODO）。Phase 2/3 标为「后续独立计划展开」属合法 scope 分解。✅
- **遗留校验点**（执行时必须确认，已在对应步骤标注）：① `DictionaryMetaRow.type` 可空性；② AppModel 刷新词典缓存的真实方法名；③ `WebDavOps.buildRequest` 接受绝对 URL（既有 content file 路径已证）；④ `HibikiClientUrl` 构造签名（`sync_repository.dart`）；⑤ `SyncOrchestrator` 测试构造参数（`sync_orchestrator_test.dart:150-170`）。
