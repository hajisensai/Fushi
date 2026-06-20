## BUG-348 · 混合词典误判kanji划词查词全失踪(detect_type kanji优先)
- **报告**：2026-06-20（用户：TODO-622）
- **真实性**：✅ 真 bug。根因 `native/hoshidicts/hoshidicts_src/importer.cpp:88-94`（修复前）：`detect_type()` 先查 `kanji_banks` 非空即返 `"kanji"`，无视是否同时含 `term_bank`。混合词典（如 `現代新国語辞典 第七版`，index.json 自述 82620 词条 + 2136 汉字，含 `kanji_bank_1.json` + `term_bank_1~9.json`）被一票否决判 `kanji`。`type=kanji` 到 `app_model.dart` `bucketDictPaths` 一本只进 kanji 桶 → 82620 词条只进 kanji 桶，划词查日语词全查不到，只剩逐字查汉字。blobs.bin 里 term + kanji record 都在（`importer.cpp` 无条件全写），重分类即恢复无需重解析。
- **[x] ① 已修复** — 方案A（native 探测做单一真相源）四步：
  1. `native/hoshidicts/hoshidicts_src/importer.cpp:88-104` `detect_type` 调换 if 顺序：含 `term_bank` → 返 `"term"`（优先）；仅 `kanji_bank` 无 `term_bank` → `"kanji"`（纯 KANJIDIC 仍判 kanji）。
  2. 新 native 导出 `probe_dict_content(dir)→bitmask`（bit0=hasTerm, bit1=hasKanji），实现 `native/hoshidicts/hoshidicts_src/query.cpp:589`（手解 hash.table 桶 → offset-index → record 首字节 type，复用 query_kanji 同套磁盘格式，不撞 ZSTD 因每个 offset 是 record 精确起点）；声明 `query.hpp:72`；FFI 导出 `hoshidicts_ffi.cpp:262`。
  3. `FfiImportResult` 加 `kanji_count`（C `hoshidicts_ffi.cpp:86/211`，Dart `hoshidicts_ffi_bindings.dart:98`，`HoshiImportResult.kanjiCount` `hoshidicts.dart:103`），导入时 `result.kanjiCount>0` → `metadata['hasKanji']='true'`（`dictionary_import_manager.dart:232/354`，metadata 已持久化到 `DictionaryMetadata.metadataJson` 列，**无 schema 迁移**）。
  4. 存量自愈：`_migrateDictionaryTypes`（`app_model.dart:638`）对 type=='kanji' 词典调 `HoshiDicts.probeDictContent`：hasTerm → 回迁 type=term + 补 hasKanji。双桶：`DictPathEntry` 加 `hasKanji`（`app_model.dart:190`），`bucketDictPaths`（`app_model.dart:198`）term 类型 + hasKanji → **也**进 kanji 桶（add_term_dict + add_kanji_dict 都调，混合词典释义 + 汉字卡都查到；query_kanji 有 type+char 双守卫，纯 term 词典 add_kanji_dict 零误命中）。
  - 提交：`<本轮 commit>`
- **[x] ② 已加自动化测试** —
  - native ctest：`native/hoshidicts/tests/kanji_import_query_test.cpp` Case B 加 `r.detected_type=="term"` 断言（detect_type 顺序守卫）；probe 对纯 kanji(A,0x2)/混合(B,0x3)/纯 term(C,0x1) 三类 bitmask 断言（本机无 C++ 编译器，留 CI Linux ctest 验，TODO-578 已接 CI）。
  - Dart 行为：`hibiki/test/models/bucket_dict_paths_test.dart` 加 4 条双桶守卫（混合进两桶 / 纯 term 不进 kanji / 隐藏不进 kanji / 不存在跳过）。
  - Dart 源码扫描：`hibiki/test/models/mixed_dict_reclassify_guard_test.dart`（_migrateDictionaryTypes kanji→term probe 回迁 + 两处 rebuild 读 metadata[hasKanji] + DictPathEntry.hasKanji 字段）。
  - 测试文件：`bucket_dict_paths_test.dart` / `mixed_dict_reclassify_guard_test.dart` / `kanji_import_query_test.cpp`
- **备注**：采番遍历所有 worktree 分支取并集（345/346 被 620/610 占，347 也被占）→ 348。真机待验：导入这本 zip 划词查日语词出释义 + 单字查汉字出汉字卡 + 存量误判词典重启自动迁移（需 FFI lib 重编含 probe 导出，本机 dev .dll/.so 早于本改动）。
