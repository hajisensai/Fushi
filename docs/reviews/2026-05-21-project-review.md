# Hibiki 项目深度质量审查报告

**日期**: 2026-05-21
**审查范围**: 全代码库 — 架构、实现、工程规范、安全、性能、可维护性
**审查方法**: 6 路并行深度扫描 + 核心文件逐行审读
**代码库规模**: ~200 Dart 文件 / ~85K 行（主应用）+ 118 文件（packages）

---

## 第一轮：全局架构与致命风险

### Scope

全代码库架构层面扫描：`app_model.dart`、数据库层、阅读器 WebView、字典 FFI、Creator/Anki、异步/错误处理模式。

---

## Findings

---

### HBK-AUDIT-001 — AppModel 上帝对象

**Severity**: CRITICAL
**Status**: open
**文件**: `hibiki/lib/src/models/app_model.dart` (4,045 行)

**根因**: `AppModel` 是一个典型的上帝对象（God Object），单个 `ChangeNotifier` 承载了整个应用的所有全局状态：

| 职责 | 行数估算 |
|------|----------|
| 主题/颜色定制 | ~300 行 |
| 偏好存取（50+ getter/setter 对） | ~600 行 |
| 字典管理（导入/排序/搜索/历史） | ~800 行 |
| 媒体源管理 | ~300 行 |
| 初始化/迁移 | ~300 行 |
| 书架/MediaItem 缓存 | ~200 行 |
| 音频/TTS/有声书桥接 | ~200 行 |
| 导出/文件管理 | ~200 行 |
| Profile 系统 | ~100 行 |
| 卡片创建辅助 | ~150 行 |
| 杂项 | ~800 行 |

**关键指标**:
- 31 个 `late final` 声明 — 严格依赖初始化顺序
- 54 次 `notifyListeners()` 调用 — 任何属性变更都触发全树重建
- 28 个 `catch` 块，其中 3 个 `catch (_) {}` 完全吞噬异常
- 10 个 `dynamic` 类型使用

**影响**:
1. **性能**: 改一个偏好就 `notifyListeners()` -> 全部 `Consumer<AppModel>` 重建，包括与该偏好无关的 widget
2. **可测试性**: 无法单独测试字典逻辑、主题逻辑、偏好逻辑 — 必须实例化整个 AppModel
3. **并发安全**: 多个异步方法同时修改 `_prefCache`、`_dictionariesCache`、`_mediaItemsCache` 等共享可变状态，无锁无同步
4. **生命周期**: 31 个 `late final` 如果初始化顺序打乱 -> `LateInitializationError` 崩溃，且错误信息无法定位是哪个字段

**修复建议**: 拆分为独立的 Riverpod Provider/Notifier：
- `ThemeNotifier` — 主题/颜色
- `PreferencesRepository` — 偏好读写（可注入 mock DB）
- `DictionaryRepository` — 字典 CRUD + 搜索
- `MediaHistoryRepository` — 媒体历史
- `ProfileRepository`（已存在，需完全解耦）

**验证方式**: 拆分后单元测试每个 Repository，验证 `notifyListeners` 精确到子模块。

---

### HBK-AUDIT-002 — 阅读器状态机竞态条件（位置保存 vs 导航）

**Severity**: CRITICAL
**Status**: not-reproducible — 2026-05-21 验证：`_debouncedSaveReaderPosition(int section, double progress)` 参数已被闭包捕获为值，timer 触发时不依赖实例变量。审查报告描述的竞态场景在当前代码中不存在。
**文件**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:2189-2551`

**根因**: 位置保存使用 500ms debounce Timer，导航操作直接修改 `_currentChapter`，两者无同步机制。

**竞态场景**:
1. 用户在第 3 章 50% 位置，debounce timer 待触发
2. 用户快速跳转到第 5 章
3. `_currentChapter = 5`，`_initialProgress` 更新
4. 500ms 后 timer 触发 `_persistPosition()`，使用已被修改的 `_currentChapter`
5. 位置被错误保存为第 5 章（用户只是短暂经过）

**影响**: 用户阅读位置丢失，下次打开书直接跳到错误章节。

**修复建议**: 在 `_debouncedSaveReaderPosition` 中捕获当前 section 和 progress 到闭包局部变量，而非依赖实例变量。

---

### HBK-AUDIT-003 — WebView Controller 生命周期竞态

**Severity**: CRITICAL
**Status**: fixed — 2026-05-21 在 `_applyStylesLive`、`_syncPageSize`、`_applyChapterHighlights`、`_updateLyricsStyleLive`、`_paginate`、`_reloadWithCurrentSettings` 6 个方法中添加了 `if (!mounted || _controller == null) return;` 守卫。
**文件**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:1091-1130`

**根因**: `_applyStylesLive()` 等方法先检查 `_controller != null`，然后执行多个 `await`，期间 `dispose()` 可能被调用。

```
_applyStylesLive() 开始 -> _controller != null (ok)
    | await _syncSettingsFromHive() (100+ ms)
        | 用户返回 -> dispose() 被调用 -> _controller 失效
    | _controller!.evaluateJavascript() -> CRASH
```

**影响**: 用户快速退出阅读器时崩溃。

**修复建议**: 所有 `evaluateJavascript()` 调用包裹 try-catch 捕获 `PlatformException`（controller disposed），或在每个 await 点后重新检查 `mounted && _controller != null`。

---

