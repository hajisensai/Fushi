# 全后端书籍 + 有声书 + 词典同步（资产层重构）— 设计文档

- 日期：2026-06-03
- 状态：设计已确认（用户逐节批准），待写实现计划（writing-plans）
- 范围：`hibiki/lib/src/sync/` —— 引入 `SyncAssetStore` 资产抽象层，让**所有**同步后端支持书籍（EPUB）、有声书（音频+字幕）、词典的**双向**同步
- 方案：**方案 C**（独立资产存储抽象层，取代现有 `SyncBackend` 文件接口）
- 执行原则：彻底根因实现；改造后端核心接口，但保证现有"书籍进度同步"零破坏；实现后进入 审查→修复→循环 直到 Opus code review 通过（CLAUDE.md 强制流程）

---

## 1. 背景与问题（已沿真实代码路径验真）

用户诉求：用 Google Drive（及所有其它后端）同步时，**另一台设备收不到书和词典**。期望开启后两台设备镜像彼此的书库（含有声书、字幕）与词典库。

当前实现的三个根因缺口：

### 1.1 书籍：接收远端新书的能力根本不存在
- 书籍同步只在"两台设备都已按书名导入同一本书"之间同步进度/统计/有声书位置（小 JSON）。
- `sync_compare_dialog.dart:314` 把 `bookId == null`（远端独有、本地没有的书）一律 `SyncChoice.skip`；`:340-343` 的 actionable 过滤又要求 `bookId != null`。`syncAllBooks` 只遍历本地书。
- → 设备 A 的新书在远端建了文件夹 + EPUB，但设备 B 没有任何路径去发现并导入它。
- 次要：`sync_manager.dart:184-186` 当进度判定为 `synced` 时提前返回，连已共享书的 EPUB/内容补传也被跳过。

### 1.2 词典：根本没接后端
- `sync.dictionary` 开关只在 `backup_service.dart:118` 被读，仅决定本地备份 ZIP 是否打包词典。引入提交即 `feat(sync): add dictionary **backup** option`。
- `SyncAssetPackageService.exportDictionaryPackage/importDictionaryPackage` 已存在且有测试，但**只被测试调用**，未接到任何后端或 UI。

### 1.3 有声书 + 字幕：未纳入同步
- 有声书音频、SRT 字幕、cues、对齐数据完全不参与后端同步。
- `SyncAssetPackageService.exportAudioDatabasePackage/importAudioDatabasePackage` 已存在且有测试（打包 audiobook 行 + srtBook 行 + cues + 音频文件 + 对齐文件 + 封面），同样未接线。

## 2. 已确认决策

| 决策点 | 结论 |
|--------|------|
| 架构方案 | **C**：独立 `SyncAssetStore` 抽象层，书籍/有声书/词典三类资产都走它 |
| 书籍范围 | 书籍 bundle 含 EPUB + 有声书包(音频+字幕) + 进度/统计 |
| 旧数据兼容 | **无历史用户，旧同步数据可清空，不做迁移**；新布局 `books/`、`dictionaries/`，旧 `ttu-reader-data/` 直接无视 |
| 拉取时机 | 自动同步时**自动全拉**（双向并集，两端镜像） |
| 有声书音频开关 | **EPUB 一组，有声书(音频+字幕+cues 整体一个包)一组**；包不拆，整包复用 `exportAudioDatabasePackage` |
| 同步语义 | 增量并集，**不传播删除** |
| 删除传播 | 本次范围外（YAGNI + 安全） |

## 3. 核心抽象：`SyncAssetStore`

新建与业务无关的资产存取层，后端只负责"存/取/列命名空间下的二进制资产"：

