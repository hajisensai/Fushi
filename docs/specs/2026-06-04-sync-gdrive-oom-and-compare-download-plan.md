# 谷歌云盘同步「卡 + 闪退 + 没下载书籍」修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 所有派生子代理必须 `model: "opus"`（CLAUDE.md 规则）。

**Goal:** 手机端用谷歌云盘「立刻同步」不再 OOM 闪退、不再卡死 UI；并让「Local vs Remote」对比对话框能真正把远端独有的书下载到本机。

**Architecture:**
- 卡 + 闪退根因 = `sync_asset_package_service.dart` 全程「整文件 readAsBytes + 整 zip 在内存编/解码」，跑在 UI isolate。修复 = 改用 `archive_io` 流式压缩/解压（`ZipFileEncoder` / `InputFileStream` / `OutputFileStream`，从不整文件入内存），并把纯文件 zip/unzip 放进 `Isolate.run`（DB 读写留主 isolate）。包格式 100% 不变，向后兼容。
- 没下载书籍根因 = 对比对话框设计上排除 remote-only 书（`bookId==null` 强制 skip）。修复 = 抽出可复用的 `importRemoteBookFolder` 单书下载导入函数（orchestrator 与对话框共用），让对话框给 remote-only 书提供「下载」动作。

**Tech Stack:** Dart 3.12 / Flutter 3.44；`archive ^3.6.1`（`archive_io`）；`dart:isolate` `Isolate.run`；Drift；既有 `EpubImporter`（唯一插书入口）。

---

## 已验证的根因（动手前必读）

| 症状 | 根因位置 | 证据 |
|---|---|---|
| 闪退 (OOM) | `sync_asset_package_service.dart` | 导出：`await file.readAsBytes()`（:99 音频 / :295 词典文件）+ `ZipEncoder().encode(archive)!`（:272 整 zip 内存编码）。导入：`ZipDecoder().decodeBytes(await packageFile.readAsBytes())`（:45 词典 / :127 有声书 整包入内存）。词典/有声书包数百 MB → Android 低堆 native OOM。 |
| 卡 (UI 冻结) | 同上 + `sync_orchestrator.run()` | 整个同步链在 UI isolate await 执行，无 `compute`/`Isolate`。zip 编解码 CPU 同步阻塞 event loop。 |
| 没下载书籍 | `sync_compare_dialog.dart` | remote-only 书 `bookId==null`（:204）→ `_load` 强制 skip（:442-443）→ `actionable`（:480-483）/`_actionableCount`（:652-657）要求 `bookId!=null` → 永不下载。唯一下载 remote-only 书的路径是 `sync_orchestrator.importRemoteBooks`（:173），只被全量 `run()` 调用且被 `if(syncContent)`（:127）门控。 |

用户设置：内容同步 + 有声书文件同步 + 词典同步全开，崩在「立刻同步」→ 命中 `syncDictionaries` + `syncAudiobookPackages` 的 OOM 路径。

**工作范例**：`packages/hibiki_dictionary/lib/src/formats/yomichan_dictionary_format.dart:122-158` 已用 `Isolate.run(() { InputFileStream + ZipDecoder().decodeBuffer + 流式解压 })` 处理大词典——本计划套用同一模式。

**安全网**：`test/sync/sync_asset_package_service_test.dart` 已有 export→import 往返测试；流式重写后它必须保持绿（证明包格式不变）。

---

# Part A — 流式 + isolate 化打包服务（修 卡 + 闪退，登记为 BUG-036）

## File Structure

- Modify: `hibiki/lib/src/sync/sync_asset_package_service.dart`
  - 新增 3 个顶层 isolate 辅助函数：`_zipPackageInIsolate` / `_readManifestInIsolate` / `_extractResourcesInIsolate`。
  - 4 个公开方法（`exportDictionaryPackage` / `importDictionaryPackage` / `exportAudioDatabasePackage` / `importAudioDatabasePackage`）改为「主 isolate 读/写 DB + 调用 isolate 辅助做纯文件 zip」。
  - 删除被取代的私有件：`_writeZip`（:270）、`_jsonFile`（:276）、`_addDirectoryFiles`（:281）、`_extractArchivePrefix`（:300）、`_readManifest`（:331）。保留 `_safeDirName`、`_audioPackageFiles`、`_uniqueFileName`、`_resourceName`、各 `_*Value` / `_*Manifest` 辅助。
  - import 改：`dart:convert`、`dart:io` 保留；新增 `dart:isolate`；`package:archive/archive.dart` 改/加 `package:archive/archive_io.dart`（提供 `ZipFileEncoder` / `InputFileStream` / `OutputFileStream`，且 re-export `ArchiveFile`/`ZipDecoder`）。
- Test: `hibiki/test/sync/sync_asset_package_service_test.dart`（扩展，保持既有往返测试）
- Test: `hibiki/test/sync/sync_asset_package_no_inmemory_guard_test.dart`（新建：源码守卫）
- Docs: `docs/BUGS.md`（追加 BUG-036）

---

### Task A1: 顶层流式 isolate 辅助函数

**Files:**
- Modify: `hibiki/lib/src/sync/sync_asset_package_service.dart`（文件顶部 import + 文件末尾追加 3 个顶层函数）

