# 本地音频来源云同步（配置 + DB 文件）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development。所有派生子代理 `model: "opus"`（CLAUDE.md）。Steps 用 `- [ ]`。

**Goal:** 在同步设置加「同步本地音频」开关；打开后把本地音频来源（`LocalAudioDbEntry`：发音 DB 文件 + displayName/enabled/子来源偏好）像词典包那样双向云同步到其它设备，DB 文件复用 Part A 的 STORE 流式打包。

**Architecture:** 完全镜像现有「词典同步」链路（toggle → orchestrator 阶段 → SyncAssetPackageService 包 → 后端命名空间）。两点不同：①DB 文件大且是二进制 → 用 STORE 流式（`storeResources:true`）；②本地音频配置存 preferences 的双真相源（`local_audio_dbs` + `audio_source_configs`）且 orchestrator 不同步 preferences 表 → 配置走**包 manifest** 携带，导入侧经 AppModel 复用 `setAudioSourceConfigs` 重建本机 path 并保持两源一致 + 推 native + 刷 UI。orchestrator 不依赖 AppModel，靠 sync_auto_trigger 注入「条目列表」+「导入回调」。

**Tech Stack:** Dart 3.12/Flutter 3.44；`archive_io`（已有流式 helper）；Drift preferences；既有 `LocalAudioManager`/`AudioSourceConfig`。

**身份/去重：** 跨设备资产名 = `displayName`（`LocalAudioDbEntry.path` 含本机时间戳，每机不同，不可用）。push 本地独有（displayName 不在远端）/pull 远端独有（displayName 不在本地）。displayName 无唯一约束 → 撞名按「同一库」union 跳过（与词典按 name 同语义），代码注释标注该限制。

**范围：** 本期做 toggle + orchestrator 同步 + 包格式 + 导入注册 + 测试。**对比对话框的本地音频分组**（`SyncLocalAudioEntry`）列为 follow-up，不在本期。

---

## 已验证接点（file:line，动手前必读）

- 配置 pref key `'local_audio_dbs'`（JSON 数组）；`LocalAudioManager.entries` getter `local_audio_manager.dart:82`，`setEntries` `:104-111`（写 pref + `TtsChannel.setLocalAudioDbs` 推 native）。
- DB 文件：单 sqlite `.db`（可带 `-wal`/`-shm` 旁文件），落 `databaseDirectory`（= `getApplicationSupportDirectory()`，`app_model.dart:1077/1143`）；内部名 `local_audio_<millis>.db`（`local_audio_manager.dart:136-139`）。
- `importFile(sourcePath, displayName)` `local_audio_manager.dart:132-149`：拷进库目录返回本机 path 的 entry（不写 pref）。`AppModel.importLocalAudioDbFile` `app_model.dart:2653-2657` 转发它。
- `setAudioSourceConfigs(List<AudioSourceConfig>)` `app_model.dart:2601-2626`：写 `audio_source_configs` + **从中推导** `local_audio_dbs`（:2606-2620，按 `source.path` 保留既有 sources）+ `setEntries` 推 native + `pruneOrphans` 回收孤儿。**这是保持双真相源一致的唯一正确写入口。**
- `localAudioDbs` getter `app_model.dart:2649`；`setLocalAudioDbSources(path, prefs)` `:2675-2679`（设子来源 + notifyListeners）。
- `LocalAudioSourcePref{name,enabled}` `local_audio_source_pref.dart:9-38`（fromJson/toJson 齐全）。
- 词典同步模板：`SyncRepository.isSyncDictionaryEnabled` `sync_repository.dart:110-113`（key `:40`，默认 false）；`kSyncDictionaryNamespace='__dictionaries__'` + `isReservedSyncFolderName` `sync_orchestrator.dart:16/27`；`syncDictionaries` `:201-257`；`run()` 门控 `:142`；构造参数 `syncDictionary` `:91/110/123`。包：`exportDictionaryPackage`/`importDictionaryPackage` `sync_asset_package_service.dart:15-87`（流式 helper `:418-553`）。
- 后端原语（`SyncAssetStore`）：`ensureNamespace` `:30`、`listChildren` `:36`、`putAsset` `:42`、`getAsset` `:50`、`AssetEntry{id,name,isFolder}` `:4-24`。
- 设置 UI：词典开关 `sync_settings_schema.dart:162-173`（Group3 「what to sync」）；`_SyncSettingsState.syncDictionary` 字段 `:2459`、`load()` `:2502`。
- 报告汇总：`SyncRunReport` `sync_orchestrator.dart:57-65`；`summarizeSyncReport` `sync_settings_schema.dart:272-289`。
- sync_auto_trigger：`runManualFullSync` `sync_auto_trigger.dart:153-192`、`triggerAutoSyncOnAppOpen`/`_runAutoSyncAll` `:68-139`，两处构造 `SyncOrchestrator`。
- **风险**：orchestrator `run()` 不同步 preferences 表（`sync_orchestrator.dart:123-145`）→ 配置必须走包 manifest；导入必须本机重建 path（远端绝对 path 文件不存在会被 `bindForNativeHandler` 静默跳过 `local_audio_manager.dart:211-215`）；双真相源必须经 `setAudioSourceConfigs` 一致写入。

