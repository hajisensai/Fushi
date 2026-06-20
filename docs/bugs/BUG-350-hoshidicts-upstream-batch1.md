## BUG-350 · hoshidicts 上游同步批1（score double / freq 排序 / c++23 兼容）
- **报告**：2026-06-20（用户：qqbotxiaoxiao）
- **真实性**：✅ 真改进（非崩溃 bug，是上游修正直抄）。TODO-621 批1：把 Manhhao/hoshidicts 上游三处零风险修正同步进 Hibiki fork（`native/hoshidicts/`）。逐字节确认 apply 前 Hibiki 仍是上游旧版。
  - ① 上游 `3448d6d` Term::score `int`→`double`：根因 `native/hoshidicts/hoshidicts_src/json/yomitan_parser.hpp:22`（apply 前为 `int score = 0`）。Yomitan term 词条 score 可为小数，旧 `int` 解析非整数 score 会失败。零盘格式风险（`process_term_bank` 写盘不含 score）。Tag::score（同文件 :39）按上游不动，仍 `int`。
  - ② 上游 `4975788` 频率排序用全部 freq 值：根因 `native/hoshidicts/hoshidicts_src/lookup.cpp:24-40`（`get_freq_value_for_dict` 旧版只取 min）+ 调用点 `:111-112`。旧实现同 dict 多个频率值只取最小，排序信息丢失；改为收集全部值 `std::ranges::sort` 后按 `vector<int>` 字典序比较。纯查询期排序，不碰 importer / 写盘。
  - ③ 上游 `1a34a59` c++23 兼容：根因 `native/hoshidicts/hoshidicts_include/hoshidicts/query.hpp:100`（`Dictionary` 含 `unique_ptr<DictionaryData>` pimpl 但无显式特殊成员）+ `native/hoshidicts/hoshidicts_src/query.cpp:83` 后缺定义。c++23 下 Swift/Clang 对含不完整类型 pimpl 的隐式特殊成员推导更严，显式声明移动/析构（拷贝 delete）修编译。5 平台受益。
- **[x] ① 已修复** — 三处直抄上游对应 commit（见上 file:line）；新建 `native/hoshidicts/UPSTREAM.md` 记基线 commit + Hibiki 本地改动清单。提交：见本批 commit（feature/vendoring-621-hoshidicts-upstream）。
- **[x] ② 已加自动化测试** — 复用 578 接 CI Linux 的 ctest：`native/hoshidicts/tests/freq_pitch_import_query_test.cpp` 守 freq 排序；`text_processor` / `kanji` 现有 ctest 不回退。本机无 C++ 编译器（MSVC/NDK），native 改动由 CI Linux ctest + 5 平台 build 验。
- **备注**：FFI 签名未变——`score` / `get_freq_value_for_dict` / `Dictionary` 均为内部符号，`hoshidicts_ffi.cpp` / `hoshidicts_jni.cpp` / Dart binding 未暴露，Dart 侧无需改。BUG 采番遍历全 worktree 取并集（345-349 已占）→ 350。批2（2d4f2a2 NFKC 需 utf8proc）/ 批3（e7dfdea kanji 需 #embed→CMake 改写）/ 918744d（IPA 需 Dart 消费）留 follow-up。