```dart
class AssetEntry {
  const AssetEntry({required this.id, required this.name, this.sizeBytes});
  final String id;        // 后端原生定位符（Drive fileId / WebDAV href / ...）
  final String name;      // 业务可见名（bookKey 下的 content.epub、dictionaries 下的 <name>.hibikidict）
  final int? sizeBytes;
}

abstract class SyncAssetStore {
  /// 确保某命名空间（顶层文件夹/前缀）存在，返回其定位符。
  Future<String> ensureNamespace(String name);

  /// 列出某命名空间下的直接子项（资产或子命名空间），用于并集 diff。
  Future<List<AssetEntry>> listAssets(String namespaceId);

  /// 在 [namespaceId] 下确保一个子命名空间（如某本书的 bookKey 文件夹）。
  Future<String> ensureSubNamespace(String namespaceId, String name);

  Future<AssetEntry?> findAsset(String namespaceId, String name);

  Future<void> putAsset(
    String namespaceId,
    String name,
    File file, {
    void Function(double progress)? onProgress,
  });

  Future<void> getAsset(
    String assetId,
    File destination, {
    void Function(double progress)? onProgress,
  });

  Future<void> deleteAsset(String assetId);

  // ── 小 JSON metadata（进度/统计/位置）仍走轻量通道 ──
  Future<Map<String, Object?>?> getJson(String assetId);
  Future<void> putJson(String namespaceId, String name, Object? json);
}
```

设计要点：
- **命名空间 = 文件夹/前缀**，子命名空间用于 `books/<bookKey>/`。
- 现有 `ensureBookFolder` / `uploadContentFile` / `downloadContentFile` / `findContentFile` / `listBooks` / `listSyncFiles` / `getProgressFile` / `updateProgressFile` 等**改造为委托到 `SyncAssetStore`**，或被其取代。
- 7 个后端各实现这套接口：`webDav` / `hibikiServer`(HibikiClient) / `ftp` / `sftp` 多数共用 `WebDavOps`（`hibiki/lib/src/sync/webdav_ops.dart`）；`googleDrive`(经 `google_drive_handler.dart`) / `oneDrive` / `dropbox` 各自 REST。
- `SyncBackend` 的认证/缓存部分（isAuthenticated / authenticate / restoreAuth / clearCache / restoreCache）**保留不动**。

## 4. 全新远端布局

```
<root>/
├── books/
│   └── <bookKey>/                  bookKey = sanitizeTtuFilename(title)
│       ├── content.epub            ← EPUB 资产           （gate: sync.content）
│       ├── audiobook.hibikiaudio   ← 有声书包(音频+字幕+cues+对齐+封面)（gate: 新 sync.audiobookFiles）
│       ├── progress.json           ← 阅读进度（小 JSON）  （gate: 始终；方向按时间戳）
│       └── stats.json              ← 统计（小 JSON）      （gate: sync.statistics）
│       └── audiopos.json           ← 有声书播放位置（小 JSON）（gate: sync.audiobook）
└── dictionaries/
    └── <name>.hibikidict           ← 词典包             （gate: sync.dictionary）
```

- 大资产（`content.epub` / `audiobook.hibikiaudio` / `*.hibikidict`）经 `putAsset`/`getAsset`，带进度回调。
- 小 JSON（progress/stats/audiopos）经 `putJson`/`getJson`。
- 旧 `ttu-reader-data/` 布局**不读不迁移**；首次新版同步在新 `books/`、`dictionaries/` 下重建。

## 5. 同步开关模型（最终）

| 开关 id | 标题 | 控制 | 现状 |
|---|---|---|---|
| `sync.content` | 同步书籍文件 | `content.epub` | 已有，语义收窄为仅 EPUB |
| `sync.audiobookFiles`（新增） | 同步有声书文件 | `audiobook.hibikiaudio`（音频+字幕+cues 整包） | 新增 toggle + i18n |
| `sync.dictionary` | 同步词典 | `<name>.hibikidict` | 已有，语义从"仅备份"扩展为"同步 + 备份" |
| `sync.audiobook` | 同步有声书进度 | `audiopos.json` 播放位置 | 已有，不变 |
| `sync.statistics` | 同步统计 | `stats.json` | 已有，不变 |
| `sync.auto_sync` | 自动同步 | 触发后台全量双向同步 | 已有，不变 |