---

### Task LA1: SyncRepository 加同步开关

**Files:** Modify `hibiki/lib/src/sync/sync_repository.dart`

- [ ] **Step 1**：仿 `_keySyncDictionary`（:40）加 key 常量，仿 `isSyncDictionaryEnabled`/`setSyncDictionaryEnabled`（:110-113）加 getter/setter（默认 **false**）：

```dart
  static const _keySyncLocalAudio = 'sync_local_audio_enabled';
```
```dart
  /// 是否同步本地音频来源（DB 文件 + 配置）。默认 false：DB 大，需用户显式开启。
  Future<bool> isSyncLocalAudioEnabled() =>
      _db.getPrefTyped<bool>(_keySyncLocalAudio, false);
  Future<void> setSyncLocalAudioEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncLocalAudio, v);
```
**不要**把 `_keySyncLocalAudio` 或 `'local_audio_dbs'` 加进 `deviceLocalPrefKeys`（:512-537）。

- [ ] **Step 2**：`flutter test test/sync/sync_repository_test.dart`（若有相关用例则确认绿；本步主要确保编译）。`dart analyze lib/src/sync/sync_repository.dart` → 0。
- [ ] **Step 3**：Commit（只 add `sync_repository.dart`，禁 `git add -A`）：`feat(sync): add local-audio sync toggle (default off)`

---

### Task LA2: SyncAssetPackageService 加本地音频包 export/import

**Files:** Modify `hibiki/lib/src/sync/sync_asset_package_service.dart`；Test 扩展 `hibiki/test/sync/sync_asset_package_service_test.dart`

包格式（镜像词典，但资源是单个 .db、用 STORE）：manifest `{schemaVersion:1, kind:'localAudio', localAudio:{displayName, enabled, dbFileName, sources:[{name,enabled}]}}`，资源 `resources/<dbFileName>`。

- [ ] **Step 1**：加导出。`exportLocalAudioPackage` 主 isolate 建 manifest + 单文件清单，调已有 `_zipPackageInIsolate(..., storeResources: true)`（STORE，避免大 DB 整入内存）：

```dart
  /// 打包一个本地音频库：单个 .db（STORE 流式）+ manifest（displayName/enabled/子来源）。
  /// [dbFile] 是该库的本机 .db 主文件（不含 -wal/-shm，导入后由 sqlite 自建）。
  Future<File> exportLocalAudioPackage({
    required String displayName,
    required bool enabled,
    required List<LocalAudioSourcePref> sources,
    required File dbFile,
    required File outputFile,
  }) async {
    final String dbFileName = p.basename(dbFile.path);
    final String manifestJson = jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'kind': 'localAudio',
      'localAudio': <String, Object?>{
        'displayName': displayName,
        'enabled': enabled,
        'dbFileName': dbFileName,
        'sources': sources.map((LocalAudioSourcePref s) => s.toJson()).toList(),
      },
    });
    outputFile.parent.createSync(recursive: true);
    await _zipPackageInIsolate(
      outputPath: outputFile.path,
      manifestJson: manifestJson,
      archivePathToSource: <String, String>{'resources/$dbFileName': dbFile.path},
      storeResources: true,
    );
    return outputFile;
  }
```
需 import `local_audio_source_pref.dart`（`LocalAudioSourcePref`）。

