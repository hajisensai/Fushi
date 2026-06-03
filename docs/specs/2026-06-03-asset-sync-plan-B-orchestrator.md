# 双向并集同步编排器 — 实现计划（Plan B）

> **For agentic workers:** REQUIRED SUB-SKILL: 用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现。步骤用 `- [ ]` 复选框。**前置：Plan A（SyncAssetStore 地基）必须已落地且 `flutter test test/sync` 全绿。**

**Goal:** 让所有后端在自动同步时**双向全拉**：远端有本地无的书（EPUB）、有声书包（音频+字幕）、词典，自动下载导入到本地；本地有远端无的自动上传。两台设备最终镜像彼此的书库与词典库。

**Architecture:** 新建 `SyncOrchestrator`，基于 `SyncAssetStore`（Plan A）按命名空间做并集 diff。远端新布局：`books/<bookKey>/{content.epub, audiobook.hibikiaudio, progress.json, stats.json, audiopos.json}` 与 `dictionaries/<name>.hibikidict`。复用已测试的 `SyncAssetPackageService`（词典/有声书打包）、`EpubImporter.importFromPath`、`mergeStatistics`。

**Tech Stack:** Dart / Flutter 3.44.0；`flutter test`；slang i18n（`hibiki/tool/i18n_sync.dart`）。

**设计依据：** `docs/specs/2026-06-03-all-backend-asset-sync-design.md` §4-§8。

**已核实的 API 事实（写代码直接用）：**
- `EpubImporter.importFromPath({required HibikiDatabase db, required String filePath, required String fileName}) → Future<int>`（返回 book id；自带存储目录）。
- book → bookUid：`buildLegacyBookUid(book.id)`（`package:hibiki_core` 的 `legacy_book_uid.dart`，`'reader_ttu/hoshi://book/$bookId'`）。
- srtBookUid：`(await db.getSrtBookByTtuBookId(book.id))?.uid`（`AudiobookRow` 无 srtBookUid 字段）。
- `SyncAssetPackageService({required HibikiDatabase db})`，方法：
  - `exportDictionaryPackage({required String dictionaryName, required Directory dictionaryResourceRoot, required File outputFile}) → Future<File>`
  - `importDictionaryPackage({required File packageFile, required Directory dictionaryResourceRoot})`
  - `exportAudioDatabasePackage({required String bookUid, required String srtBookUid, required File outputFile}) → Future<File>`
  - `importAudioDatabasePackage({required File packageFile, required Directory audioDatabaseRoot})`
- DB：`getAllEpubBooks()`、`getEpubBook(id)`、`getReaderPosition(ttuBookId)`、`upsertReaderPosition(ReaderPositionsCompanion)`、`getAllDictionaryMetadata()`、`getAudiobookByBookUid(bookUid)`、`getSrtBookByTtuBookId(ttuBookId)`。
- `appModel.dictionaryResourceDirectory : Directory`、`appModel.databaseDirectory : Directory`、`appModel.temporaryDirectory : Directory`。
- gate 读取：`SyncRepository.isSyncContentEnabled()`、`isSyncDictionaryEnabled()`、`isSyncStatsEnabled()`、`isSyncAudioBookEnabled()` + 新增 `isSyncAudioBookFilesEnabled()`（Task 1）。

---

## Task 0：定位有声书音频/字幕的本地落地根目录（调查，必须先做）

`AppModel` **没有**全局有声书根目录访问器；音频按书存在 DB 的 `AudiobookRow.audioRoot`。`importAudioDatabasePackage` 需要一个 `audioDatabaseRoot`，会在其下建 `{root}/{bookUid}`。

- [ ] **Step 1:** 读现有有声书导入路径，找出新导入有声书时 `audioRoot` 取值的根目录约定：
  Run: `cd hibiki && grep -rn "audioRoot" lib/src/media/audiobook lib/src/models | head -40`
  以及看 `hibiki/lib/src/media/audiobook/` 的导入对话框/导入器，确认音频文件实际落盘的父目录（很可能是 `appDirectory` 或 `appModel.appDirectory` 下某子目录）。
- [ ] **Step 2:** 把确认到的根目录记为常量 `audioDatabaseRoot`（如 `Directory(p.join(appModel.appDirectory.path, 'audiobooks'))`），**必须与现有播放路径解析一致**，否则导入后播放找不到音频。在本计划后续任务统一用它。
- [ ] **Step 3:** 不提交（纯调查）。把结论写进本任务下方备注。

> 备注（执行时填写）：audioDatabaseRoot = `__________`

---

## Task 1：新增 `syncAudioBookFiles` 开关（repo + i18n + UI）