### HBK-AUDIT-004 — JavaScript 模板字符串转义不完整

**Severity**: HIGH
**Status**: fixed — 2026-05-21 `_applyStylesLive` 中手动转义替换为 `jsonEncode(css)` 安全编码。
**文件**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:1113-1129`

**根因**: CSS 注入到 JS 模板字符串时只转义了 `\`, `` ` ``, `$`，但未处理 `${}` 模式。

```dart
final String escaped = css
    .replaceAll('\\', '\\\\')
    .replaceAll('`', '\\`')
    .replaceAll('\$', '\\\$');
// 注入到: el.textContent = `$escaped`;
```

如果 CSS 包含 `${...}` 形式的内容（虽然不常见，但自定义 CSS 用户可输入），可能导致 JS 执行。

**影响**: 自定义 CSS 功能存在 XSS 风险（虽然是本地 WebView，非远程攻击面，但仍可导致阅读器行为异常）。

**修复建议**: 使用 `JSON.encode(css)` 生成安全字符串，或用 Blob URL 替代模板字符串注入。

---

### HBK-AUDIT-005 — 字典 ZIP 解压无内存限制

**Severity**: HIGH
**Status**: fixed — 2026-05-21 Dart fallback 路径添加单文件 256MB 上限 + 总解压 2GB 上限，超限中止。FFI 快速路径仍无限制（需 native 层修复）。
**文件**: `packages/hibiki_dictionary/lib/src/formats/yomichan_dictionary_format.dart:120-145`

**根因**: Dart fallback 解压路径 `writeAsBytesSync(file.content as List<int>)` 将整个文件内容加载到内存。

**影响**: 导入 1GB+ 字典 ZIP 时 RAM 峰值 2GB+，中端手机直接 OOM 崩溃。

**修复建议**: 改用流式解压，或至少在解压前检查 `uncompressedSize` 并拒绝超限文件。

---

### HBK-AUDIT-006 — C++ 导入器无资源上限

**Severity**: MEDIUM
**Status**: open
**文件**: `native/hoshidicts/hoshidicts_src/importer.cpp:200-250`

**根因**: 无最大条目数、最大条目大小、最大字典总大小限制。glossary 和 frequency 数组无界。

**影响**: 恶意构造的字典 ZIP 可通过海量条目触发 OOM。

**修复建议**: 添加硬限制：单文件最大 100K 条目，单条目 expression 最大 64KB，频率条目最大 1000/term。

---

### HBK-AUDIT-007 — 阅读器多标志状态机（非原子）

**Severity**: MEDIUM
**Status**: fixed — 2026-05-22 在 `_onChapterLoadComplete()` 入口捕获 `_navigateGeneration`，每个 `await` 点后校验 generation 变化，阻止过期加载完成处理。
**文件**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:1467-1617`

**根因**: 阅读器使用多个独立布尔标志管理状态：`_readerContentReady`、`_hasEverLoaded`、`_restoreInFlight`、`_restoreExpectedGeneration`。这些标志之间没有原子性保证。

快速导航场景：
1. 加载第 1 章 (gen=1) -> 设置 `_restoreExpectedGeneration=1`
2. 快速跳转第 2 章 (gen=2) -> 设置 `_restoreExpectedGeneration=2`
3. 第 1 章的 `onLoadStop` 触发 (gen=1)，但 generation 不匹配 -> 静默跳过
4. 进度轮询在错误状态下启动/停止

**影响**: 快速导航时进度轮询不稳定，可能导致章节内位置不准确。

**修复建议**: 用枚举状态机替代多布尔标志：
```dart
enum ReaderState { idle, loading, restoring, ready, error }
```

---

### HBK-AUDIT-008 — Stream/Timer 资源泄漏风险

**Severity**: MEDIUM
**Status**: false-positive — 2026-05-22 验证：所有 StreamSubscription 在重新创建前已正确 `cancel()`，所有 Timer 在 `dispose()` 中正确取消，`catch (_) {}` 仅用于 WakelockPlus 等可选平台功能。
**文件**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:2756-2773`

**根因**: `_subscribeNotificationStreams()` 每次被调用时创建新订阅，但如果 `_initAudioFeatures()` 被多次调用（行 667, 749），旧订阅的 `ctrl` 闭包引用被泄漏。

全局统计：
- 15 处 `catch (_) {}` 完全吞噬异常（详见附录 A）
- 10 处 `StreamSubscription` 声明，部分缺少对应 `cancel()`
- `reader_hoshi_page.dart` 中 4 处 `catch (_) {}` — 阅读器最关键路径上的静默失败

**修复建议**: 在重新订阅前断言旧订阅已取消。添加 `@mustCallSuper` dispose 检查。

---

### HBK-AUDIT-009 — Creator/Anki 大规模代码重复

**Severity**: MEDIUM
**Status**: open
**文件**: 多文件

**重复清单**:

| 重复区域 | 文件 | 重复行数 |
|----------|------|----------|
| AudioField / AudioSentenceField | `fields/audio_field.dart`, `fields/audio_sentence_field.dart` | **300+ 行 (95%相同)** |
| AnkiConnect / AnkiDroid `mineEntry()` | `ankiconnect_repository.dart`, `anki_repository.dart` | **100+ 行 (90%相同)** |
| 3 个 Cloze 字段 | `cloze_before_field.dart`, `cloze_after_field.dart`, `cloze_inside_field.dart` | **~40 行结构相同** |
| 3 个 Meaning 变体字段 | `collapsed_meaning_field.dart`, `expanded_meaning_field.dart`, `hidden_meaning_field.dart` | **~45 行逻辑相同** |
| PickImage / PickAudio 增强 | `pick_image_enhancement.dart`, `pick_audio_enhancement.dart` | **~70 行模式相同** |