- [ ] **Step 1: 改 import**

把 `import 'package:archive/archive.dart';`（:4）替换为：

```dart
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
```

（`dart:convert` `dart:io` `drift` `hibiki_core` `path` 保持不变。`archive_io.dart` 提供 `ZipFileEncoder`/`InputFileStream`/`OutputFileStream` 并 re-export `ArchiveFile`/`ZipDecoder`，与 `archive.dart` 同名符号兼容。）

- [ ] **Step 2: 在文件末尾（`_nullablePathIn` 之后）追加三个顶层 isolate 辅助函数**

```dart
// ── 流式打包辅助（跑在后台 isolate，纯文件→文件，不依赖 DB / Flutter）─────────
//
// OOM 根因修复：旧实现把整个资源文件 readAsBytes、整个 zip 在内存里 encode/decode。
// 这里改用 archive_io 流式（ZipFileEncoder.addFile 经 InputFileStream 逐块读，
// ArchiveFile.writeContent 经 OutputFileStream 逐块写），并整体放进 Isolate.run，
// 让 deflate/inflate 的 CPU 与磁盘 IO 都离开 UI isolate。

/// 流式打 zip：把 [archivePathToSource]（zip 内路径 → 磁盘绝对路径）的每个文件
/// 流式写入 [outputPath]，并把 [manifestJson] 作为 `manifest.json` 写入。
Future<void> _zipPackageInIsolate({
  required String outputPath,
  required String manifestJson,
  required Map<String, String> archivePathToSource,
}) async {
  await Isolate.run(() async {
    final ZipFileEncoder encoder = ZipFileEncoder();
    encoder.create(outputPath);
    final List<int> manifestBytes = utf8.encode(manifestJson);
    encoder.addArchiveFile(
      ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
    );
    for (final MapEntry<String, String> entry in archivePathToSource.entries) {
      final File file = File(entry.value);
      if (!file.existsSync()) continue;
      // addFile 内部用 InputFileStream 流式读，不整文件入内存。
      await encoder.addFile(file, entry.key);
    }
    encoder.closeSync();
  });
}

/// 只读取包内 `manifest.json`（小，进内存）。decodeBuffer 只读中央目录 + 惰性流，
/// 不解压全部条目，因此很轻。
Future<String> _readManifestInIsolate(String packagePath) async {
  return Isolate.run(() {
    final InputFileStream input = InputFileStream(packagePath);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final ArchiveFile? manifestFile = archive.findFile('manifest.json');
      if (manifestFile == null) {
        throw const FormatException('Package manifest is missing');
      }
      return utf8.decode(manifestFile.content as List<int>);
    } finally {
      input.closeSync();
    }
  });
}

/// 流式把 [prefix]/ 下的资源解压到 [targetDirPath]。保留 zip-slip 路径安全校验
/// （与旧 _extractArchivePrefix 等价），每个文件经 OutputFileStream 逐块落盘。
Future<void> _extractResourcesInIsolate({
  required String packagePath,
  required String targetDirPath,
  required String prefix,
}) async {
  await Isolate.run(() {
    final InputFileStream input = InputFileStream(packagePath);
    try {
      final Archive archive = ZipDecoder().decodeBuffer(input);
      final String canonicalRoot = p.canonicalize(targetDirPath);
      for (final ArchiveFile file in archive.files) {
        if (!file.isFile) continue;
        final String rawName = file.name.replaceAll(r'\', '/');
        if (!rawName.startsWith('$prefix/')) continue;
        final String relativePath = rawName.substring(prefix.length + 1);
        final String normalizedRelative = p.posix.normalize(relativePath);
        if (relativePath.isEmpty ||
            p.posix.isAbsolute(relativePath) ||
            normalizedRelative == '..' ||
            normalizedRelative.startsWith('../')) {
          throw FormatException('Invalid package path: ${file.name}');
        }
        final String targetPath =
            p.normalize(p.join(targetDirPath, normalizedRelative));
        final String canonicalTarget = p.canonicalize(targetPath);
        if (canonicalTarget != canonicalRoot &&
            !p.isWithin(canonicalRoot, canonicalTarget)) {
          throw FormatException('Invalid package path: ${file.name}');
        }
        File(targetPath).parent.createSync(recursive: true);
        final OutputFileStream out = OutputFileStream(targetPath);
        try {
          file.writeContent(out);
        } finally {
          out.closeSync();
        }
      }
    } finally {
      input.closeSync();
    }
  });
}
```

- [ ] **Step 3: 编译确认（此步仅加函数，旧方法暂未调用它们，会有 unused warning，下一任务消化）**