新增持久化键：`sync_audiobook_files_enabled`（默认 false，大文件保守默认关）。经 `SyncRepository` 新增 `isSyncAudioBookFilesEnabled()/setSyncAudioBookFilesEnabled()`。
i18n 新键：`sync_audiobook_files` + `sync_audiobook_files_warning`，**必须走 `hibiki/tool/i18n_sync.dart`**，改完跑 `dart run slang` + `dart format`。

## 6. 双向同步编排器

新建 `SyncOrchestrator`（或重写 `SyncManager`），auto-sync 调一次跑全量：

1. **列两端**
   - 本地：`db.getAllEpubBooks()` 按 `sanitizeTtuFilename(title)` 建集合；`db.getAllDictionaryMetadata()` 按 name 建集合。
   - 远端：`store.listAssets(ensureNamespace('books'))` 得远端 bookKey 集合；`store.listAssets(ensureNamespace('dictionaries'))` 得远端词典集合。

2. **本地有 → 推送**（按各 gate）
   - bookKey 子空间缺 `content.epub` 且 `syncContent` → `putAsset`。
   - 缺 `audiobook.hibikiaudio` 且 `syncAudioBookFiles` 且本地该书有有声书 → `exportAudioDatabasePackage` → `putAsset`。
   - 缺词典包且 `syncDictionary` → `exportDictionaryPackage` → `putAsset`。
   - 进度/统计/位置：按时间戳新旧合并（沿用 `_determineSyncDirection` + `mergeStatistics`）。

3. **远端有本地无 → 拉取导入**（按各 gate）
   - 下载 `content.epub`（若 `syncContent`）→ `EpubImporter`（`hibiki/lib/src/epub/`）建本地书行。
   - 若有 `audiobook.hibikiaudio` 且 `syncAudioBookFiles` → 下载 → `importAudioDatabasePackage` 建有声书/字幕/cues。
   - 导入 `progress.json`/`stats.json`/`audiopos.json`。
   - 远端独有词典且 `syncDictionary` → 下载 → `importDictionaryPackage`。

4. **接线点**
   - `sync_auto_trigger.dart` 的 `_runAutoSyncAll` / `_runAutoSync`：调编排器全量双向。
   - `sync_compare_dialog.dart`：`bookId == null` 的远端独有书不再无条件 skip；列出可拉取项（用户已选自动全拉，compare 仍可见可取消）。修 `_load` 与 `_applyChoices` 的过滤。

## 7. 身份与冲突

- 书籍身份 = `sanitizeTtuFilename(title)`；词典身份 = `DictionaryMetaRow.name`（已是导入去重键）。
- **增量并集，不传播删除**。
- 大资产内容不可变：已存在即跳过，不重复传（`findAsset` 命中即跳）。
- 小 JSON：时间戳新旧合并；统计走 `mergeStatistics`。
- 旧远端数据可清空：本地 `sync_folder_cache`/`sync_root_folder_id` 清一次重建（与新布局对齐）。

## 8. 错误处理

- 单本书/单词典/单有声书导入失败不阻断整体（per-item try/catch + 错误聚合，沿用现有模式）。
- 包解压路径穿越校验已内置于 `SyncAssetPackageService._extractArchivePrefix`（保留）。
- 部分下载失败清理临时文件（`getAsset` 实现 finally 清理，沿用现有 download 逻辑）。
- 资产层与 metadata 层错误分别处理：EPUB 下载失败不应连带丢进度同步。
- 可重试错误：保留 `_backend.clearCache()` 丢内存态，**不清磁盘 folder 缓存**（沿用 F1 修复结论）。

## 9. 改动文件清单