**总计**: ~555+ 行可消除的重复。

**影响**: 修复一个 bug 需要在 2-3 个文件中同步修改。AudioField 和 AudioSentenceField 尤其危险 — 375 行几乎相同的代码，任何音频播放器的 bug 修复都必须做两次。

**修复建议**:
1. 提取 `AudioPlayerField` 基类，AudioField 和 AudioSentenceField 只保留构造函数差异
2. 将 `mineEntry()` 通用逻辑上提到 `BaseAnkiRepository`
3. Cloze 字段改为参数化工厂

---

### HBK-AUDIT-010 — 偏好系统类型不安全的字符串序列化

**Severity**: MEDIUM
**Status**: low-risk — 2026-05-22 验证：当前所有偏好值不存在 string/int/bool 碰撞。架构上脆弱（启发式类型猜测），但实际生产安全。需在添加新偏好类型时注意。
**文件**: `hibiki/lib/src/media/media_source.dart:110-137`, `packages/hibiki_core/lib/src/database/database.dart:246-253`

**根因**: 所有偏好值通过 `value.toString()` 存储，读取时通过启发式猜测恢复类型：

```dart
if (raw == 'true') -> bool
else if (int.tryParse(raw) != null) -> int
else if (double.tryParse(raw) != null) -> double
else -> String
```

**问题场景**:
- 字符串值 `"123"` 被反序列化为 `int 123`
- 字符串值 `"true"` 被反序列化为 `bool true`
- `double` 值 `1.0` 经 `toString()` 后变为 `"1.0"`，读回是 `double`，但 `1` 变为 `int`

**影响**: 类型漂移导致 `getPreference<T>` 在运行时类型检查失败，静默返回 `defaultValue`，用户设置丢失但不报错。

**修复建议**: 存储时附带类型标记，如 `"b:true"`, `"i:123"`, `"d:1.0"`, `"s:123"` 或使用 JSON。

---

### HBK-AUDIT-011 — CI/CD 缺失关键环节

**Severity**: MEDIUM
**Status**: open
**文件**: `.github/workflows/main.yml`

**现状**:
- `flutter analyze` (ok)
- `flutter test`（106 个单元测试文件 / ~8,300 行）(ok)
- 只构建 **debug** APK，不构建 release (missing)
- 无代码覆盖率报告 (missing)
- 无集成测试（4 个集成测试文件未在 CI 运行）(missing)
- 无 release signing 验证 (missing)
- 无 dependency audit / vulnerability scan (missing)

**影响**: release-only 的 bug（如 tree-shaking 移除被反射引用的代码、ProGuard 问题）在 CI 不会被捕获。

**修复建议**: 添加 `flutter build apk --release`（需要 CI 上配置签名密钥），添加 `flutter test --coverage`，添加 `dart pub outdated` 检查。

---

### HBK-AUDIT-012 — 数据库降级策略是全删重建

**Severity**: MEDIUM
**Status**: fixed — 2026-05-21 在 DROP ALL 前添加 `hibiki.db.bak.$from` 文件备份。`_dbDirectory` 存储为实例变量。
**文件**: `packages/hibiki_core/lib/src/database/database.dart:73-80`

```dart
if (from > to) {
  for (final table in allTables) {
    await customStatement(
      'DROP TABLE IF EXISTS "${table.actualTableName}"',
    );
  }
  await m.createAll();
  return;
}
```

**根因**: schema 版本降级时（如用户安装旧版本 APK），直接 DROP ALL TABLES 重建。

**影响**: 用户回退版本后 **所有数据丢失** — 书架、阅读位置、字典历史、偏好全没了。没有警告，没有备份。

**修复建议**: 降级时至少先备份 `hibiki.db` 为 `hibiki.db.bak.{version}`，或拒绝降级并提示用户。

---

### HBK-AUDIT-020 — CreatorModel 无 dispose()（内存泄漏）

**Severity**: CRITICAL
**Status**: fixed — 2026-05-21 添加 `dispose()` 方法，释放 ScrollController + 所有 TextEditingController + 所有 ValueNotifier。
**文件**: `hibiki/lib/src/models/creator_model.dart:27-42`

**根因**: `CreatorModel` 继承 `ChangeNotifier` 但**没有实现 `dispose()` 方法**。

实例内持有：
- ~20 个 `TextEditingController`（每个 Field 一个）
- ~20 个 `ValueNotifier<bool>`（锁定状态）
- 1 个 `ScrollController`

这些控制器在 `CreatorModel` 被 Riverpod `ChangeNotifierProvider` 销毁时不会被清理。

**影响**: 每次 Provider 重建都泄漏 ~40 个 Flutter 控制器对象。虽然 Provider 不频繁重建，但这是确定性的内存泄漏。

**修复建议**:
```dart
@override
void dispose() {
  scrollController.dispose();
  for (final c in _controllersByField.values) c.dispose();
  for (final n in _lockNotifiersByField.values) n.dispose();
  super.dispose();
}
```

---