**Files:**
- Modify: `hibiki/lib/src/sync/sync_repository.dart`
- Modify: `hibiki/lib/src/sync/sync_settings_schema.dart`
- Modify: i18n 源 + `strings.g.dart`（经脚本）
- Test: `hibiki/test/sync/sync_repository_test.dart`

- [ ] **Step 1: 写失败测试（repo round-trip）**

在 `sync_repository_test.dart` 加：

```dart
test('syncAudioBookFiles defaults false and round-trips', () async {
  final repo = SyncRepository(db);
  expect(await repo.isSyncAudioBookFilesEnabled(), isFalse);
  await repo.setSyncAudioBookFilesEnabled(true);
  expect(await repo.isSyncAudioBookFilesEnabled(), isTrue);
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd hibiki && flutter test test/sync/sync_repository_test.dart -p vm`
Expected: FAIL（方法未定义）。

- [ ] **Step 3: 实现 repo 访问器**

在 `sync_repository.dart`：常量区加 `static const _keySyncAudioBookFiles = 'sync_audiobook_files_enabled';`，访问器区加：

```dart
  Future<bool> isSyncAudioBookFilesEnabled() =>
      _db.getPrefTyped<bool>(_keySyncAudioBookFiles, false);
  Future<void> setSyncAudioBookFilesEnabled(bool v) =>
      _db.setPrefTyped<bool>(_keySyncAudioBookFiles, v);
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd hibiki && flutter test test/sync/sync_repository_test.dart -p vm`
Expected: PASS。

- [ ] **Step 5: 加 i18n key（用脚本，禁止手改 17 文件）**

Run: `cd hibiki && dart run tool/i18n_sync.dart --add sync_audiobook_files "Sync audiobook files" "同步有声书文件"`
Run: `cd hibiki && dart run tool/i18n_sync.dart --add sync_audiobook_files_warning "Audio and subtitles can be large." "音频和字幕可能很大。"`
然后：`dart run slang` 重生成 `strings.g.dart`，再 `dart format lib/i18n/strings.g.dart`。

- [ ] **Step 6: 加 UI toggle**

在 `sync_settings_schema.dart` 的 Group 3（`sync_section_content`）`sync.audiobook` 项之后加：

```dart
          SettingsSwitchItem(
            id: 'sync.audiobook_files',
            title: t.sync_audiobook_files,
            subtitle: t.sync_audiobook_files_warning,
            icon: Icons.audio_file_outlined,
            value: (SettingsContext ctx) =>
                _syncSettings(ctx).syncAudioBookFiles,
            onChanged: (SettingsContext ctx, bool value) async {
              _syncSettings(ctx).syncAudioBookFiles = value;
              await SyncRepository(ctx.appModel.database)
                  .setSyncAudioBookFilesEnabled(value);
            },
          ),
```

并在 `_SyncSettingsState`（schema 文件底部，约 line 2311）加 `bool syncAudioBookFiles = false;` 字段，在其 `load()` 里加 `syncAudioBookFiles = await _repo.isSyncAudioBookFilesEnabled();`。

- [ ] **Step 7: 分析 + 测试**

Run: `cd hibiki && flutter analyze lib/src/sync && flutter test test/sync/sync_repository_test.dart test/i18n -p vm`
Expected: PASS（i18n 完整性测试不报缺 key）。

- [ ] **Step 8: Commit**

```bash
git add hibiki/lib/src/sync/sync_repository.dart hibiki/lib/src/sync/sync_settings_schema.dart hibiki/lib/i18n hibiki/test/sync/sync_repository_test.dart
git commit -m "feat(sync): add 'sync audiobook files' toggle"
```

---

## Task 2：`SyncOrchestrator` 骨架 + 命名空间常量

**Files:**
- Create: `hibiki/lib/src/sync/sync_orchestrator.dart`
- Test: `hibiki/test/sync/sync_orchestrator_test.dart`

- [ ] **Step 1:** 定义 orchestrator，注入 `SyncAssetStore`（即后端，Plan A 后 `SyncBackend implements SyncAssetStore`）、`HibikiDatabase`、`SyncRepository`、目录、gate 标志、`SyncAssetPackageService`。命名空间常量 `_kBooks='books'`、`_kDicts='dictionaries'`，资产名常量 `content.epub`/`audiobook.hibikiaudio`/`progress.json`/`stats.json`/`audiopos.json`，词典名 `'$name.hibikidict'`。bookKey = `sanitizeTtuFilename(title)`（来自 `ttu_filename.dart`）。

构造与字段（完整签名）：