- [ ] **Step 2**：加导入。返回解析内容（不碰 prefs——注册交 AppModel）。先建结果类（文件内顶层）：

```dart
/// [SyncAssetPackageService.importLocalAudioPackage] 的解析结果：已解压到本机
/// staging 目录的 .db 文件 + manifest 携带的配置。注册（拷进库目录/写 prefs/推
/// native）由调用方（AppModel.importSyncedLocalAudioDb）完成。
class LocalAudioPackageContents {
  const LocalAudioPackageContents({
    required this.dbFile,
    required this.displayName,
    required this.enabled,
    required this.sources,
  });
  final File dbFile;
  final String displayName;
  final bool enabled;
  final List<LocalAudioSourcePref> sources;
}
```
```dart
  /// 解析本地音频包：读 manifest + 把 .db 流式解压到 [stagingDir]，返回内容。
  /// 不写任何 prefs / 不推 native（注册由 AppModel 负责，保持双真相源一致 + 本机重建 path）。
  Future<LocalAudioPackageContents> importLocalAudioPackage({
    required File packageFile,
    required Directory stagingDir,
  }) async {
    final String manifestJson = await _readManifestInIsolate(packageFile.path);
    final Map<String, Object?> manifest = _typedMap(jsonDecode(manifestJson));
    if (manifest['kind'] != 'localAudio') {
      throw FormatException('Unexpected package kind: ${manifest['kind']}');
    }
    final Map<String, Object?> meta = _mapValue(manifest, 'localAudio');
    final String displayName = _stringValue(meta, 'displayName');
    final String dbFileName = _stringValue(meta, 'dbFileName');
    final bool enabled = _nullableBool(meta, 'enabled') ?? true;
    final List<LocalAudioSourcePref> sources =
        _listValue(meta, 'sources').map((Object? raw) {
      final Map<String, Object?> m = _typedMap(raw);
      return LocalAudioSourcePref(
        name: _stringValue(m, 'name'),
        enabled: _nullableBool(m, 'enabled') ?? true,
      );
    }).toList();

    await _extractResourcesInIsolate(
      packagePath: packageFile.path,
      targetDirPath: stagingDir.path,
      prefix: 'resources',
    );
    return LocalAudioPackageContents(
      dbFile: File(p.join(stagingDir.path, dbFileName)),
      displayName: displayName,
      enabled: enabled,
      sources: sources,
    );
  }
```
> 注：`LocalAudioSourcePref` 构造形参以 `local_audio_source_pref.dart:9-20` 实际签名为准（核对 `name`/`enabled` 命名）；`_listValue`/`_typedMap`/`_stringValue`/`_nullableBool` 是文件内既有 helper。

- [ ] **Step 3**：测试。在 `sync_asset_package_service_test.dart` 加一组「Local audio sync packages」：
  - 造一个 >2MB 的假 .db 文件（伪随机字节，走 STORE 流式分块），`exportLocalAudioPackage`（displayName/enabled/2 个 sources）→ `importLocalAudioPackage` 到 staging → 断言：解压出的 dbFile 字节 sha256 与源一致、displayName/enabled/sources 还原正确。

- [ ] **Step 4**：`dart analyze lib/src/sync/sync_asset_package_service.dart` 0 issue；`flutter test test/sync/sync_asset_package_service_test.dart` 全绿。
- [ ] **Step 5**：Commit（只 add service + 该 test）：`feat(sync): local-audio package export/import (STORE streaming)`

---

### Task LA3: SyncOrchestrator 加本地音频同步阶段

**Files:** Modify `hibiki/lib/src/sync/sync_orchestrator.dart`；Test 扩展 `hibiki/test/sync/sync_orchestrator_test.dart`

- [ ] **Step 1**：常量 + reserved 过滤。仿 `:16/27`：

```dart
const String kSyncLocalAudioNamespace = '__local_audio__';
const String _localAudioAssetSuffix = '.hibikiaudiolib';
```
`isReservedSyncFolderName`（:27）改为：
```dart
bool isReservedSyncFolderName(String name) =>
    name == kSyncDictionaryNamespace || name == kSyncLocalAudioNamespace;
```

- [ ] **Step 2**：`SyncRunReport` 加计数（:57-65）：`int localAudioImported = 0; int localAudioExported = 0;`