### HBK-AUDIT-021 — 数据库缺少关键查询索引

**Severity**: MEDIUM
**Status**: fixed — 2026-05-21 在 beforeOpen 中添加 4 个索引：media_items(media_type_identifier)、media_items(media_source_identifier)、audio_cues(book_uid)、search_history_items(history_key)。
**文件**: `packages/hibiki_core/lib/src/database/database.dart`

**现状**: 只有 4 个自定义索引（3 个 profile 相关 + 1 个 bookmarks）。

**缺失索引**:
- `media_items.media_type_identifier` — `getMediaItemsByType()` 全表扫描
- `media_items.media_source_identifier` — `getMediaItemsBySource()` 全表扫描
- `audio_cues.book_uid` — cue 查询全表扫描
- `search_history_items.history_key` — 搜索历史查询全表扫描

**影响**: 数据量少时不明显，但 media_items 和 audio_cues 随使用增长，查询性能会线性退化。

---

### HBK-AUDIT-022 — 5 层偏好缓存，无失效机制

**Severity**: MEDIUM
**Status**: fixed — 2026-05-22 `AppModel.refreshPrefCache()` 现在遍历所有已注册 `mediaSources` 调用 `refreshPreferencesFromDb()`。`profile_view_model.dart` 的 `onApplied` 不再硬编码 Reader 专属刷新。新增 MediaSource 会自动参与 profile 切换刷新。
**文件**: `app_model.dart:216`, `media_source.dart:92`, `database.dart:234`

**现状**: 偏好数据存在 5 个独立存储/缓存层：

| 层 | 位置 | 同步机制 |
|----|------|----------|
| 1. Drift `preferences` 表 | `database.dart` | 地面真相 |
| 2. AppModel `_prefCache` | `app_model.dart:216` | 启动加载一次，`_setPref` 同步更新 |
| 3. MediaSource `_preferences` | `media_source.dart:92` | 每个 source 独立缓存，初始化时加载 |
| 4. Profile `profile_settings` 表 | `database.dart` | 独立表，不走 `_prefCache` |
| 5. SharedPreferences | `ttu_migration.dart` | 仅迁移用 |

**问题**: `_setPref()` 更新层 1 和层 2，但不触发层 3 的 `MediaSource._preferences` 更新。Profile 切换需要手动调用 `refreshPreferencesFromDb()`，如果遗漏，source 读到旧偏好。

---

### HBK-AUDIT-023 — 数据库查询缺少关键事务包裹

**Severity**: MEDIUM
**Status**: fixed — 2026-05-21 `deleteEpubBook` (4 DELETEs) 和 `deleteAudiobookByBookUid` (2 DELETEs) 包裹在 `transaction()` 中。
**文件**: `packages/hibiki_core/lib/src/database/database.dart`

**问题**: `deleteEpubBook` 执行 3 个 DELETE 操作但无显式事务：

```dart
await _database.deleteMediaItemByUniqueKey(item.uniqueKey);
await _database.upsertMediaItem(_mediaItemToCompanion(item));
await _database.trimMediaHistory(...);
```

如果中间步骤失败，数据库处于不一致状态。迁移 v10/v12 的 orphan cleanup 同样未包裹在事务中。

---

### HBK-AUDIT-025 — 阅读器 _initBook() fire-and-forget + 异步间隙缺 mounted 检查

**Severity**: CRITICAL
**Status**: fixed — 2026-05-21 在 `_initBook()` 的 8 个 await 点后添加 `if (!mounted) return;` 守卫。
**文件**: `hibiki/lib/src/pages/implementations/reader_hoshi_page.dart:155, 220-294`

**根因**: `_initBook()` 在 `initState()` 中被调用但不 await。该方法内部有 10+ 个 `await` 点（`_resolveAndApplyProfile`、`EpubStorage` 操作、`_resolveAudioSlot` 等），其间只在最末尾（行 296）做了 `if (mounted)` 检查。

```dart
@override
void initState() {
  super.initState();
  _initBook();  // <- fire-and-forget, 无 await
}

Future<void> _initBook() async {
  // 10+ await 操作...
  // 行 220-294: 大量状态修改，无 mounted 检查
  if (mounted) { setState(() {}); }  // <- 仅最后检查
}
```

**影响**: 如果用户在阅读器初始化过程中快速返回（dispose 被调用），中间的 `await` 恢复后会修改已释放的 widget 状态 -> `setState() called after dispose()` 崩溃。

**修复建议**: 在每个 `await` 之后添加 `if (!mounted) return;` 守卫，或将整个初始化逻辑提取到非 Widget 的 Controller 中。

---

### HBK-AUDIT-024 — 911 个 null assertion (`!`) 分布全代码

**Severity**: LOW
**Status**: open
**文件**: 全代码库

**统计**:
- 911 个 `!` null assertion
- 573 个 `as` 类型转换
- 66 个文件使用 `dynamic` 关键字

**热点**: `reader_hoshi_page.dart` 和 `audiobook_controller.dart` 中 `!` 密度最高。`ttu_migration.dart` 中 `as` 转换最密集（33 处，遗留 JSON 处理，可接受）。

**影响**: null assertion 失败会导致 `TypeError` 崩溃，且错误信息只显示 `Null check operator used on a null value`，无法定位是哪个变量。但大部分使用场景有逻辑保证非 null，属于 Dart 类型系统的使用习惯。

---