| 文件 | 改动 |
|------|------|
| `hibiki/lib/src/sync/sync_asset_store.dart`（新建） | `SyncAssetStore` 抽象 + `AssetEntry` |
| `hibiki/lib/src/sync/sync_backend.dart` | 文件/文件夹接口迁移到 `SyncAssetStore`；保留 auth/cache；`resolveSyncBackend` 不变 |
| `hibiki/lib/src/sync/google_drive_sync_backend.dart` + `google_drive_handler.dart` | 实现 `SyncAssetStore`（Drive REST） |
| `hibiki/lib/src/sync/webdav_sync_backend.dart` | 实现 `SyncAssetStore`（`WebDavOps`） |
| `hibiki/lib/src/sync/hibiki_client_sync_backend.dart` | 实现 `SyncAssetStore`（`WebDavOps`） |
| `hibiki/lib/src/sync/ftp_sync_backend.dart` | 实现 `SyncAssetStore` |
| `hibiki/lib/src/sync/sftp_sync_backend.dart` | 实现 `SyncAssetStore` |
| `hibiki/lib/src/sync/onedrive_sync_backend.dart` | 实现 `SyncAssetStore`（OneDrive REST） |
| `hibiki/lib/src/sync/dropbox_sync_backend.dart` | 实现 `SyncAssetStore`（Dropbox REST） |
| `hibiki/lib/src/sync/sync_manager.dart` → `sync_orchestrator.dart` | 重写为基于 bundle 的双向并集同步 |
| `hibiki/lib/src/sync/sync_compare_dialog.dart` | 放开远端独有书/词典的拉取，修 `_load`/`_applyChoices` 过滤 |
| `hibiki/lib/src/sync/sync_auto_trigger.dart` | 接编排器全量双向 |
| `hibiki/lib/src/sync/sync_repository.dart` | 加 `syncAudioBookFiles` 访问器 + 键 |
| `hibiki/lib/src/sync/sync_settings_schema.dart` | 加"同步有声书文件" toggle |
| `hibiki/lib/src/sync/sync_asset_package_service.dart` | 复用，不改逻辑（必要时暴露细粒度 API） |
| i18n 源 + `strings.g.dart` | 经 `i18n_sync.dart` 增 `sync_audiobook_files*` |

## 10. 测试与验证

- **AssetStore 契约测试**：fake `SyncAssetStore` round-trip（ensureNamespace / list / put / get / findAsset / json）。
- **编排器测试**（fake backend，无网络）：
  - 远端独有书 → `EpubImporter` 建行 + 进度导入。
  - 远端独有有声书包 → `importAudioDatabasePackage` 建有声书/字幕/cues。
  - 远端独有词典 → `importDictionaryPackage`。
  - 本地独有 → 推送各资产。
  - 两端进度新旧 → 正确方向 + 统计 merge。
  - gate 关闭时对应资产不传。
- **回归守卫**：现有 `sync_*_test.dart` 必须仍绿（书籍进度同步零破坏）；源码扫描守卫：`listAssets('books')` 不串入 `dictionaries`。
- **现有打包测试**：`sync_asset_package_service_test.dart` 不回归。
- **命令**：`hibiki/` 下 `dart format .` + `flutter test`。Android manifest/权限/Gradle 无改动，**无需** `assembleRelease`。
- **设备复测**（声明"修好了"前必做）：两台真实设备 / 模拟器，同一 Google Drive 账户，A 导入 EPUB+有声书+词典 → B 自动同步后出现并可读/可播/可查，留证据（见 docs/agent/integration-testing.md）。

## 11. 向后兼容与风险

- **无历史用户**：旧远端数据可清空，旧 `ttu-reader-data/` 不读不迁移，无破坏面。
- **最大风险**：改造 `SyncBackend` 文件接口可能碰坏现有"书籍进度同步"。缓解＝改造采用委托而非删除语义、现有 sync 单测全绿守门、新增 fake-backend 端到端测试。
- **大文件流量**：有声书音频默认关（`syncAudioBookFiles=false`），用户显式开启；自动全拉时给进度回调与日志，不静默拉几百 MB。
- **词典体积**：词典包可能很大，`sync.dictionary` 仍默认关（现状），保留 warning 文案。

## 12. 本次范围外（未来）

- 删除传播（一端删书/词典 → 另一端删）。
- 增量更新已存在的大资产（当前内容不可变，已存在即跳过）。
- 同步冲突的人工三方合并 UI（当前时间戳自动 + compare 手选）。
- 有声书包的细粒度拆分（音频/字幕分包）——本次按用户决策整包。