- [ ] **Step 3**：orchestrator 加字段/构造参数 + 注入数据/回调。仿 `syncDictionary`（:91/110）：
  - 构造参数：`required this.syncLocalAudio`、`required this.localAudioEntries`（`List<LocalAudioDbEntry>`，导出用）、`this.onLocalAudioImported`（`Future<void> Function(LocalAudioPackageContents)?`，导入注册回调）。
  - import `local_audio_manager.dart`（`LocalAudioDbEntry`）、`sync_asset_package_service.dart` 已 import（`LocalAudioPackageContents`）。
  - 字段：`final bool syncLocalAudio; final List<LocalAudioDbEntry> localAudioEntries; final Future<void> Function(LocalAudioPackageContents)? onLocalAudioImported;`

- [ ] **Step 4**：`run()`（:142 后）加门控：
```dart
    if (syncLocalAudio) await syncLocalAudioPackages(report);
```

- [ ] **Step 5**：加 `syncLocalAudioPackages`（镜像 `syncDictionaries` :201-257，去重 key=displayName，资源=单 .db）：
```dart
  /// Union-syncs local audio source DBs in the `__local_audio__` namespace.
  /// 资产名 = displayName（path 每机不同不可用）。push 本地独有 / pull 远端独有。
  Future<void> syncLocalAudioPackages(SyncRunReport report) async {
    final String ns = await _backend.ensureNamespace(kSyncLocalAudioNamespace);
    final List<AssetEntry> remote = await _backend.listChildren(ns);

    final Set<String> remoteNames = <String>{
      for (final AssetEntry e in remote)
        if (!e.isFolder && e.name.endsWith(_localAudioAssetSuffix))
          e.name.substring(0, e.name.length - _localAudioAssetSuffix.length),
    };
    final Set<String> localNames = <String>{
      for (final LocalAudioDbEntry d in localAudioEntries) d.displayName,
    };

    // Push local-only.
    for (final LocalAudioDbEntry d in localAudioEntries) {
      if (remoteNames.contains(d.displayName)) continue;
      final File dbFile = File(d.path);
      if (!dbFile.existsSync()) continue;
      File? tmp;
      try {
        tmp = _tmpFile(_localAudioAssetSuffix);
        await _packages.exportLocalAudioPackage(
          displayName: d.displayName,
          enabled: d.enabled,
          sources: d.sources,
          dbFile: dbFile,
          outputFile: tmp,
        );
        await _backend.putAsset(
            ns, '${d.displayName}$_localAudioAssetSuffix', tmp);
        report.localAudioExported++;
      } catch (e) {
        report.errors.add('export local audio "${d.displayName}": $e');
      } finally {
        _safeDelete(tmp);
      }
    }

    // Pull remote-only.
    for (final AssetEntry e in remote) {
      if (e.isFolder || !e.name.endsWith(_localAudioAssetSuffix)) continue;
      final String base = e.name
          .substring(0, e.name.length - _localAudioAssetSuffix.length);
      if (localNames.contains(base)) continue;
      File? tmp;
      try {
        tmp = _tmpFile(_localAudioAssetSuffix);
        await _backend.getAsset(e.id, tmp);
        final LocalAudioPackageContents contents =
            await _packages.importLocalAudioPackage(
          packageFile: tmp,
          stagingDir: _tempDir,
        );
        if (onLocalAudioImported != null) {
          await onLocalAudioImported!(contents);
          report.localAudioImported++;
        }
      } catch (err) {
        report.errors.add('import local audio "${e.name}": $err');
      } finally {
        _safeDelete(tmp);
      }
    }
  }
```

- [ ] **Step 6**：测试。在 `sync_orchestrator_test.dart` 仿现有词典/有声书阶段用例，用 fake backend 验：①本地有、远端无 → 调 `putAsset`（export 计数+1）；②远端有、本地无 → `getAsset` + `onLocalAudioImported` 被调（import 计数+1，回调收到正确 displayName/enabled）；③displayName 两边都有 → 跳过。`syncLocalAudio:false` 时整阶段不跑。

- [ ] **Step 7**：`dart analyze lib/src/sync/sync_orchestrator.dart` 0；`flutter test test/sync/sync_orchestrator_test.dart` 绿。
- [ ] **Step 8**：Commit（add orchestrator + test）：`feat(sync): local-audio union sync phase in orchestrator`