### HBK-AUDIT-013 — `jidoujisho` 遗留命名与 `hibiki` 混杂

**Severity**: LOW
**Status**: open
**文件**: 全代码库

**现状**: UI 组件层使用 `Jidoujisho*` 前缀（如 `JidoujishoBottomSheet`、`JidoujishoDropdown`、`JidoujishoSelectableText` 等 8+ 个文件），数据模型使用 `JidoujishoTextSelection`，而应用层使用 `Hibiki*`/`Hoshi*` 前缀。

**影响**: 新贡献者困惑，两个命名空间的语义边界不清晰。不影响功能，但影响代码考古效率。

**修复建议**: 低优先级。在下一次涉及这些组件的重构时统一命名。

---

### HBK-AUDIT-014 — EPUB 导入内存峰值

**Severity**: MEDIUM
**Status**: fixed — 2026-05-22 新增 `EpubImporter.importFromPath()` 和 `EpubParser.parseSyncFromPath()`，文件在 isolate 内读取，主 isolate 不再持有 ZIP 字节数组。三个 `book_import_dialog.dart` 调用方已迁移到 path-based API（TextToEpub 生成的内存 bytes 仍走旧 API）。
**文件**: `hibiki/lib/src/epub/epub_parser.dart:98-121`, `epub_importer.dart:138`

**根因**: `readAsBytes()` 将整个 EPUB 加载到内存，然后传给 compute isolate：

```dart
final Uint8List bytes = await file.readAsBytes();  // 全量读取
return import(db: db, bytes: bytes, ...);           // 传给 isolate
```

**影响**: 500MB EPUB 导入时 RAM 峰值 500MB+。中端手机 RAM 通常 4-6GB，系统 + Flutter 引擎已占 2-3GB，可触发 OOM killer。

**修复建议**: 使用文件路径而非字节数组传给 isolate，在 isolate 内流式处理。

---

### HBK-AUDIT-015 — 错误日志系统限制

**Severity**: LOW
**Status**: fixed — 2026-05-22 `_appendToFile()` 从 `writeAsStringSync` 改为 `writeAsString` 异步写入，不再阻塞主线程。`init()` 和 `clear()` 的同步 I/O 保留（分别只在启动和用户操作时调用一次）。
**文件**: `hibiki/lib/src/utils/misc/error_log_service.dart`

**现状**:
- 有集中式错误日志（`ErrorLogService.instance.log()`）(ok)
- 内存限制 200 条，文件限制 512KB (ok)
- 纯文本格式，无结构化字段（无 device info、无 app version、无 user action context）(missing)
- 无远程上报（无 Crashlytics/Sentry）(missing)
- `_appendToFile` 使用 `writeAsStringSync` — 主线程同步 I/O (issue)
- 4 处 `catch (_) {}` — 日志系统本身的错误被吞噬 (issue)

**影响**: 生产环境用户遇到崩溃时，开发者只能靠用户手动导出日志。日志写入如果发生在关键路径（如阅读器翻页），同步 I/O 可能造成短暂卡顿。

---

### HBK-AUDIT-016 — 有声书字幕 cue 数量无上限

**Severity**: LOW
**Status**: fixed — 2026-05-22 在 `_parseCues()` 统一出口添加 `_maxCuesPerFile = 50000` 上限，超出时截断并 debugPrint 警告。同时重构 `_parseCues()` 消除 6 分支重复 return 模式。
**文件**: `hibiki/lib/src/media/audiobook/audiobook_import_dialog.dart:570`

**根因**: 解析字幕文件后 `cues.length` 无校验。

**影响**: 损坏的字幕文件可能产生 100K+ cue 条目，全部写入 SQLite `audio_cues` 表，导致后续查询变慢。

---

### HBK-AUDIT-017 — 静态可变字典样式缓存无驱逐

**Severity**: LOW
**Status**: false-positive — 2026-05-22 验证：`_stylesCache` 由字典数量约束（典型 5-20，极端 100），每条 1-10KB，总量 < 1MB。`disposeInstance()` 时清空。不需要 LRU 驱逐。
**文件**: `packages/hibiki_dictionary/lib/src/engine/hoshidicts.dart:185`

**根因**: `_stylesCache` 是 static Map，随字典数量线性增长，无 LRU 驱逐。

**影响**: 导入 100+ 字典时（极端场景），缓存可能占用数百 MB。正常使用场景（5-20 字典）影响可忽略。

---

### HBK-AUDIT-018 — 测试覆盖分析

**Status**: open

**现状**:
- 106 个单元测试文件 / ~8,300 行 — 数据库层覆盖**良好**（migration、CRUD、并发写入、外键、profile 等全有）
- 4 个集成测试文件 — 存在但未在 CI 运行
- **无** AppModel 单元测试（4,045 行核心逻辑零测试）(missing)
- **无** 阅读器状态机测试（3,849 行复杂逻辑零测试）(missing)
- **无** 字典搜索/导入集成测试 (missing)
- **无** Creator/Anki 导出集成测试 (missing)
- **无** WebView JS 交互测试 (missing)

**风险**: 数据库层是唯一有信心的区域。阅读器、AppModel、字典系统的任何重构都是在没有安全网的情况下走钢丝。

---

### HBK-AUDIT-019 — 依赖风险

**Status**: open
**文件**: `hibiki/pubspec.yaml`