Run: `cd hibiki && dart analyze lib/src/sync/sync_asset_package_service.dart`
Expected: 无 error（可能有 unused_element 提示，Task A2/A3 后消失）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/sync/sync_asset_package_service.dart
git commit -m "refactor(sync): add streaming isolate zip helpers (BUG-036 prep)"
```

---

### Task A2: 导出方法改用流式 isolate（DB 读留主 isolate）

**Files:**
- Modify: `hibiki/lib/src/sync/sync_asset_package_service.dart:14-38`（`exportDictionaryPackage`）、`:79-112`（`exportAudioDatabasePackage`）

- [ ] **Step 1: 重写 `exportDictionaryPackage`**

把 `:14-38` 整个方法体替换为：

```dart
  Future<File> exportDictionaryPackage({
    required String dictionaryName,
    required Directory dictionaryResourceRoot,
    required File outputFile,
  }) async {
    final DictionaryMetaRow meta = (await _db.getAllDictionaryMetadata())
        .singleWhere((DictionaryMetaRow row) => row.name == dictionaryName);
    final Directory sourceDir = Directory(
      p.join(dictionaryResourceRoot.path, dictionaryName),
    );

    // 主 isolate：收集文件清单（zip 内路径 → 磁盘路径），不读内容。
    final Map<String, String> archivePathToSource = <String, String>{};
    if (await sourceDir.exists()) {
      await for (final FileSystemEntity entity
          in sourceDir.list(recursive: true)) {
        if (entity is! File) continue;
        final String relativePath =
            p.relative(entity.path, from: sourceDir.path).replaceAll(r'\', '/');
        archivePathToSource['resources/$relativePath'] = entity.path;
      }
    }

    final String manifestJson = jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'kind': 'dictionary',
      'dictionary': _dictionaryManifest(meta),
    });

    outputFile.parent.createSync(recursive: true);
    await _zipPackageInIsolate(
      outputPath: outputFile.path,
      manifestJson: manifestJson,
      archivePathToSource: archivePathToSource,
    );
    return outputFile;
  }
```

- [ ] **Step 2: 重写 `exportAudioDatabasePackage`**

把 `:79-112` 整个方法体替换为：

```dart
  Future<File> exportAudioDatabasePackage({
    required String bookUid,
    required String srtBookUid,
    required File outputFile,
  }) async {
    final AudiobookRow audiobook = (await _db.getAudiobookByBookUid(bookUid))!;
    final SrtBookRow srtBook = (await _db.getSrtBookByUid(srtBookUid))!;
    final List<AudioCueRow> cues = await _db.getCuesForBook(bookUid);
    final List<File> files = _audioPackageFiles(audiobook, srtBook);

    // 主 isolate：分配唯一文件名，建立 manifest 的 resources 映射（源路径→名）
    // 与 isolate 的 zip 内路径映射（resources/名→源路径）。
    final Map<String, String> resourceNames = <String, String>{}; // src -> name
    final Map<String, String> archivePathToSource = <String, String>{};
    final Set<String> usedNames = <String>{};
    for (final File file in files) {
      if (!await file.exists()) continue;
      final String name = _uniqueFileName(file, usedNames);
      resourceNames[file.path] = name;
      archivePathToSource['resources/$name'] = file.path;
    }

    final String manifestJson = jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'kind': 'audioDatabase',
      'audiobook': _audiobookManifest(audiobook),
      'srtBook': _srtBookManifest(srtBook),
      'cues': cues.map(_audioCueManifest).toList(),
      'resources': resourceNames,
    });

    outputFile.parent.createSync(recursive: true);
    await _zipPackageInIsolate(
      outputPath: outputFile.path,
      manifestJson: manifestJson,
      archivePathToSource: archivePathToSource,
    );
    return outputFile;
  }
```

- [ ] **Step 3: 运行既有往返测试（导出侧已切流式，导入侧仍旧 → 仍应绿）**

Run: `cd hibiki && flutter test test/sync/sync_asset_package_service_test.dart`
Expected: PASS（包格式未变，旧 `ZipDecoder().decodeBytes` 能读流式产物）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/sync/sync_asset_package_service.dart
git commit -m "fix(sync): stream package export off UI isolate (BUG-036)"
```

---

### Task A3: 导入方法改用流式 isolate

**Files:**
- Modify: `hibiki/lib/src/sync/sync_asset_package_service.dart:40-77`（`importDictionaryPackage`）、`:120-211`（`importAudioDatabasePackage`）
- 删除取代件：`_writeZip` / `_jsonFile` / `_addDirectoryFiles` / `_extractArchivePrefix` / `_readManifest`

- [ ] **Step 1: 重写 `importDictionaryPackage`**

把 `:40-77` 整个方法体替换为：

```dart
  Future<void> importDictionaryPackage({
    required File packageFile,
    required Directory dictionaryResourceRoot,
  }) async {
    final String manifestJson = await _readManifestInIsolate(packageFile.path);
    final Map<String, Object?> manifest = _typedMap(jsonDecode(manifestJson));
    if (manifest['kind'] != 'dictionary') {
      throw FormatException('Unexpected package kind: ${manifest['kind']}');
    }
    final Map<String, Object?> dictionary = _mapValue(manifest, 'dictionary');
    final String name = _stringValue(dictionary, 'name');

    await _db.upsertDictionaryMeta(DictionaryMetadataCompanion.insert(
      name: name,
      formatKey: _stringValue(dictionary, 'formatKey'),
      order: _intValue(dictionary, 'order'),
      type: Value(_stringValue(dictionary, 'type')),
      metadataJson: Value(_stringValue(dictionary, 'metadataJson')),
      hiddenLanguagesJson: Value(_stringValue(dictionary, 'hiddenLanguagesJson')),
      collapsedLanguagesJson:
          Value(_stringValue(dictionary, 'collapsedLanguagesJson')),
    ));

    final Directory targetDir = Directory(
      p.join(dictionaryResourceRoot.path, name),
    );
    await _extractResourcesInIsolate(
      packagePath: packageFile.path,
      targetDirPath: targetDir.path,
      prefix: 'resources',
    );
  }
```

