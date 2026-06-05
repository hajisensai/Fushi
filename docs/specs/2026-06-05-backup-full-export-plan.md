# 本地备份「全量导出」实现计划（含修卡顿 + 导入路径重基）

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development 或 superpowers:executing-plans 逐 task 执行。步骤用 `- [ ]` 复选框跟踪。每个代码改动 task 走 TDD（先红后绿）+ 频繁提交。子代理一律 `model: opus`。

**Goal:** 让「导出本地备份」把**所有用户数据**（数据库 + 词典资源 + EPUB 书籍内容 + 有声书音频 + 封面）打进一个 zip，并消除导出时 UI 卡死（未响应）；让「导入备份」能在另一台设备/重装后**真正恢复**这些书（重写 DB 里失效的绝对路径）。

**Architecture:**
- **导出**：`BackupService.exportBackup` 改为把 `hoshi_books/`（书籍）和 `audiobooks/`（有声书音频）两棵目录树整体纳入 zip；编解码搬进 `Isolate.run` + 流式 `ZipFileEncoder` 直接写盘（照搬同仓 `sync_asset_package_service.dart` 已验证范式），不再在 UI isolate 上同步 `ZipEncoder().encode` 全内存压缩。
- **导入**：解压两棵树到本机 app 目录后，**按 bookKey 重写 DB 路径列**（`epubPath`/`extractDir`/`coverPath`/`audioRoot`/`audioPathsJson`）——把备份里旧设备的绝对路径前缀换成本机当前 app 目录前缀。这是跨设备/重装恢复的唯一正确办法（iOS 重装容器 UUID 必变，绝对路径一定失效）。
- **体积**：去掉 512MB 导入上限；手机端导出从「系统分享面板」改为 `saveFile` 落盘（GB 级文件分享会崩）。
- **安全不变**：即便全量，仍剥离同步凭据（HBK-AUDIT-012），备份是分享出去的，不能泄露 OAuth/FTP 密码与 NAS 地址。

**Tech Stack:** Dart / Flutter 3.44；`package:archive`（`ZipFileEncoder` 流式，来自 `archive/archive_io.dart`）；Drift（路径列更新）；`path_provider`；`file_picker`（saveFile）。

---

## 背景事实（实现前必读）

存储布局（`epub_storage.dart` / `audiobook_storage.dart` 确认）：

| 数据 | 根目录 | DB 列（绝对路径） |
|---|---|---|
| 数据库 | `getApplicationSupportDirectory()` | — (`hibiki.db`) |
| 书籍（epub 原件 + 解压正文/图/字体 + 封面 `cover<ext>`） | `getApplicationDocumentsDirectory()/hoshi_books/<bookKey>/` | `EpubBooks.epubPath` / `extractDir` / `coverPath` |
| 有声书音频 | `getApplicationDocumentsDirectory()/audiobooks/<hash>/`（`hash = sha/hashCode of bookUid`） | `Audiobooks.audioRoot` / `audioPathsJson`（JSON 字符串数组） |
| 词典资源 | `appModel.dictionaryResourceDirectory`（已在备份里，但当前被 `isSyncDictionaryEnabled` 门控） | — |

当前 `exportBackup`（`backup_service.dart:82`）只打：`hibiki.db` + 可选 `dictionaryResources/` + `backup_meta.json`。**书籍/音频/封面一个都没有**——这是用户报的「备份里没有 epub」。卡顿点在 `backup_service.dart:150` 的同步 `ZipEncoder().encode(archive)`（全内存 deflate 跑在 UI isolate）。

已存在可复用：`updateEpubBookPath(bookKey, epubPath)`（`database.dart:998`）。流式 zip 范式：`sync_asset_package_service.dart:510`（`Isolate.run` + `ZipFileEncoder` + `STORE/GZIP`）。

---

## 文件结构（改动清单）

- **Modify** `hibiki/lib/src/sync/backup_service.dart`
  - `BackupService` 构造新增 `booksRootDirectory` / `audiobooksRootDirectory`（可空，向后兼容旧调用）。
  - `BackupMeta` 新增 `booksRoot` / `audiobooksRoot` / `dictionaryRoot` 字段（旧设备绝对根，供导入重基；旧备份缺这些 → 跳过重基，仅恢复 db）。
  - `exportBackup` 改为流式 + 纳入两棵树；提取静态纯函数 `buildBackupZip`（放进 `Isolate.run`）。
  - `importBackupFiles` 新增 `booksRootDirectory` / `audiobooksRootDirectory` 参数；解压两棵树 + 调用新 `_rebaseContentPaths`。
  - 新增静态 `_rebaseContentPaths(db, meta, newBooksRoot, newAudiobooksRoot)`：重写路径列。
  - 新增静态纯函数 `rebasePath(oldPath, oldRoot, newRoot)`（**可测**）。
  - `_maxImportBytes` 512MB 上限移除（或抬到一个不挡 GB 备份的值）。