| 风险项 | 详情 |
|--------|------|
| 6 个 git 依赖 | `blurrycontainer`, `material_floating_search_bar`, `receive_intent`, `ruby_text`, `spaces` — 固定 commit hash，但上游项目均为个人 fork，无维护保证 |
| 5 个 dependency_overrides | `ffi`, `freezed_annotation`, `gap`, `logging`, `wakelock_plus_platform_interface` — 版本冲突通过 override 压制而非解决 |
| `flutter_html: ^3.0.0-beta.2` | 使用 beta 版依赖 |
| `dart_mappable: ^4.0.0-dev.1` | 使用 dev 版依赖 |
| 2 个本地 package override | `file_picker`, `flutter_inappwebview_windows` — 意味着上游版本有 bug，维护了本地 fork |

**影响**: 5 个 override 意味着 `pub upgrade` 无法正常工作，依赖更新需要手动逐个验证。beta/dev 依赖在 Flutter 升级时可能率先破坏。

---

## 高风险问题列表（按优先级排序）

| 优先级 | 编号 | 问题 | 影响 |
|--------|------|------|------|
| ~~P0~~ | HBK-AUDIT-002 | ~~阅读器位置保存竞态~~ | not-reproducible |
| ~~P0~~ | HBK-AUDIT-003 | ~~WebView controller 生命周期竞态~~ | **fixed** |
| ~~P0~~ | HBK-AUDIT-012 | ~~数据库降级全删重建~~ | **fixed** |
| ~~P0~~ | HBK-AUDIT-020 | ~~CreatorModel 无 dispose()~~ | **fixed** |
| ~~P0~~ | HBK-AUDIT-025 | ~~_initBook() 异步间隙缺 mounted 检查~~ | **fixed** |
| P1 | HBK-AUDIT-001 | AppModel 上帝对象 | 性能/可维护性/并发安全 |
| ~~P1~~ | HBK-AUDIT-005 | ~~字典 ZIP 解压无内存限制~~ | **fixed** (Dart fallback) |
| ~~P1~~ | HBK-AUDIT-004 | ~~JS 模板字符串转义不完整~~ | **fixed** |
| ~~P2~~ | HBK-AUDIT-007 | ~~阅读器多标志状态机~~ | **fixed** (generation check in _onChapterLoadComplete) |
| ~~P2~~ | HBK-AUDIT-008 | ~~Stream/Timer 泄漏风险~~ | **false-positive** (subscriptions properly cancelled) |
| P2 | HBK-AUDIT-010 | 偏好类型不安全序列化 | 架构脆弱但当前值安全 |
| P2 | HBK-AUDIT-009 | Creator/Anki 代码重复 | 维护成本翻倍 |
| P2 | HBK-AUDIT-011 | CI/CD 缺失 release build | 生产 bug 逃逸 |
| ~~P2~~ | HBK-AUDIT-014 | ~~EPUB 导入内存峰值~~ | **fixed** (path-based isolate parsing) |
| ~~P2~~ | HBK-AUDIT-021 | ~~数据库缺少关键查询索引~~ | **fixed** |
| ~~P2~~ | HBK-AUDIT-022 | ~~5 层偏好缓存无失效机制~~ | **fixed** (refreshPrefCache refreshes all sources) |
| ~~P2~~ | HBK-AUDIT-023 | ~~关键操作缺少事务包裹~~ | **fixed** |
| P3 | HBK-AUDIT-006 | C++ 导入器无资源上限 | 恶意输入 OOM |
| ~~P3~~ | HBK-AUDIT-016 | ~~字幕 cue 无上限~~ | **fixed** (50K cap + unified parse path) |
| ~~P3~~ | HBK-AUDIT-015 | ~~错误日志同步 I/O~~ | **fixed** (async writeAsString) |
| ~~P3~~ | HBK-AUDIT-017 | ~~字典样式缓存无驱逐~~ | **false-positive** (bounded by dictionary count) |
| P3 | HBK-AUDIT-024 | 911 个 null assertion | 崩溃时难定位 |
| P3 | HBK-AUDIT-013 | 命名不一致 | 可读性 |
| P3 | HBK-AUDIT-019 | 依赖风险 | 升级困难 |
| — | HBK-AUDIT-018 | 测试覆盖缺口 | 重构无安全网 |

---

## 中长期架构风险

### 1. AppModel 拆分成本指数增长
AppModel 每增加一个功能就多一对 getter/setter + notifyListeners。当前 54 次 notify 意味着 UI 已经被过度重建。6 个月后如果达到 80+ notify，性能问题将从「偶尔卡」变成「持续卡」。**拆分窗口正在关闭** — 现在拆成本约 1 周，6 个月后约 3 周。

### 2. 阅读器 3,849 行单文件不可持续
`reader_hoshi_page.dart` 集成了 WebView 管理、状态机、音频桥接、位置恢复、样式注入、资源拦截、手势处理。任何单一功能的修改都需要理解整个 3,849 行的上下文。**已进入「碰一处坏三处」的区间**。

### 3. 多平台扩展的隐性障碍
worktree 中已有 `phase2-3-multiplatform` 分支。但当前代码中 ~20 处 `Platform.isAndroid` / `Platform.isIOS` 分支散布在 AppModel、main.dart、media_source.dart 中。packages 层（hibiki_core, hibiki_dictionary 等）虽已分离，但 AppModel 仍直接引用平台特定 API（ExternalPath、DeviceInfoPlugin、WakelockPlus）。多平台需要先解决 AppModel 拆分。