- [ ] **Step 2: 重写 `importAudioDatabasePackage`**

把 `:120-211` 整个方法体替换为（保留头部 dartdoc 注释 `:114-119` 不动）：

```dart
  Future<void> importAudioDatabasePackage({
    required File packageFile,
    required Directory audioDatabaseRoot,
    String? bookUidOverride,
    int? ttuBookIdOverride,
  }) async {
    final String manifestJson = await _readManifestInIsolate(packageFile.path);
    final Map<String, Object?> manifest = _typedMap(jsonDecode(manifestJson));
    if (manifest['kind'] != 'audioDatabase') {
      throw FormatException('Unexpected package kind: ${manifest['kind']}');
    }
    final Map<String, Object?> audiobook = _mapValue(manifest, 'audiobook');
    final Map<String, Object?> srtBook = _mapValue(manifest, 'srtBook');
    final Map<String, Object?> resources = _mapValue(manifest, 'resources');
    final String bookUid =
        bookUidOverride ?? _stringValue(audiobook, 'bookUid');
    final int ttuBookId = ttuBookIdOverride ?? _intValue(srtBook, 'ttuBookId');
    final Directory targetDir =
        Directory(p.join(audioDatabaseRoot.path, _safeDirName(bookUid)));

    await _extractResourcesInIsolate(
      packagePath: packageFile.path,
      targetDirPath: targetDir.path,
      prefix: 'resources',
    );

    final String alignmentPath = p.join(
      targetDir.path,
      _resourceName(resources, _stringValue(audiobook, 'alignmentPath')),
    );
    final List<String> audioPaths = _stringList(audiobook, 'audioPaths')
        .map((String path) =>
            p.join(targetDir.path, _resourceName(resources, path)))
        .toList();

    await _db.upsertAudiobook(AudiobooksCompanion.insert(
      bookUid: bookUid,
      audioRoot: Value(targetDir.path),
      audioPathsJson: Value(jsonEncode(audioPaths)),
      alignmentFormat: _stringValue(audiobook, 'alignmentFormat'),
      alignmentPath: alignmentPath,
      healthKindRaw: Value(_nullableString(audiobook, 'healthKindRaw')),
      matchRatePct: Value(_nullableInt(audiobook, 'matchRatePct')),
      healthMeasuredAt: Value(_nullableDate(audiobook, 'healthMeasuredAt')),
      healthReason: Value(_nullableString(audiobook, 'healthReason')),
      followAudio: Value(_nullableBool(audiobook, 'followAudio')),
    ));

    await _db.upsertSrtBook(SrtBooksCompanion.insert(
      uid: _stringValue(srtBook, 'uid'),
      title: _stringValue(srtBook, 'title'),
      author: Value(_nullableString(srtBook, 'author')),
      audioRoot: Value(targetDir.path),
      audioPathsJson: Value(jsonEncode(audioPaths)),
      srtPath: p.join(
        targetDir.path,
        _resourceName(resources, _stringValue(srtBook, 'srtPath')),
      ),
      coverPath: Value(
          _nullablePathIn(targetDir, resources, srtBook, 'coverPath')),
      importedAt: _intValue(srtBook, 'importedAt'),
      ttuBookId: Value(ttuBookId),
    ));

    await _db.replaceCuesForBook(
      bookUid,
      _listValue(manifest, 'cues').map((Object? raw) {
        final Map<String, Object?> cue = _typedMap(raw);
        return AudioCuesCompanion.insert(
          bookUid: bookUid,
          chapterHref: _stringValue(cue, 'chapterHref'),
          sentenceIndex: _intValue(cue, 'sentenceIndex'),
          textFragmentId: _stringValue(cue, 'textFragmentId'),
          cueText: _stringValue(cue, 'cueText'),
          startMs: _intValue(cue, 'startMs'),
          endMs: _intValue(cue, 'endMs'),
          audioFileIndex: _intValue(cue, 'audioFileIndex'),
        );
      }).toList(),
    );
  }
```

- [ ] **Step 3: 删除被取代的私有件**

删除这五个函数定义：`_writeZip`（原 :270-274）、`_jsonFile`（原 :276-279）、`_addDirectoryFiles`（原 :281-298）、`_extractArchivePrefix`（原 :300-329）、`_readManifest`（原 :331-346）。

- [ ] **Step 4: analyze + 既有往返测试（双向都流式了）**

Run: `cd hibiki && dart analyze lib/src/sync/sync_asset_package_service.dart && flutter test test/sync/sync_asset_package_service_test.dart`
Expected: 0 error；往返测试 PASS。

- [ ] **Step 5: Commit**

```bash
git add hibiki/lib/src/sync/sync_asset_package_service.dart
git commit -m "fix(sync): stream package import off UI isolate, drop in-memory zip (BUG-036)"
```

---

### Task A4: 源码守卫测试（防回归到内存模式）