```dart
class SyncOrchestrator {
  SyncOrchestrator({
    required HibikiDatabase db,
    required SyncAssetStore store,
    required Directory dictionaryResourceRoot,
    required Directory audioDatabaseRoot,
    required Directory tempDir,
    required bool syncContent,
    required bool syncAudioBookFiles,
    required bool syncDictionary,
    required bool syncStats,
    required bool syncAudioBookPos,
    void Function(double fraction)? onProgress,
  });

  Future<SyncRunReport> run();          // 跑一次双向全量
}
```

`SyncRunReport`：`{int booksImported, booksExported, dictsImported, dictsExported, audiobooksImported, audiobooksExported; List<String> errors;}`。

- [ ] **Step 2:** 静态分析通过；先不写 run() 内部，返回空 report，让骨架编译。Commit `feat(sync): SyncOrchestrator skeleton`。

---

## Task 3：词典双向同步（最独立，先做）

**Files:** Modify `sync_orchestrator.dart`；Test `sync_orchestrator_test.dart`

- [ ] **Step 1: 写失败测试（fake store + 两个内存 DB）**

用 Plan A 的 `FakeAssetStore`。源 DB 有 1 个词典 + resource 目录有文件；跑"推送"后 fake store 的 `dictionaries/<name>.hibikidict` 存在；换目标 DB（空）+ 同一 fake store，跑"拉取"后目标 DB 有该词典 meta 且 resource 目录落地。断言 round-trip。

- [ ] **Step 2: 跑确认失败。**

- [ ] **Step 3: 实现 `_syncDictionaries()`**：
  - gate：`if (!syncDictionary) return;`
  - `ns = await store.ensureNamespace('dictionaries');`
  - 本地：`getAllDictionaryMetadata()` → names。远端：`store.listChildren(ns)` → 文件名去 `.hibikidict` 后缀。
  - 本地有远端无：`exportDictionaryPackage(dictionaryName:name, dictionaryResourceRoot:dictionaryResourceRoot, outputFile: tmp)` → `store.putAsset(ns, '$name.hibikidict', tmp)`。
  - 远端有本地无：`store.getAsset(entry.id, tmp)` → `importDictionaryPackage(packageFile:tmp, dictionaryResourceRoot:dictionaryResourceRoot)`。
  - per-item try/catch 收进 `errors`，临时文件用后删。

- [ ] **Step 4: 跑确认通过。Commit** `feat(sync): bidirectional dictionary sync`。

---

## Task 4：书籍 EPUB 双向同步 + 接收远端新书

**Files:** Modify `sync_orchestrator.dart`；Test `sync_orchestrator_test.dart`

- [ ] **Step 1: 写失败测试**：源 DB 有 1 本已导入 EPUB（用测试夹具 epub）；推送后 fake store `books/<bookKey>/content.epub` 存在 + `progress.json`。目标空 DB 拉取后：`EpubImporter` 建了书行（`getAllEpubBooks()` 含该 title）且 reader position 导入。
- [ ] **Step 2: 跑确认失败。**
- [ ] **Step 3: 实现 `_syncBooks()`**：
  - `booksNs = await store.ensureNamespace('books');`
  - 本地按 `sanitizeTtuFilename(title)` 建 map；远端 `store.listChildren(booksNs)` 取 isFolder 的 bookKey。
  - **本地有**：`folderId = await store.ensureFolder(booksNs, bookKey);`
    - 若 `syncContent` 且远端缺 `content.epub`（`findAsset`==null）→ `putAsset(folderId,'content.epub', File(book.epubPath))`。
    - 进度：读 `getReaderPosition(book.id)`，按时间戳与远端 `progress.json`（`getJsonAsset`）新旧决定 put/skip；统计同理（gate `syncStats`）；位置 `audiopos.json`（gate `syncAudioBookPos`）。
  - **远端有本地无**（bookKey 不在本地 map）且 `syncContent`：
    - `epub = await store.findAsset(folderId,'content.epub');` 若为 null → 记日志跳过（发送端没开 content）。
    - 下载到 `tempDir`，`final id = await EpubImporter.importFromPath(db: db, filePath: tmp.path, fileName: '$bookKey.epub');`
    - 读远端 `progress.json` → `upsertReaderPosition(ReaderPositionsCompanion(ttuBookId: Value(id), ...))`。
  - 进度方向沿用现有 `_determineSyncDirection` 思路（可从 `sync_manager.dart` 提取为纯函数复用，避免重复实现）。
- [ ] **Step 4: 跑确认通过。Commit** `feat(sync): bidirectional book + remote-book import`。

---

## Task 5：有声书包双向同步

**Files:** Modify `sync_orchestrator.dart`；Test `sync_orchestrator_test.dart`

