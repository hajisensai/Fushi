## BUG-906 · 偏好版本并发自增丢失 + 查询热路径缺索引
- **报告**：2026-07-19（审计批次）
- **真实性**：✅ 真 bug（两处均沿真实代码路径定位）。根因链见下。
- **[x] ① 已修复** — 见下方修复（A/B）
- **[x] ② 已加自动化测试** — `packages/hibiki_core/test/bug906_prefs_version_and_indexes_test.dart`
- **备注**：两处同在 `packages/hibiki_core/lib/src/database/database.dart`，合并一个任务修复。B 需 bump schemaVersion 45→46（存量库补索引，见下）。真机复测待做。

### 缺陷 A：prefs_version 并发自增丢失

#### 现象
分离的 :popup 进程读到过期偏好缓存：主进程改了偏好但 `prefs_version` 计数器漏增，:popup 据此判定“无变化”不重载缓存。

#### 根因
`HibikiDatabase.setPref`（`packages/hibiki_core/lib/src/database/database.dart:1716`）把「写业务 pref」与「bump 版本号」拆成两个独立 `await`，无事务包裹；`_bumpPrefsVersion`（`:1763`，加行后）内部「读 current → 写 current+1」是非原子读改写。两个并发 `setPref` 在 await 点交错：都读到版本 N，都写 N+1 → 少增一次。计数器不再单调对齐真实写入次数。

对比：同文件 `compareAndSetPref`（`:1737`）已用 `transaction()` 把「比较写 + bump」整体包裹，是正确的原子范式；`setPref` 独漏。

#### 修复
- `setPref`：把「insert 业务 pref + bump」整体包进 `transaction()`。drift 在单写连接上串行化事务，第二个 `setPref` 的事务等第一个提交后才跑，读改写因此原子——不丢增量，且跨进程读者绝不会看到「新值 + 旧版本号」的中间态。
- `_bumpPrefsVersion`：读改写保持不变，但补文档说明它**必须在外层事务上下文中调用**（其仅有的两个调用者 `setPref`/`compareAndSetPref` 现均提供事务），由事务锁保证原子；禁止新增裸调用者。

### 缺陷 B：查询热路径缺索引

#### 现象
有声书章节加载、按标签统计书数、按来源查收藏词等热路径走全表扫描。

#### 根因
`_ensureIndexes`（`packages/hibiki_core/lib/src/database/database.dart:987`）只建了单列索引，缺：
- `audio_cues`：`getCuesForChapter`（`:2642` 主 checkout 对应逻辑）按 `book_key + chapter_href` 过滤并按 `sentence_index` 排序、`findCue` 按 `book_key + chapter_href + sentence_index` 过滤——单列 `idx_audio_cues_book_key` 覆盖不了 `chapter_href` 过滤与 `sentence_index` 排序。
- 三张 tag 映射表 `book_tag_mappings` / `srt_book_tag_mappings` / `video_book_tag_mappings`：`countBooksForTag` 三处 `WHERE tag_id IN (...) GROUP BY <owner> HAVING COUNT(DISTINCT tag_id)`，只有 owner 侧（book_key 等）索引，`tag_id` 过滤全表扫。
- `favorite_words`：`getFavoritesBySource` 按 `source_type` 过滤（`'book' | 'video'`），无索引。

#### 修复
在 `_ensureIndexes()` 补建（均 `CREATE INDEX IF NOT EXISTS`，`_tableExists` 守卫）：
- `idx_audio_cues_book_chapter_sentence ON audio_cues (book_key, chapter_href, sentence_index)`——等值过滤列（book_key、chapter_href）在前，`sentence_index` 在后既做 `findCue` 的等值列又做 `getCuesForChapter` 的排序列；leading `book_key` 仍服务只按书查的路径。
- `idx_book_tag_mappings_tag_id` / `idx_srt_book_tag_mappings_tag_id` / `idx_video_book_tag_mappings_tag_id`，各 `(tag_id)`。
- `idx_favorite_words_source_type ON favorite_words (source_type)`。

**存量库补建**：新库经 `onCreate`（createAll + `_ensureIndexes`）自动得到；存量库只能经一次性 onUpgrade 步补上。因此 bump `schemaVersion` 45→46，并加 `if (from < 46) await _ensureIndexes();`（`_ensureIndexes` 幂等，重跑对既有索引是 no-op，只建新的）。这正是本仓库既定范式：HBK-AUDIT-094（commit `6636cc3d5`）明确「把索引从 beforeOpen（每次启动跑）移到 onCreate + 版本化 onUpgrade 步 + bump schemaVersion」，并**刻意移除**了 beforeOpen-每次启动路径。故不用重新往 beforeOpen 塞。降级保护已处理 `from > to`，老 app 打开 v46 库会干净抛 `HibikiDatabaseDowngradeException`。

> ⚠️ 并发提示：其它 draft 分支（PR#224/#234 等）也各自声明过 v46/v47。若与本改动同期合并，schemaVersion 需由 integration owner 统一重排（与 BUG 号撞号同理）。