### 4. WebView <-> Dart 状态同步脆弱
当前依赖 JS handler 回调 + generation number 匹配来同步 WebView 和 Dart 状态。没有形式化的消息协议或 ACK 机制。网络延迟（本地 WebView 不涉及网络，但 JS 执行延迟）或 GC 暂停都可能导致 generation 不匹配。

---

## 技术债地图

```
hibiki/
  lib/
    src/models/
      app_model.dart ............ [CRITICAL] 4,045 行上帝对象 [P1: 拆分]
      creator_model.dart ........ [CRITICAL] 无 dispose() [P0: 修复]
    src/pages/implementations/
      reader_hoshi_page.dart .... [CRITICAL] 3,849 行: 竞态 + 异步间隙 [P0+P1]
    src/creator/fields/
      audio_field.dart .......... [MEDIUM] 与 audio_sentence_field 95% 重复
      audio_sentence_field.dart . [MEDIUM] [P2: 提取基类]
    src/media/media_source.dart . [MEDIUM] 偏好序列化类型不安全 [P2]
    src/utils/misc/
      error_log_service.dart .... [LOW] 同步 I/O + 吞异常 [P3]
  pubspec.yaml .................. [MEDIUM] 6 git 依赖 + 5 override [P3]

packages/
  hibiki_core/src/database/
    database.dart ............... [CRITICAL] 降级全删 [P0] + 缺索引 [P2]
  hibiki_dictionary/src/
    formats/*.dart .............. [MEDIUM] ZIP 解压无内存限制 [P1]
    engine/hoshidicts.dart ...... [LOW] 样式缓存无驱逐 [P3]
  hibiki_anki/src/
    ankiconnect/ ................ [MEDIUM] mineEntry 与 ankidroid 重复
    ankidroid/ .................. [MEDIUM] [P2: 上提到 base]
```

---

## 可维护性评分

| 维度 | 评分 | 说明 |
|------|------|------|
| 代码组织 | 5/10 | package 分离思路正确，但 AppModel 上帝对象严重拖后腿 |
| 类型安全 | 7/10 | Dart 强类型体系使用较好，`dynamic` 用量低（10 处），但偏好序列化存在类型漂移 |
| 错误处理 | 4/10 | 有集中式日志，但 15 处 `catch (_) {}` + 6 处 `.catchError((_) {})` 是定时炸弹 |
| 资源管理 | 5/10 | 大部分 dispose 正确，但阅读器和音频桥接存在泄漏路径 |
| 测试覆盖 | 4/10 | 数据库层优秀，但核心业务逻辑（AppModel、阅读器、Creator）零覆盖 |
| 依赖健康 | 4/10 | 6 个 git fork + 5 个 override + 2 个 beta/dev 依赖 |
| CI/CD | 3/10 | 只有 analyze + test + debug build，无 release 验证/覆盖率/安全扫描 |
| 文档 | 6/10 | CLAUDE.md + AGENTS.md 规则详尽，代码内注释适量 |
| 性能意识 | 6/10 | FFI 字典查询、WebView 预热等做得好，但 AppModel 全树 rebuild 和内存峰值是盲点 |
| 安全 | 5/10 | EPUB 路径遍历防护优秀，但 JS 注入、资源限制、降级数据丢失存在缺口 |

**综合可维护性: 4.9/10** — 「单人维护期的项目，有良好的基础设施意识，但核心模块（AppModel、阅读器）的复杂度已经超过了安全维护的阈值。」

---

## 架构健康度评价

**架构成熟度: Early Growth (成长初期)**

**优势**:
- Package 分离方向正确（hibiki_core/dictionary/anki/audio/platform）
- Drift SQLite 使用规范（WAL、外键、索引、迁移版本号）
- 数据库测试覆盖率高（migration、concurrent、foreign key 全有）
- FFI 内存管理总体规范（finally 释放、isolate 隔离）
- EPUB 路径遍历防护到位

**劣势**:
- AppModel 上帝对象阻碍了 package 分离的价值发挥
- 阅读器单文件 3,849 行，状态机无形式化
- 异步错误吞噬模式广泛分布
- CI 只做最低限度验证
- 核心逻辑零测试覆盖

**正面发现（异步/资源审查确认）**:
- 所有 `StreamSubscription` 在 `dispose()` 中正确取消
- 所有 `Timer` / `Timer.periodic` 在 `dispose()` 中正确取消
- `FocusNode`、`ScrollController`、`TextEditingController` 释放总体正确
- `addListener` / `removeListener` 配对正确
- `Completer` 使用正确，有 `isCompleted` 守卫防止双重完成
- `runZonedGuarded` + `FlutterError.onError` 全局错误边界完善
- EPUB 路径遍历防护（`p.isWithin()` 检查）优秀
- FFI 内存管理使用 `try-finally` + `calloc.free()` 规范
- AudiobookController dispose 完整（3 个 stream subscription + player）

**结论**: 项目有良好的技术直觉（选择 Drift 而非 SharedPreferences、用 Isolate 做重计算、用 C++ FFI 做字典查询），但**执行纪律不一致** — 数据库层和资源释放的严谨程度远高于 AppModel 和阅读器状态管理层。这是典型的「AI 辅助开发 + 单人维护」模式：基础设施层（被仔细审查过的）质量高，业务逻辑层（快速迭代的）质量低。

---