- [ ] **Step 1: 写失败测试**：源 DB 有书 + audiobook 行 + srtBook 行 + cues + 音频/srt 文件（夹具）；推送后 fake store `books/<bookKey>/audiobook.hibikiaudio` 存在。目标 DB（已有该书）拉取后 `getAudiobookByBookUid` / `getSrtBookByTtuBookId` / `getCuesForBook` 都还原。
- [ ] **Step 2: 跑确认失败。**
- [ ] **Step 3: 实现 `_syncAudiobooks()`**（gate `syncAudioBookFiles`）：
  - 对每本本地书：`bookUid = buildLegacyBookUid(book.id)`；`srt = await db.getSrtBookByTtuBookId(book.id)`；若 `getAudiobookByBookUid(bookUid)!=null && srt!=null` 且远端缺 `audiobook.hibikiaudio` → `exportAudioDatabasePackage(bookUid: bookUid, srtBookUid: srt.uid, outputFile: tmp)` → `putAsset`。
  - 远端有本地（书已存在）无有声书 → `getAsset` → `importAudioDatabasePackage(packageFile: tmp, audioDatabaseRoot: audioDatabaseRoot)`（Task 0 的根目录）。
  - 注意顺序：有声书导入依赖书已存在 → `_syncBooks()` 必须在 `_syncAudiobooks()` 之前跑。
- [ ] **Step 4: 跑确认通过。Commit** `feat(sync): bidirectional audiobook package sync`。

---

## Task 6：`run()` 编排 + 接线 auto-sync 与 compare

**Files:** Modify `sync_orchestrator.dart`、`sync_auto_trigger.dart`、`sync_compare_dialog.dart`

- [ ] **Step 1:** `run()` 顺序：`_syncBooks()` → `_syncAudiobooks()` → `_syncDictionaries()`，聚合 report。
- [ ] **Step 2:** `sync_auto_trigger.dart` 的 `_runAutoSyncAll`：构造 `SyncOrchestrator`（从 repo 读全部 gate + appModel 目录），调 `run()`，替换原 `SyncManager.syncAllBooks` 单向调用。`_runAutoSync`（单本关闭触发）保留轻量进度同步即可，或同样走 orchestrator 但仅该书——按现有行为最小改动，注释说明。
- [ ] **Step 3:** `sync_compare_dialog.dart`：修 `_load`（line ~314）——`bookId == null` 的远端独有项不再无条件 skip：当 `syncContent` 开时标 `useRemote`；修 `_applyChoices`（line ~340）actionable 过滤去掉 `bookId != null` 硬条件，远端独有项走 orchestrator 的远端导入路径。compare 仍展示、可取消。
- [ ] **Step 4:** 分析 + 全 sync 测试：`cd hibiki && flutter analyze lib/src/sync && flutter test test/sync -p vm`。Expected: 全绿（含现有测试零回归 + 新 orchestrator 测试）。
- [ ] **Step 5: Commit** `feat(sync): wire orchestrator into auto-sync and compare`。

---

## Task 7：清理旧布局耦合 + 全量验证

**Files:** 视情况 Modify `sync_manager.dart`（若 orchestrator 已取代其全量入口，标记 deprecated 或删除未用方法；保留被 compare 单本仍用的部分）。

- [ ] **Step 1:** 确认 `sync_manager.dart` 中已无用代码（被 orchestrator 取代的全量遍历）；删除或保留按实际引用。不破坏 compare 单本路径。
- [ ] **Step 2:** `cd hibiki && dart format . && flutter analyze && flutter test`（全量）。Expected: 全绿。
- [ ] **Step 3: 设备复测（声明"修好了"前必做）**：两台真机/模拟器，同一 Google Drive，A 导入 EPUB+有声书+词典并开启对应 toggle → B 开自动同步 → 验证 B 出现该书可读、有声书可播、词典可查。留证据（docs/agent/integration-testing.md）。按 docs/BUGS.md 记 BUG 条目（验真→①根因修复→②自动化测试两勾选框 + 提交哈希）。
- [ ] **Step 4: Commit** 收尾。

---

## 自检（Plan B 对照设计 §4-§8）

- §4 远端布局 books/dictionaries + 5 个资产名 → Task 2 常量、Task 3-5 读写：覆盖。
- §5 开关模型新增 `syncAudioBookFiles` → Task 1：覆盖。
- §6 双向并集 + 接收远端新书/有声书/词典 → Task 3/4/5/6：覆盖。
- §6 接线 auto-sync + compare → Task 6：覆盖。
- §7 增量并集不传播删除 → 各 sync 方法只"缺则传"，无删除分支：覆盖。
- §8 错误处理 per-item + 临时文件清理 → Task 3-5 each：覆盖。
- 顺序约束（书先于有声书）→ Task 6 Step 1 明确：覆盖。
- **未决点已显式处理**：audioDatabaseRoot 由 Task 0 调查确定，非编造；进度方向函数从 `sync_manager` 提取复用，非重写。