---

### Task LA4: sync_auto_trigger 注入条目 + 回调

**Files:** Modify `hibiki/lib/src/sync/sync_auto_trigger.dart`

- [ ] **Step 1**：给 `runManualFullSync`（:153）与 `triggerAutoSyncOnAppOpen`/`_runAutoSyncAll`（:68-139）加参数 `required List<LocalAudioDbEntry> localAudioEntries`、`Future<void> Function(LocalAudioPackageContents) onLocalAudioImported`（import `local_audio_manager.dart` + `sync_asset_package_service.dart`）。
- [ ] **Step 2**：两处 `SyncOrchestrator(...)` 构造（:113-124、:172-183）加：
```dart
        syncLocalAudio: await repo.isSyncLocalAudioEnabled(),
        localAudioEntries: localAudioEntries,
        onLocalAudioImported: onLocalAudioImported,
```
- [ ] **Step 3**：`dart analyze lib/src/sync/sync_auto_trigger.dart` —— 此时调用方未传新参数会编译错，**与 LA5 同轮修复**，故本 Task 暂不单独跑、不单独 commit；与 LA5 合并提交。（在报告里说明已知编译中断，LA5 接上。）

---

### Task LA5: AppModel 导入注册 + 接通调用方

**Files:** Modify `hibiki/lib/src/models/app_model.dart`；调用方 `hibiki/lib/src/sync/sync_settings_schema.dart`（手动 `_syncNow`）、以及 app-open 自动同步触发处（grep `triggerAutoSyncOnAppOpen` 的调用点）

- [ ] **Step 1**：**先核对** `AudioSourceConfig.localAudio` 工厂签名（`hibiki/lib/src/models/audio_source_config.dart`）——确认构造本地音频 config 所需字段（path / displayLabel / enabled，可能还有 kind）。按真实签名写下面方法。

- [ ] **Step 2**：AppModel 加导入注册方法（复用 `setAudioSourceConfigs` 保双真相源一致 + 推 native；本机重建 path；displayName 去重）：
```dart
  /// 同步拉到一个远端本地音频库：把 staging 的 .db 拷进本机库目录（重建 path），
  /// 经 setAudioSourceConfigs 双写 audio_source_configs + local_audio_dbs + 推 native，
  /// 再还原子来源偏好并刷 UI。按 displayName 去重（已存在则跳过）。
  Future<void> importSyncedLocalAudioDb(LocalAudioPackageContents c) async {
    final bool exists = audioSourceConfigs.any((AudioSourceConfig s) =>
        s.kind == AudioSourceKind.localAudio &&
        s.displayLabel == c.displayName);
    if (exists) return;
    if (!await c.dbFile.exists()) return;
    final LocalAudioDbEntry entry =
        await importLocalAudioDbFile(c.dbFile.path, displayName: c.displayName);
    final AudioSourceConfig cfg = AudioSourceConfig.localAudio(
      path: entry.path,
      displayLabel: c.displayName,
      enabled: c.enabled,
    ); // ← 字段名以 Step1 核对结果为准
    await setAudioSourceConfigs(<AudioSourceConfig>[...audioSourceConfigs, cfg]);
    if (c.sources.isNotEmpty) {
      await setLocalAudioDbSources(entry.path, c.sources);
    }
    notifyListeners();
  }
```
import `LocalAudioPackageContents`（from sync_asset_package_service.dart）。

- [ ] **Step 3**：接通调用方。`sync_settings_schema.dart` 的 `_syncNow`（runManualFullSync 调用处，~:647）传：
```dart
        localAudioEntries: appModel.localAudioDbs,
        onLocalAudioImported: appModel.importSyncedLocalAudioDb,
```
同样修 app-open 自动同步触发处（grep `triggerAutoSyncOnAppOpen(`，把 `appModel.localAudioDbs` + `appModel.importSyncedLocalAudioDb` 传进去）。

- [ ] **Step 4**：`dart analyze`（app_model + sync_auto_trigger + sync_settings_schema）→ 0 error；`flutter test test/sync/` 全绿。
- [ ] **Step 5**：Commit（add app_model + sync_auto_trigger + sync_settings_schema）：`feat(sync): register synced local-audio DBs via AppModel (consistent dual-write)`