- **Modify** `hibiki/lib/src/sync/sync_settings_schema.dart`
  - 导出 widget（`_BackupExportWidgetState._export`，:802）：传入 books/audiobooks 根；移动端从 `Share.shareXFiles` 改为 `FilePicker.platform.saveFile`（落盘）。
  - 导入 widget（`_BackupImportWidgetState._import`，:905）：给 `importBackupFiles` 传 books/audiobooks 根。
- **新增 helper（DB 层）** `packages/hibiki_core/lib/src/database/database.dart`
  - `updateEpubBookContentPaths(bookKey, {epubPath, extractDir, coverPath})`
  - `updateAudiobookPaths(bookKey, {audioRoot, audioPathsJson})`
  - `getAllAudiobooks()`（若无）
- **Test**
  - `hibiki/test/sync/backup_rebase_path_test.dart`（纯函数 `rebasePath` + `_rebaseContentPaths` 端到端 round-trip）
  - `hibiki/test/sync/backup_full_export_test.dart`（导出含两棵树 + 导入恢复文件 + 路径列被重写）
  - 既有 `backup_service_test.dart` / `backup_import_preserve_test.dart` 回归不破。

---

## Task 1：`rebasePath` 纯函数 + 测试（路径重基的地基）

**Files:**
- Modify: `hibiki/lib/src/sync/backup_service.dart`
- Test: `hibiki/test/sync/backup_rebase_path_test.dart`

- [ ] **Step 1: 写失败测试**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';