**Files:**
- Create: `hibiki/test/sync/sync_asset_package_no_inmemory_guard_test.dart`

- [ ] **Step 1: 写守卫测试**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-036 守卫：sync_asset_package_service.dart 不得回归到「整文件/整 zip 进内存」。
/// OOM 根因正是 readAsBytes 整文件 + ZipEncoder().encode / ZipDecoder().decodeBytes
/// 整 zip 在内存。打包必须走 archive_io 流式 + Isolate.run。
void main() {
  test('package service stays streaming (no whole-file/zip in memory)', () {
    final String src = File(
      'lib/src/sync/sync_asset_package_service.dart',
    ).readAsStringSync();

    expect(src.contains('readAsBytes'), isFalse,
        reason: '资源文件不得 readAsBytes 整文件入内存，用 ZipFileEncoder.addFile 流式');
    expect(src.contains('ZipEncoder()'), isFalse,
        reason: '不得用内存 ZipEncoder().encode，用 ZipFileEncoder 流式落盘');
    expect(src.contains('decodeBytes'), isFalse,
        reason: '不得 ZipDecoder().decodeBytes 整包入内存，用 decodeBuffer(InputFileStream)');
    expect(src.contains('Isolate.run'), isTrue,
        reason: 'zip 编解码必须在后台 isolate，勿阻塞 UI isolate');
    expect(src.contains('ZipFileEncoder'), isTrue);
    expect(src.contains('InputFileStream'), isTrue);
  });
}
```

- [ ] **Step 2: 运行（在 hibiki/ 下，cwd 决定相对路径可读）**

Run: `cd hibiki && flutter test test/sync/sync_asset_package_no_inmemory_guard_test.dart`
Expected: PASS。

- [ ] **Step 3: 全量 sync 测试回归**

Run: `cd hibiki && flutter test test/sync/`
Expected: 全 PASS（含 orchestrator / compare / 既有往返）。

- [ ] **Step 4: Commit**

```bash
git add hibiki/test/sync/sync_asset_package_no_inmemory_guard_test.dart
git commit -m "test(sync): guard package service stays streaming (BUG-036)"
```

---

### Task A5: 登记 BUG-036

**Files:**
- Modify: `docs/BUGS.md`（按文件头流程追加一条，两个勾选框）

- [ ] **Step 1:** 按 `docs/BUGS.md` 现有格式追加 BUG-036：标题「手机端谷歌云盘『立刻同步』开有声书文件/词典同步时 OOM 闪退 + UI 卡死」；根因 `sync_asset_package_service.dart:99/272/45/127/295`（整文件+整 zip 进内存，跑 UI isolate）；① 根因修复勾上记 Task A2/A3 提交哈希；② 自动测试勾上记 `test/sync/sync_asset_package_no_inmemory_guard_test.dart` + 既有 `sync_asset_package_service_test.dart`。

- [ ] **Step 2:** `git diff --cached --check` 后 commit：

```bash
git add docs/BUGS.md
git commit -m "docs(bugs): log BUG-036 sync package OOM + UI freeze"
```

---

# Part B — 对比对话框可下载远端独有书（修 没下载书籍，登记为 BUG-037）

## File Structure

- Modify: `hibiki/lib/src/sync/sync_orchestrator.dart`
  - 抽出顶层可复用函数 `importRemoteBookFolder({db, backend, folderId, tempDir})`。
  - `SyncOrchestrator.importRemoteBooks`（:173-212）改为循环调用它（行为不变）。
- Modify: `hibiki/lib/src/sync/sync_compare_dialog.dart`
  - 构造器 + `showSyncCompareDialog` 加可选 `Directory? tempDir`。
  - `_load` remote-only 默认 useRemote；`_isActionable` 助手；`_applyChoices` 下载分支；`_actionableCount` 复用助手；`_buildEntry` 渲染下载控件 `_downloadRow`；select-all 菜单兼顾 remote-only。
- i18n: 经 `hibiki/tool/i18n_sync.dart` 新增 key `sync_compare_download`。
- Test: `hibiki/test/sync/sync_compare_download_test.dart`（新建）
- Docs: `docs/BUGS.md`（追加 BUG-037）

---

### Task B1: 抽出可复用 `importRemoteBookFolder`

**Files:**
- Modify: `hibiki/lib/src/sync/sync_orchestrator.dart`（import 区已含 `epub_importer` / `sync_backend` / `hibiki_core` / `path`；末尾追加顶层函数）、`:173-212`（`importRemoteBooks` 改为复用）

- [ ] **Step 1: 在 `sync_orchestrator.dart` 末尾（`isReservedSyncFolderName` 附近的顶层作用域）追加**

```dart
/// 下载远端书文件夹 [folderId] 里的 `.epub` 内容资产并导入为本地书。
/// 返回 true=导入成功；false=该文件夹没有 `.epub`（发送方关了内容同步，跳过）。
/// 传输/导入失败时抛出，交调用方决定如何提示。临时文件用后即删。
Future<bool> importRemoteBookFolder({
  required HibikiDatabase db,
  required SyncBackend backend,
  required String folderId,
  required Directory tempDir,
}) async {
  final List<AssetEntry> children = await backend.listChildren(folderId);
  AssetEntry? epub;
  for (final AssetEntry e in children) {
    if (!e.isFolder && e.name.toLowerCase().endsWith('.epub')) {
      epub = e;
      break;
    }
  }
  if (epub == null) return false;

  tempDir.createSync(recursive: true);
  final File tmp = File(p.join(
    tempDir.path,
    'hibiki_remote_${DateTime.now().microsecondsSinceEpoch}.epub',
  ));
  try {
    await backend.getAsset(epub.id, tmp);
    await EpubImporter.importFromPath(
      db: db,
      filePath: tmp.path,
      fileName: epub.name,
    );
    return true;
  } finally {
    try {
      if (tmp.existsSync()) tmp.deleteSync();
    } catch (_) {
      // best-effort temp cleanup
    }
  }
}
```

- [ ] **Step 2: 改 `importRemoteBooks`（:180-211 的 for 循环体）复用它**

把 `:185-210`（`File? tmp; try { ... } finally { _safeDelete(tmp); }` 整块）替换为：

```dart
      try {
        if (await importRemoteBookFolder(
          db: _db,
          backend: _backend,
          folderId: folder.id,
          tempDir: _tempDir,
        )) {
          report.booksImported++;
        }
      } catch (e) {
        report.errors.add('import book "${folder.name}": $e');
      }