## 推荐重构顺序

### Phase 0: 紧急修复（2-3 天）
1. **HBK-AUDIT-002**: 修复位置保存竞态（闭包捕获局部变量）
2. **HBK-AUDIT-003**: WebView controller 调用包裹 try-catch
3. **HBK-AUDIT-012**: 数据库降级前备份
4. **HBK-AUDIT-020**: CreatorModel 添加 dispose()（5 行修复）
5. **HBK-AUDIT-025**: _initBook() 异步间隙添加 mounted 守卫

### Phase 1: 安全加固（3-5 天）
4. **HBK-AUDIT-004**: JS 注入改用 JSON 编码
5. **HBK-AUDIT-005**: ZIP 解压添加大小检查
6. **HBK-AUDIT-011**: CI 添加 release build + coverage

### Phase 2: 结构性还债（1-2 周）
7. **HBK-AUDIT-001**: AppModel 拆分（ThemeNotifier、PreferencesRepo、DictionaryRepo）
8. **HBK-AUDIT-009**: Creator 字段提取基类，Anki mineEntry 上提
9. **HBK-AUDIT-010**: 偏好序列化添加类型标记

### Phase 3: 阅读器治理（2-3 周）
10. **HBK-AUDIT-007**: 状态机形式化（enum + 转换函数）
11. 拆分 `reader_hoshi_page.dart` 为：
    - `ReaderHoshiPage` (生命周期/路由)
    - `ReaderWebViewController` (WebView 管理)
    - `ReaderPositionManager` (位置保存/恢复)
    - `ReaderAudioBridge` (有声书集成)
    - `ReaderStyleInjector` (CSS/样式管理)

---

## 如果继续当前模式，未来 3-6 个月最可能出现的问题

1. **AppModel 性能坍塌** (2-3 个月): 随着功能增加，`notifyListeners()` 频率上升，UI 重建开销从可忽略变为可感知。用户会报告「切换偏好后全部卡一下」。

2. **阅读器修不动** (1-2 个月): `reader_hoshi_page.dart` 每次修 bug 都有 30%+ 概率引入新 bug，因为 3,849 行代码的状态交互路径超出人脑缓存。某次「修复翻页」会导致「位置恢复坏了」。

3. **大字典导入 OOM** (已可复现): 用户导入 1GB+ 字典 ZIP 时 OOM 崩溃。当前只在小字典上测试通过。

4. **依赖锁死** (3-6 个月): Flutter 3.41.6 -> 下一个大版本升级时，6 个 git fork + 5 个 override 会导致至少 2-3 天的依赖解冲突工作。`dart_mappable: ^4.0.0-dev.1` 进入 stable 后 API 可能变化。

5. **多平台计划受阻** (正在发生): Windows 适配已在 worktree 中进行，但 AppModel 对 Android API 的硬依赖意味着每个偏好都需要添加平台分支，工作量线性增长。

6. **回归失控** (持续): 无阅读器/Creator 自动化测试意味着每次发版都是手动回归。随着功能增加，手动测试覆盖率持续下降。

---

## Next Scope

下一轮审查将聚焦：
1. `reader_hoshi_page.dart` 逐函数审查（WebView 资源拦截、onLoadStop 完整路径）
2. Profile 系统（`profile_repository.dart`、`profile_view_model.dart`）— 多 Profile 切换的状态一致性
3. 有声书播放栏（`audiobook_play_bar.dart` 2,151 行）— 另一个大文件热点
4. 字典搜索性能路径（HoshiDicts FFI -> UI 渲染完整链路）

---

## 附录 A: 异常吞噬清单

| 文件 | 行号 | 模式 | 风险 |
|------|------|------|------|
| `app_model.dart` | 2748 | `catch (_) {}` | 未知操作静默失败 |
| `app_model.dart` | 2796 | `catch (_) {}` | 未知操作静默失败 |
| `app_model.dart` | 3749 | `catch (_) {}` | 未知操作静默失败 |
| `reader_hoshi_page.dart` | 277 | `catch (_) {}` | WebView 初始化失败被吞 |
| `reader_hoshi_page.dart` | 811 | `catch (_) {}` | 阅读器操作失败被吞 |
| `reader_hoshi_page.dart` | 1720 | `catch (_) {}` | 样式应用失败被吞 |
| `reader_hoshi_page.dart` | 2418 | `catch (_) {}` | 位置相关操作失败被吞 |
| `error_log_service.dart` | 58, 78, 114 | `catch (_) {}` | 日志系统自身错误被吞 |
| `audiobook_play_bar.dart` | 1214 | `catch (_) {}` | 播放控制失败被吞 |
| `highlight_bridge.dart` | 387 | `catch (_) {}` | 高亮操作失败被吞 |
| `hoshi_settings_page.dart` | 239 | `catch (_) {}` | 设置操作失败被吞 |
| `update_checker.dart` | 52, 55 | `catch (_) {}` | 更新检查失败被吞 |
| `profile_view_model.dart` | 50 | `.catchError((_) {})` | Profile 快照失败被吞 |
| `app_model.dart` | 1791 | `.catchError((_) {})` | splash 颜色设置失败被吞 |
| `audio_field.dart` | 118, 370 | `.catchError((Object _) {})` | 音频操作失败被吞 |
| `audio_sentence_field.dart` | 120, 372 | `.catchError((Object _) {})` | 音频操作失败被吞 |