void main() {
  group('rebasePath', () {
    test('replaces the old root prefix with the new root (posix)', () {
      expect(
        rebasePath('/old/app/hoshi_books/MyBook/original.epub',
            '/old/app/hoshi_books', '/new/app/hoshi_books'),
        '/new/app/hoshi_books/MyBook/original.epub',
      );
    });

    test('replaces the old root prefix (windows backslash)', () {
      expect(
        rebasePath(r'C:\OldA\hoshi_books\Bk\cover.jpg',
            r'C:\OldA\hoshi_books', r'D:\NewB\hoshi_books'),
        r'D:\NewB\hoshi_books\Bk\cover.jpg',
      );
    });

    test('returns the path unchanged when it is not under the old root', () {
      expect(
        rebasePath('/somewhere/else/x.epub', '/old/app/hoshi_books',
            '/new/app/hoshi_books'),
        '/somewhere/else/x.epub',
      );
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `D:/flutter_sdk/flutter_extracted/flutter/bin/flutter test test/sync/backup_rebase_path_test.dart`
Expected: FAIL（`rebasePath` 未定义）。

- [ ] **Step 3: 实现 `rebasePath`**

放在 `backup_service.dart` 顶层（class 外，便于测试）。用规范化比较，避免 `/` vs `\` 与末尾分隔符差异：

```dart
/// Rewrites an absolute [oldPath] that lives under [oldRoot] so it lives under
/// [newRoot] instead, preserving the sub-path. Returns [oldPath] verbatim when
/// it is not under [oldRoot] (e.g. a path that was already local, or an
/// unrelated location). Comparison normalizes separators so a backup taken on
/// one OS restores on the same OS regardless of `/` vs `\`.
String rebasePath(String oldPath, String oldRoot, String newRoot) {
  String norm(String s) => s.replaceAll('\\', '/');
  final String np = norm(oldPath);
  String nr = norm(oldRoot);
  if (nr.endsWith('/')) nr = nr.substring(0, nr.length - 1);
  if (np == nr) return newRoot;
  if (!np.startsWith('$nr/')) return oldPath;
  final String suffix = oldPath.substring(oldRoot.length);
  // Strip a leading separator from suffix so join is clean on both OSes.
  final String cleanSuffix =
      suffix.startsWith('/') || suffix.startsWith('\\')
          ? suffix.substring(1)
          : suffix;
  return p.join(newRoot, cleanSuffix);
}
```
（`p` 是已 import 的 `package:path`。）

- [ ] **Step 4: 跑测试确认通过**

Run: 同 Step 2。Expected: PASS（3 例）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/lib/src/sync/backup_service.dart hibiki/test/sync/backup_rebase_path_test.dart
git commit -m "feat(backup): add rebasePath helper for cross-device path restore"
```

---

## Task 2：`BackupMeta` 携带旧设备根目录

**Files:** Modify `hibiki/lib/src/sync/backup_service.dart`；Test: 扩 `backup_rebase_path_test.dart`

- [ ] **Step 1: 写失败测试**（`BackupMeta` round-trip 带新字段、旧 JSON 缺字段时为 null）

```dart
test('BackupMeta round-trips content roots, tolerates legacy json', () {
  final m = BackupMeta(
    appVersion: '1', schemaVersion: 16, createdAt: DateTime(2026, 6, 5),
    bookCount: 2, statsCount: 0,
    booksRoot: '/old/hoshi_books', audiobooksRoot: '/old/audiobooks',
  );
  final back = BackupMeta.fromJson(m.toJson());
  expect(back.booksRoot, '/old/hoshi_books');
  expect(back.audiobooksRoot, '/old/audiobooks');
  // legacy backup без новых полей
  final legacy = BackupMeta.fromJson({
    'appVersion': '1', 'schemaVersion': 16,
    'createdAt': DateTime(2026).toIso8601String(),
  });
  expect(legacy.booksRoot, isNull);
  expect(legacy.audiobooksRoot, isNull);
});
```

- [ ] **Step 2: 跑测试确认失败**（构造器无 `booksRoot` 命名参数）。

- [ ] **Step 3: 实现** — 给 `BackupMeta` 加 `final String? booksRoot; final String? audiobooksRoot;`，构造器加可选命名参数，`toJson` 增两键，`fromJson` 用 `as String?`（缺则 null）。

- [ ] **Step 4: 跑测试确认通过。**

- [ ] **Step 5: 提交** `feat(backup): record source content roots in BackupMeta`

---

## Task 3：DB 路径列更新 helper

**Files:** Modify `packages/hibiki_core/lib/src/database/database.dart`；Test: `packages/hibiki_core/test/...`（或在 hibiki 层端到端测，见 Task 6）

- [ ] **Step 1**：在 `database.dart` 加（紧邻 `updateEpubBookPath:998`）：

```dart
Future<void> updateEpubBookContentPaths(
  String bookKey, {
  String? epubPath,
  String? extractDir,
  String? coverPath,
}) =>
    (update(epubBooks)..where((t) => t.bookKey.equals(bookKey))).write(
      EpubBooksCompanion(
        epubPath: epubPath == null ? const Value.absent() : Value(epubPath),
        extractDir:
            extractDir == null ? const Value.absent() : Value(extractDir),
        coverPath:
            coverPath == null ? const Value.absent() : Value(coverPath),
      ),
    );

Future<void> updateAudiobookPaths(
  String bookKey, {
  String? audioRoot,
  String? audioPathsJson,
  String? alignmentPath,
}) =>
    (update(audiobooks)..where((t) => t.bookKey.equals(bookKey))).write(
      AudiobooksCompanion(
        audioRoot:
            audioRoot == null ? const Value.absent() : Value(audioRoot),
        audioPathsJson: audioPathsJson == null
            ? const Value.absent()
            : Value(audioPathsJson),
        alignmentPath: alignmentPath == null
            ? const Value.absent()
            : Value(alignmentPath),
      ),
    );
```
> **已核对（实现前的结论，无需再查）**：`Audiobooks` 主键列是 `bookKey`（`tables.dart:60`，`text().unique()`），where 用 `bookKey` 正确。表里有**三个**需重基的路径列，别漏 `alignmentPath`：`audioRoot`（nullable）、`audioPathsJson`（nullable，JSON 字符串数组）、`alignmentPath`（**必填**，字幕对齐文件，落在 `audiobooks/<hash>/`，见 `book_import_dialog.dart:827` `persistedSrt` / `audiobook_import_dialog.dart:710` `persistedAlignment`，都在 `AudiobookStorage.ensurePersistDir` 下）。漏 `alignmentPath` → 恢复后 cue 对齐丢失、有声书播放不同步。`alignmentFormat` 是格式串非路径，不动。

- [ ] **Step 2**：`getAllAudiobooks()` 若不存在则加 `Future<List<AudiobookRow>> getAllAudiobooks() => select(audiobooks).get();`

- [ ] **Step 3**：`flutter analyze packages/hibiki_core` 0 issue。

- [ ] **Step 4: 提交** `feat(db): add content-path updaters for backup restore`

---

## Task 4：流式打包（修卡顿）+ 纳入两棵树

**Files:** Modify `hibiki/lib/src/sync/backup_service.dart`

- [ ] **Step 1**：`import 'package:archive/archive_io.dart';`（提供 `ZipFileEncoder`）。

- [ ] **Step 2**：构造器加 `final Directory? _booksRootDirectory; final Directory? _audiobooksRootDirectory;`（命名可选参数，默认 null → 退化为旧行为，保旧测试不破）。

- [ ] **Step 3**：把 zip 写盘逻辑抽成静态纯函数并放进 `Isolate.run`，**取代** `backup_service.dart:135-152` 的 `Archive()` + `ZipEncoder().encode`：

```dart
// 在 exportBackup 内，准备好 cleanDbPath/meta/各根目录后：
final String outPath = outputPath;
final String dbPathForZip = cleanDbPath;
final String? dictRoot = includeDictionary ? dictionaryResourceRoot!.path : null;
final String? booksRoot = _booksRootDirectory?.path;
final String? audiobooksRoot = _audiobooksRootDirectory?.path;
final List<int> metaBytes = utf8.encode(
    const JsonEncoder.withIndent('  ').convert(meta.toJson()));

await Isolate.run(() async {
  final encoder = ZipFileEncoder();
  encoder.create(outPath);
  try {
    // 大文件一律 STORE（epub/音频本就压缩过，deflate 收益≈0 且更慢/更耗内存）。
    await encoder.addFile(File(dbPathForZip), _dbName, ZipFileEncoder.STORE);
    if (dictRoot != null) {
      await encoder.addDirectory(Directory(dictRoot),
          includeDirName: true /* dictionaryResources/ */ );
    }
    if (booksRoot != null && Directory(booksRoot).existsSync()) {
      await encoder.addDirectory(Directory(booksRoot), includeDirName: true);
    }
    if (audiobooksRoot != null && Directory(audiobooksRoot).existsSync()) {
      await encoder.addDirectory(Directory(audiobooksRoot),
          includeDirName: true);
    }
    encoder.addArchiveFile(ArchiveFile(_metaName, metaBytes.length, metaBytes));
  } finally {
    await encoder.close();
  }
});
```

> 注意 `addDirectory(includeDirName:true)` 会以目录名（`hoshi_books`/`audiobooks`/`dictionaryResources`）作为 zip 内前缀——导入端按这三个前缀解。核对 `ZipFileEncoder.addDirectory` 在本仓 archive 版本的 API 签名（`sync_asset_package_service.dart` 用的是同包，照其调用风格）。`dictionaryResources` 旧实现用的是自定义前缀 `_dictionaryResourcesPrefix`，**保持一致**：若目录名≠`dictionaryResources`，改用逐文件 `addFile(...,'dictionaryResources/<rel>')` 保前缀不变（避免破坏既有 `_buildDictionaryRestorePlan` 的前缀约定）。

- [ ] **Step 4**：`meta` 增 `booksRoot`/`audiobooksRoot`（旧根，来自构造参数）。词典恒含：把 `includeDictionary` 改为「目录存在即含」，去掉 `isSyncDictionaryEnabled` 门控（用户要全量）。但仍 `_stripDictionaryState` 的反向逻辑要相应处理：全量导出不再 strip 词典。

- [ ] **Step 5**：`flutter analyze` + 既有 `backup_service_test.dart` 跑通（旧调用 booksRoot=null → 退化路径仍只打 db+dict，旧断言不破）。

- [ ] **Step 6: 提交** `fix(backup): stream-encode export off the UI isolate, include book+audio trees`

---

## Task 5：导入端解压两棵树 + 路径重基

**Files:** Modify `hibiki/lib/src/sync/backup_service.dart`

- [ ] **Step 1**：`importBackupFiles` 新增可选参数 `Directory? booksRootDirectory, Directory? audiobooksRootDirectory`。

- [ ] **Step 2**：在 DB 覆盖完成、且（按 `importSettings`）设置层处理之后，新增解压两棵树：删除目标根（若存在）→ 按 zip 内 `hoshi_books/` / `audiobooks/` 前缀逐文件写出到 `booksRootDirectory` / `audiobooksRootDirectory`。复用既有 `_buildDictionaryRestorePlan` 同款的**路径穿越校验**（拒绝 `../` 与绝对路径，`p.isWithin` 闸）——这是安全闸，必须照搬，别省。

- [ ] **Step 3**：新增 `_rebaseContentPaths`：打开导入后的 DB，遍历所有书/有声书，用 `rebasePath` 把每个路径列从 `meta.booksRoot`/`meta.audiobooksRoot` 重基到本机根；`audioPathsJson` 要 decode→逐项 rebase→encode。`meta.booksRoot==null`（旧备份）→ 跳过重基（仅 db 恢复，与旧行为一致）。

```dart
static Future<void> _rebaseContentPaths({
  required String dbDirectory,
  required BackupMeta meta,
  required String newBooksRoot,
  required String newAudiobooksRoot,
}) async {
  final String? oldBooks = meta.booksRoot;
  final String? oldAudio = meta.audiobooksRoot;
  if (oldBooks == null && oldAudio == null) return; // legacy backup
  final db = HibikiDatabase(dbDirectory);
  try {
    if (oldBooks != null) {
      for (final b in await db.getAllEpubBooks()) {
        await db.updateEpubBookContentPaths(
          b.bookKey,
          epubPath: rebasePath(b.epubPath, oldBooks, newBooksRoot),
          extractDir: rebasePath(b.extractDir, oldBooks, newBooksRoot),
          coverPath: b.coverPath == null
              ? null
              : rebasePath(b.coverPath!, oldBooks, newBooksRoot),
        );
      }
    }
    if (oldAudio != null) {
      for (final a in await db.getAllAudiobooks()) {
        final String? rebasedJson = a.audioPathsJson == null
            ? null
            : jsonEncode(((jsonDecode(a.audioPathsJson!) as List)
                .whereType<String>()
                .map((s) => rebasePath(s, oldAudio, newAudiobooksRoot))
                .toList()));
        await db.updateAudiobookPaths(
          a.bookKey,
          audioRoot: a.audioRoot == null
              ? null
              : rebasePath(a.audioRoot!, oldAudio, newAudiobooksRoot),
          audioPathsJson: rebasedJson,
          // alignmentPath 必填且也在 audiobooks 根下，必须重基。
          alignmentPath: rebasePath(a.alignmentPath, oldAudio, newAudiobooksRoot),
        );
      }
    }
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
  } finally {
    await db.close();
  }
}
```
> 封面可能落在 `audiobooks/<hash>/cover.*`（有声书导入路径）而非 hoshi_books。`rebasePath` 对不在 `oldBooks` 下的 coverPath 会原样返回 → 再无人重基。**对策**：coverPath 先尝试 books 根、未命中再尝试 audiobooks 根（两次 rebase 取命中的那个）。在实现里对 coverPath 做 `_rebaseEither(path, [oldBooks→newBooks, oldAudio→newAudio])`。

- [ ] **Step 4**：去掉 `_maxImportBytes` 512MB 上限（`validateBackup` 里移除 size 短路；改为不做大小上限，或抬到如 `64 * 1024 * 1024 * 1024`）。

- [ ] **Step 5**：`flutter analyze`。

- [ ] **Step 6: 提交** `feat(backup): restore book+audio trees and rebase paths on import`

---

## Task 6：端到端 round-trip 测试（最强可落地层）

**Files:** Test `hibiki/test/sync/backup_full_export_test.dart`

- [ ] **Step 1: 写测试**：在临时目录搭一个含 1 本书（hoshi_books/Bk/original.epub + cover）+ 1 个有声书（audiobooks/h/a.mp3）的假 app 布局 + Drift DB（书行的 epubPath/extractDir/coverPath/audioRoot/audioPathsJson 指向「旧」绝对路径）。`exportBackup` 到 zip → 断言 zip 内含 `hoshi_books/Bk/original.epub`、`audiobooks/h/a.mp3`、`backup_meta.json` 带 booksRoot/audiobooksRoot。然后用**新的**（不同的）books/audiobooks 根 `importBackupFiles` → 断言：① 文件被解压到新根；② DB 里该书 `epubPath/extractDir/coverPath` 已重写为新根前缀、文件在磁盘存在；③ `audioPathsJson` 每项重基到新根。

- [ ] **Step 2: 跑测试确认失败**（功能未接通）。

- [ ] **Step 3**：补齐使其通过（多半是 Task 4/5 的边角）。

- [ ] **Step 4: 跑全量** `flutter test test/sync/` 确认无回归（既有 backup_service_test / backup_import_preserve_test 绿）。

- [ ] **Step 5: 提交** `test(backup): full export/import round-trip with path rebase`

---

## Task 7：UI 接线（传根 + 手机落盘导出）

**Files:** Modify `hibiki/lib/src/sync/sync_settings_schema.dart`

- [ ] **Step 1**：导出 widget（:809）构造 `BackupService` 时传 `booksRootDirectory: Directory(await EpubStorage.baseDirectory())` 与 `audiobooksRootDirectory: <appDoc>/audiobooks`（确认取 audiobooks 根的现成 API；无则用 `p.join((await getApplicationDocumentsDirectory()).path, 'audiobooks')`）。

- [ ] **Step 2**：导出后处理：**移动端也改 `FilePicker.platform.saveFile`**（落盘，避免 GB 级分享崩）——与桌面分支合并成单一 saveFile 路径；保留桌面现状。注意 Android saveFile 的 SAF 行为，必要时回退到 `Share` 仅当 saveFile 返回 null。

- [ ] **Step 3**：导入 widget（:949）给 `importBackupFiles` 传同样的 books/audiobooks 根。

- [ ] **Step 4**：i18n：导出/导入提示文案若需调整（如「备份较大，请稍候」），用 `tool/i18n_sync.dart` 加 key，不手改 17 文件。

- [ ] **Step 5**：`flutter analyze` + `dart format` + `flutter test`（相关目录）。

- [ ] **Step 6: 提交** `feat(backup): wire full-data export/import + save-to-disk on mobile`

---

## Task 8：审查 + 真机验证收口

- [ ] **Step 1**：spawn code-review 子代理（`model: opus`）审 Task 1–7 全 diff，重点：路径重基正确性（含封面落 audiobooks 的边角）、路径穿越安全闸、流式打包不再 UI 卡死、旧备份兼容（meta 缺根时只恢复 db）、`_maxImportBytes` 移除后的内存安全（导入仍是逐文件流式写、不是整 zip 入内存）。
- [ ] **Step 2**：按审查 Critical/Warning 修复并复测。
- [ ] **Step 3**：BUGS/规范登记：本功能源于用户报「备份里没有 epub + 导出未响应」。验真后在 `docs/BUGS.md` 记一条（导出卡顿=真 bug，记根因 `backup_service.dart:150` 同步 encode；备份缺书=设计缺口/已按用户要求全量化），勾 ①②。
- [ ] **Step 4（真机，待用户）**：Windows + 一台移动设备各跑：导出 → 确认 zip 含书与音频、导出时 UI 不冻 → 在**另一身份/重装**后导入 → 书能打开、有声书能播、封面在。证据留 `.codex-test/`。

---

## 自检（计划 vs 需求）

- ✅「导出含所有数据」→ Task 4 纳入 hoshi_books + audiobooks + 恒含词典。
- ✅「导出未响应」→ Task 4 `Isolate.run` + `ZipFileEncoder` 流式。
- ✅「导入能恢复」→ Task 5 解压 + 路径重基（Task 1 `rebasePath` 地基，Task 3 DB helper）。
- ✅「体积/手机」→ Task 5 去上限 + Task 7 手机落盘。
- ✅ 安全：剥离凭据不动（Task 4 保留 `_stripCredentials`）；路径穿越闸照搬（Task 5）。
- ✅ 向后兼容：旧备份 meta 无根 → 跳过重基只恢复 db（Task 2/5）；旧 BackupService 调用 root=null → 退化旧行为（Task 4）。

## 风险点

1. **archive 版本 API**：`ZipFileEncoder.addDirectory(includeDirName:)` 与 `addFile(...,STORE)` 签名以本仓 `sync_asset_package_service.dart` 实际用法为准（同包）。**实现前先读该文件确认**。
2. **封面位置二义**：cover 可能在 hoshi_books 或 audiobooks 下 → Task 5 Step 3 的双根 rebase 必须做，否则有声书封面恢复后失效。
3. ~~**bookKey vs bookUid**~~ **已核对解除**：Audiobooks 键列就是 `bookKey`（`tables.dart:60`）。同时发现并已纳入计划：`alignmentPath`（必填）也是需重基的第三个音频路径列（Task 3/5 已含）。
4. **解压期内存**：导入务必逐文件 `writeAsBytes`（现有 `_restoreDictionaryResources` 范式），不要把整 zip decode 进内存——去掉 512MB 闸后尤其关键。
5. **磁盘空间**：导入要删旧根再写新根，GB 级数据要确保有空间；失败要可回滚（sidecar/bak 机制目前只保 db，书/音频树的回滚是新风险，Task 5 需考虑「写新根失败时不毁旧根」——建议先写到临时根成功后再原子替换，或至少失败时不删旧 hoshi_books）。