```

（循环顶部 `:181-184` 的 reserved-folder / localKeys 去重保持不变。`_tmpFile('.epub')` 在此路径不再用，但其它路径仍用，保留该方法。）

- [ ] **Step 3: analyze + 既有 orchestrator 测试（行为应不变）**

Run: `cd hibiki && dart analyze lib/src/sync/sync_orchestrator.dart && flutter test test/sync/sync_orchestrator_test.dart`
Expected: 0 error；PASS。

- [ ] **Step 4: Commit**

```bash
git add hibiki/lib/src/sync/sync_orchestrator.dart
git commit -m "refactor(sync): extract reusable importRemoteBookFolder (BUG-037 prep)"
```

---

### Task B2: 新增 i18n key `sync_compare_download`

**Files:**
- Modify: `hibiki/lib/i18n/*.i18n.json`（经工具）、`hibiki/lib/i18n/strings.g.dart`（生成）

- [ ] **Step 1: 用 i18n_sync 工具加 key（禁止手改 17 个 json）**

Run: `cd hibiki && dart run tool/i18n_sync.dart --add sync_compare_download "Download" "下载"`
Expected: 17 个语言文件补齐该 key。

- [ ] **Step 2: 重新生成并格式化**

Run: `cd hibiki && dart run slang && dart format lib/i18n/strings.g.dart`
Expected: `strings.g.dart` 含 `sync_compare_download` getter。

- [ ] **Step 3: Commit**

```bash
git add hibiki/lib/i18n/ hibiki/lib/i18n/strings.g.dart
git commit -m "i18n(sync): add sync_compare_download key"
```

---

### Task B3: 对比对话框接入 remote-only 下载

**Files:**
- Modify: `hibiki/lib/src/sync/sync_compare_dialog.dart`（import 加 `dart:io`；`showSyncCompareDialog` :355；构造器 :394-409；`_load` :441-451；`_applyChoices` :480-483 + 循环 :513；`_actionableCount` :652-657；`_buildEntry` :941-944；select-all :749-753）

- [ ] **Step 1: import + 构造器 + 入口加 `tempDir`**

文件顶部加 `import 'dart:io';`（若未含）和 `import 'package:hibiki/src/sync/sync_orchestrator.dart';`（已含，确认）。

`showSyncCompareDialog`（:355-359 签名）加参数并下传：

```dart
Future<void> showSyncCompareDialog(
  BuildContext context,
  HibikiDatabase db, {
  bool conflictsOnly = false,
  Directory? tempDir,
}) async {
```

`:377-381` 的 `SyncCompareDialog(...)` 加 `tempDir: tempDir,`。

构造器（:394-409）加字段：

```dart
  const SyncCompareDialog({
    required this.db,
    required this.backend,
    this.conflictsOnly = false,
    this.tempDir,
    super.key,
  });
  final HibikiDatabase db;
  final SyncBackend backend;
  final bool conflictsOnly;
  final Directory? tempDir;
```

State 内加临时目录解析助手（放在 `_load` 之前）：

```dart
  Directory _resolveTempDir() => widget.tempDir ?? Directory.systemTemp;
```

- [ ] **Step 2: `_load` —— remote-only 默认 useRemote（下载）**

把 `:441-451` 的 for 循环替换为：

```dart
      for (final e in entries) {
        if (e.bookId == null) {
          // remote-only 书：唯一可做的对账是「下载到本机」。有远端文件夹则默认
          // 勾选下载，匹配用户「点 Apply 应把云端书拉下来」的直觉。
          choices[e.title] =
              e.remoteFolderId != null ? SyncChoice.useRemote : SyncChoice.skip;
        } else if (e.isSynced) {
          choices[e.title] = SyncChoice.skip;
        } else if (e.autoDirection == SyncDirection.importFromTtu) {
          choices[e.title] = SyncChoice.useRemote;
        } else if (e.autoDirection == SyncDirection.exportToTtu) {
          choices[e.title] = SyncChoice.useLocal;
        } else {
          choices[e.title] = SyncChoice.skip;
        }
      }
```

- [ ] **Step 3: 加 `_isActionable` 助手并复用**

在 `_applyChoices` 之前加：

```dart
  /// 一条 entry 是否参与 Apply：选了非 skip，且要么本地已有（bookId）、要么远端
  /// 独有可下载（remoteFolderId）。
  bool _isActionable(SyncCompareEntry e) {
    final c = _choices[e.title];
    if (c == null || c == SyncChoice.skip) return false;
    return e.bookId != null || e.remoteFolderId != null;
  }
```

把 `_applyChoices` 的 `actionable`（:480-483）替换为：

```dart
    final actionable = entries.where(_isActionable).toList();
```

把 `_actionableCount`（:652-657）替换为：

```dart
  int get _actionableCount {
    if (_entries == null) return 0;
    return _entriesInPlay.where(_isActionable).length;
  }
```

- [ ] **Step 4: `_applyChoices` 循环加 remote-only 下载分支**

在 `for (final entry in actionable) {` 之后、`final book = await widget.db.getEpubBook(entry.bookId!);`（:516）之前插入：

```dart
        if (entry.bookId == null) {
          // remote-only：下载并导入本地（显式用户动作，不受 syncContent 门控）。
          if (mounted) {
            setState(() {
              _progressLabel = '(${done + 1}/$total) ${entry.title}';
              _progress = done / total;
            });
          }
          try {
            final bool imported = await importRemoteBookFolder(
              db: widget.db,
              backend: widget.backend,
              folderId: entry.remoteFolderId!,
              tempDir: _resolveTempDir(),
            );
            if (imported) applied++;
          } on DuplicateImportCancelledException {
            // 良性：本机已有同名书，跳过。
          } catch (e) {
            errors.add(entry.title);
            developer.log(
              'Failed to download "${entry.title}"',
              error: e,
              name: 'SyncCompare',
            );
          }
          done++;
          if (mounted) setState(() => _progress = done / total);
          continue;
        }
```

确认顶部已 `import 'package:hibiki/src/epub/epub_importer.dart';`（`DuplicateImportCancelledException` 来源）——若未含则加。

- [ ] **Step 5: `_buildEntry` 渲染下载控件**

把 `:941-944` 替换为：

```dart
          if (entry.bookId != null && entry.needsManualChoice) ...[
            const SizedBox(height: 6),
            _choiceRow(entry.title, choice, theme),
          ] else if (entry.bookId == null && entry.remoteFolderId != null) ...[
            const SizedBox(height: 6),
            _downloadRow(entry.title, choice, theme),
          ],
```

在 `_buildEntry` 之后加 `_downloadRow`（复用现有 `HibikiCard`/主题风格；用 Checkbox 切 skip↔useRemote）：

```dart
  Widget _downloadRow(String title, SyncChoice choice, ThemeData theme) {
    final bool download = choice == SyncChoice.useRemote;
    return Row(
      children: <Widget>[
        Checkbox(
          value: download,
          onChanged: _applying
              ? null
              : (bool? v) => setState(() {
                    _choices[title] =
                        (v ?? false) ? SyncChoice.useRemote : SyncChoice.skip;
                  }),
        ),
        Icon(Icons.cloud_download_outlined,
            size: 16, color: theme.colorScheme.primary),
        const SizedBox(width: 4),
        Text(t.sync_compare_download,
            style: theme.textTheme.labelMedium
                ?.copyWith(color: theme.colorScheme.primary)),
      ],
    );
  }
```

- [ ] **Step 6: select-all 菜单兼顾 remote-only**

把 `:749-753` 的 `for` 替换为：

```dart
                      for (final e in _entries!) {
                        if (e.bookId != null && e.needsManualChoice) {
                          _choices[e.title] = choice;
                        } else if (e.bookId == null &&
                            e.remoteFolderId != null) {
                          // remote-only 只在 useRemote/skip 间切；忽略 useLocal。
                          _choices[e.title] = choice == SyncChoice.useLocal
                              ? SyncChoice.skip
                              : choice;
                        }
                      }
```

- [ ] **Step 7: analyze**

Run: `cd hibiki && dart analyze lib/src/sync/sync_compare_dialog.dart`
Expected: 0 error。

- [ ] **Step 8: Commit**

```bash
git add hibiki/lib/src/sync/sync_compare_dialog.dart
git commit -m "fix(sync): compare dialog downloads remote-only books on Apply (BUG-037)"
```

---

### Task B4: 对比对话框下载的 widget 测试

**Files:**
- Create: `hibiki/test/sync/sync_compare_download_test.dart`
- 参考：`test/sync/sync_compare_delete_test.dart`（fake backend + pumpWidget SyncCompareDialog 范例）、`test/sync/fake_asset_store.dart`、`test/epub/`（最小 epub 夹具/构造器；执行时确认是否已有 `buildMinimalEpub` 助手，没有则在测试内构造一个最小合法 epub zip）

- [ ] **Step 1: 写测试**

要点（按 `sync_compare_delete_test.dart` 的 fake backend 写法）：
1. 造一个 fake `SyncBackend`：`listBooks` 返回一个远端 DriveFile（本机没有的标题）；`listChildren(folder)` 返回一个 `.epub` AssetEntry；`getAsset(id, dest)` 把一个最小合法 epub 写到 `dest`；`isAuthenticated=true`；其余 progress/stats 文件返回空。
2. `pumpWidget(SyncCompareDialog(db: memDb, backend: fake, tempDir: tempDir))`，`pumpAndSettle`。
3. 断言：remote-only 条目渲染出 `t.sync_compare_download` + Checkbox 默认勾选（useRemote）；`_actionableCount`/Apply 按钮可点（`Apply (1)`）。
4. 点 Apply（widget 测试可用 `tester.tap`，焦点驱动只对 integration_test 强制）；`pumpAndSettle`。
5. 断言 `await memDb.getAllEpubBooks()` 多出该书（说明 `importRemoteBookFolder`→`EpubImporter` 真正插了本地书），即「点 Apply 真把远端书下载下来了」。

```dart
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/sync_backend.dart';
import 'package:hibiki/src/sync/sync_compare_dialog.dart';
import 'package:hibiki_core/hibiki_core.dart';
// + 复用 test/epub 的最小 epub 构造助手（执行时确认确切 import 路径）

void main() {
  testWidgets('remote-only book is downloadable and Apply imports it',
      (WidgetTester tester) async {
    // 1) 准备 memDb + tempDir + fake backend（远端有一本书、含 .epub，本机没有）
    // 2) pumpWidget(SyncCompareDialog(db, backend, tempDir))
    // 3) expect(find.text(<download label>), findsOneWidget) + Checkbox 勾选
    // 4) tap Apply → pumpAndSettle
    // 5) final books = await memDb.getAllEpubBooks(); expect(books, isNotEmpty);
  });
}
```

（执行子代理负责把上面骨架填成可运行测试：fake backend 的完整接口实现照 `sync_compare_delete_test.dart`；最小 epub 用 `test/epub` 现成夹具或内联构造。）

- [ ] **Step 2: 运行**

Run: `cd hibiki && flutter test test/sync/sync_compare_download_test.dart`
Expected: PASS（远端书被导入，`getAllEpubBooks` 非空）。

- [ ] **Step 3: 全量 sync + 编译验证**

Run: `cd hibiki && dart format . && flutter test test/sync/`
Expected: 全 PASS。

- [ ] **Step 4: Commit**

```bash
git add hibiki/test/sync/sync_compare_download_test.dart
git commit -m "test(sync): compare dialog downloads remote-only book (BUG-037)"
```

---

### Task B5: 登记 BUG-037

**Files:**
- Modify: `docs/BUGS.md`

- [ ] **Step 1:** 追加 BUG-037：标题「『Local vs Remote』对比对话框点 Apply 不下载远端独有书」；根因 `sync_compare_dialog.dart:442-443/480-483/652-657/941`（remote-only `bookId==null` 被强制 skip 且排除 actionable，唯一下载路径 `importRemoteBooks` 不被对话框调用）；① 修复勾上记 Task B1/B3 哈希；② 自动测试勾上记 `test/sync/sync_compare_download_test.dart`。

- [ ] **Step 2:** commit：

```bash
git add docs/BUGS.md
git commit -m "docs(bugs): log BUG-037 compare dialog cannot download remote-only books"
```

---

## 收尾验证（两 Part 都完成后）

- [ ] `cd hibiki && dart format . && flutter analyze`（0 error）
- [ ] `cd hibiki && flutter test`（全量绿）
- [ ] 真机复测（用户侧）：手机谷歌云盘、内容/有声书文件/词典同步全开 →「立刻同步」不再卡死/闪退；远端独有书经「立刻同步」或对比对话框 Apply 下载到本机。声明「修好了」前需按 docs/agent/integration-testing.md 留证据。
- [ ] 调 `superpowers:requesting-code-review`，子代理 `model: "opus"` 审查（CLAUDE.md 强制）。

## 风险 / 注意

1. **`Isolate.run` 闭包捕获**：只捕获 String/Map<String,String>（可跨 isolate），不捕获 `_db`/Flutter 对象——DB 读写全在主 isolate。已遵守。
2. **包格式不变**：manifest schema、`resources` 映射、zip 内 `resources/` 前缀完全保持；既有往返测试是回归网。
3. **remote-only 默认勾选下载**：`conflictsOnly`（冲突解决弹窗）走 `_entriesInPlay` 过滤 `hasConflict`，remote-only 非冲突 → 不会在冲突弹窗里被自动下载。仅设置页「Local vs Remote」入口默认勾选。若 review 认为默认不该勾，改 Step B2 为 `SyncChoice.skip` 即可（控件仍在）。
4. **下载不受 syncContent 门控**：对话框里显式勾「下载」是明确用户意图，等同 manual direction 绕过 auto 门控的既有模式。
5. **i18n 纪律**：B2 必须用 `tool/i18n_sync.dart`，禁手改 17 json；改完 `dart run slang`。
6. **并发 develop**：本仓多 agent 共享 develop 工作树，提交只 stage 本轮文件，禁 `git add -A`。
