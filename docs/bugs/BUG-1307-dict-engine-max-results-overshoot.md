## BUG-1307 · 查词冷路径白解压 20 倍：引擎结果上限硬编码 200 而 Dart 侧只用 maximumTerms
- **报告**：2026-08-01（用户：查词 4-5 秒 / 有时像卡死）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/models/app_model.dart:3919`（旧行号）把
  `maxResults: maximumDictionarySearchResults`（硬编码 200，`:1248`）传给引擎，而
  `native/hoshidicts/hoshidicts_src/lookup.cpp:137-147` 是
  `partial_sort` → `resize(max_results)` → **逐条 `materialize()`**（zstd 解压
  glossary）。Dart 侧 `buildResultFromLookup` / `buildPopupJsonFromLookup`
  （`packages/hibiki_dictionary/lib/src/language/language.dart:439` / `:469`）只消费
  `maximumTerms`（用户真实值 10）条 glossary。⇒ **解压条数是消费条数的 20 倍**。
  每条 glossary 落在 `blobs.bin`（本机 26 本词典合计 1193MB）的一个随机偏移上，
  `memory.cpp:30-78` 是纯按需分页 mmap（无预取），冷页实测 180-234us/条（NVMe）。
  这是「装的词典越多越慢、只有某些用户的电脑慢」的量级来源。
  连带发现：`_ffiLookupCache` 只按 `searchTerm` 做键（`dictionary_repository.dart:271`），
  在上限恒为常量时安全，一旦上限跟随 `effectiveMaxTerms` 变动就会让 load-more
  命中上一轮的短结果集、`allLoaded` 提前置真 —— 修 ① 时必须同步修键。
- **[x] ① 已修复** — `maxResults` 改传 `effectiveMaxTerms`；删除独立常量
  `maximumDictionarySearchResults`；新增 `buildFfiLookupCacheKey`（键含上限），
  `getCachedFfiLookup` / `cacheFfiLookup` 改收 `cacheKey`。
  输出逐字不变的三条依据（已写进代码注释并被测试锁住）：
  1. `partial_sort` 比较器未动 ⇒ top-N 集合与顺序不变；
  2. `query.cpp` 的 `query_raw` 里 `glossaries.push_back` 无条件执行 ⇒ 每个返回的
     term 至少带一条 glossary，N 个结果必凑够 N 条词头预算；
  3. `bestLength` 取 `matched` 的最大 UTF-16 长度，而所有 `matched` 都是同一查询串的
     前缀（`scan_candidates` 只产前缀）⇒「码点最长」与「UTF-16 最长」是同一个元素，
     必在 `partial_sort` 后排首位、永远落在 top-N 内。
- **[x] ② 已加自动化测试** — `hibiki/test/models/dict_engine_max_results_alignment_test.dart`
  （15 个用例三组：输出不变性 / FFI 缓存键带上限 / app_model 接线守卫）。
  变异实测：改回 `maxResults: 200` → 红；`getCachedFfiLookup(searchTerm)` → 红；
  推翻「每 term ≥1 glossary」前提（fixture 造零 glossary 结果）→ 不变性组红。
- **旁证（降上限是安全的，已在生产里跑了很久）**：Android 独立弹窗进程走另一条引擎
  入口 `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDictActivity.kt:423`，
  `maxResults = prefs.maximumSearchResults`，而该值读的偏好键
  `maximum_dictionary_search_results`（`PopupDbReader.kt:215`）**全仓无人写入**
  （grep 只此一处），故它一直取默认值 **16**。也就是说同一个引擎、同一份词典，
  Android 弹窗进程长期以 16 为上限出结果，主进程却是 200 —— 两条入口本就不一致，
  低上限那条从未被报过结果缺失。
- **备注**：本条只砍「白干的解压条数」，**没有**动 native 侧的按需分页策略
  （`PrefetchVirtualMemory` / `madvise`）——那是跨平台预取改动，需单独评估。