---

### Task LA6: 同步设置加开关 UI + i18n + 报告汇总

**Files:** Modify `hibiki/lib/src/sync/sync_settings_schema.dart`；i18n 经工具；`strings.g.dart` 生成

- [ ] **Step 1**：i18n（禁手改 json）：
```
cd hibiki && dart run tool/i18n_sync.dart --add sync_local_audio "Sync local audio" "同步本地音频"
dart run tool/i18n_sync.dart --add sync_local_audio_warning "Syncs local audio source databases (may be large)" "同步本地音频来源数据库（可能较大）"
dart run slang && dart format lib/i18n/strings.g.dart
```
- [ ] **Step 2**：Group3「what to sync」section（词典开关 :162-173 旁）加：
```dart
      SettingsSwitchItem(
        id: 'sync.local_audio',
        title: (ctx) => t.sync_local_audio,
        subtitle: (ctx) => t.sync_local_audio_warning,
        icon: Icons.graphic_eq_outlined,
        value: (ctx) => _syncSettings(ctx).syncLocalAudio,
        onChanged: (ctx, v) async {
          _syncSettings(ctx).syncLocalAudio = v;
          await SyncRepository(ctx.appModel.database)
              .setSyncLocalAudioEnabled(v);
        },
      ),
```
- [ ] **Step 3**：`_SyncSettingsState` 加字段 `bool syncLocalAudio = false;`（仿 :2459），`load()` 加 `syncLocalAudio = await repo.isSyncLocalAudioEnabled();`（仿 :2502）。
- [ ] **Step 4**：`summarizeSyncReport`（:272-289）加本地音频导入/导出计数行（如 `report.localAudioImported>0` 时追加），i18n 复用现有「imported/exported」句式或新增 key（如需则同样走 i18n_sync）。
- [ ] **Step 5**：`dart format . && dart analyze lib/src/sync/sync_settings_schema.dart` 0；`flutter test test/sync/` 全绿；若有 `sync_settings_visibility_test.dart` 跑一下确认开关项渲染。
- [ ] **Step 6**：Commit（分两个：i18n 一个、schema 一个，或合并）：`feat(sync): local-audio sync settings toggle + report summary`

---

### Task LA7: 登记 docs/BUGS.md（功能项，非 bug）/ 收尾

- [ ] **Step 1**：本功能是新增能力非 bug，**不进 BUGS.md**；改为在 `docs/specs/` 留本计划即可（已在）。如项目有 feature changelog 习惯再记。跳过 BUGS.md。
- [ ] **Step 2 收尾**：`cd hibiki && dart format . && flutter analyze`（0 error）+ `flutter test test/sync/`（全绿）。真机复测（双机：A 机配本地音频库 + 开开关 + 立刻同步 → B 机开开关 + 立刻同步 → B 出现该库且能发音）——设备验证待用户。
- [ ] **Step 3**：调 `superpowers:requesting-code-review`（opus）审全功能。

## 风险 / 注意
1. **双真相源一致**：导入注册**必须**经 `setAudioSourceConfigs`（它从 config 推导 local_audio_dbs 并推 native），不可只改一个。
2. **本机重建 path**：用 `importLocalAudioDbFile`（拷进本机目录 + 本机 path），绝不用远端 manifest 的绝对 path。
3. **大 DB**：导出 STORE 流式（`storeResources:true`），导入走 Part A 的 `_extractResourcesInIsolate` 流式——已支撑数百 MB。
4. **只打包 .db 主文件**：不打 `-wal`/`-shm`（这些音频库是只读导入，sqlite 会自建；若担心未 checkpoint 丢写，可在导出前对该 db 做一次只读打开触发 checkpoint，本期从简只打主文件并注释）。
5. **displayName 撞名**：按 union 跳过，注释标注；唯一性是 follow-up。
6. **i18n 纪律**：新增 key 必走 `tool/i18n_sync.dart` + `dart run slang`，禁手改 17 json / 生成文件。
7. **并发 develop**：只 stage 本轮文件，禁 `git add -A`。
8. **AudioSourceConfig.localAudio 签名**：LA5 Step1 必须先核对真实工厂签名再写注册方法。
9. 对比对话框本地音频分组 = follow-up，本期不做。
