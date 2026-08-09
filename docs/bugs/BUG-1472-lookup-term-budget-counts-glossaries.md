## BUG-1472 · 查词只出一个读音：maximumTerms 按 glossary 行计预算吃掉其它读音
- **报告**：2026-08-09（用户：shishamo）
  - 原话：查「永遠」永远只出 えいえん，没有 とわ / とこしえ。
- **真实性**：✅ 真 bug。**同一个数字被两层当成两种语义用**：
  - 引擎侧当**词头数上限**：`native/fushidicts/fushidicts_src/lookup.cpp` 的
    `partial_sort` + `resize(max_results)`，比较器按频率排序 ⇒ えいえん 必排最前。
  - Dart 侧当**glossary 注释行数预算**：`packages/fushi_dictionary/lib/src/language/language.dart`
    的 `buildResultFromLookup`（修复前 `:446-461`）与 `buildPopupJsonFromLookup`
    （修复前 `:492-498`）都是 `if (entries.length >= maximumTerms) break outer;`，
    计数单位是内层 glossary 循环。
  - 而 `native/fushidicts/fushidicts_src/query.cpp:246` 会把**不同词典**的同一个
    (expression, reading) 合并成 **1 个 TermResult + N 条 glossary**。于是
    「永遠/えいえん」这种高频词头，装了几本词典就带几条注释（实测量级 7~26 条），
    一个人就吃满默认上限 10（`fushi/lib/src/models/preferences_repository.dart:782`），
    **とわ 的循环体一次都没进过**。
  - 仓库其实已经写下过这条事实，只是当时在查别的症状：
    `fushi/lib/src/pages/base_source_page.dart:307` 的注释原文
    「`maximumTerms` 按 glossary 注释**行**计预算（language.dart），一个高频词头的
    注释行就能吃满整个上限 → 只剩 1 个词头」。
  - 已排除的假说（都查过实码）：索引层双 key 正确（`importer.cpp:310-313` expr 与
    reading 各建一个 key）；三层 dedup key 全含 reading（`query.cpp:190`、
    `lookup.cpp:45`、`popup_json.cpp:63`）；deinflector 完全不知道 reading 存在。
    **不是 BUG-1307 引入的回归**，glossary 计数预算早于它存在。
- **[x] ① 已修复** — 预算单位改为 **distinct 词头（表记 + 有效读音）**，两个构造函数
  共用新的 `lookupHeadwordKey()`（沿用 [[BUG-791]] 的空读音归一约定）。
  同时把「有没有被截断」从**反推**改成**显式事实**：`DictionarySearchResult.truncated`
  由构造方写、随 `toJson`/`fromJson`/`withKanjiResults` 传播；四处消费方
  （`base_source_page.dart` ×2、`dictionary_page_mixin.dart` ×2、`home_dictionary_page.dart`）
  的 `allLoaded` 判据从 `entries.length < maximumTerms` 改成 `!result.truncated`。
  必须一起改：预算单位一变，那个长度比较就跨了单位、永久错位（一个词头能带 N 条 entries）。
- **[x] ② 已加自动化测试** — 新建
  `fushi/test/models/lookup_term_budget_counts_headwords_test.dart`（「永遠」三读音 fixture，
  えいえん 带 12 本词典），断言三个读音都在、超限时截断词头数并标 `truncated`、
  单个词头的注释不被腰斩。已做变异实测：改回按行计预算即红。
  - 顺带修正两条把旧错误单位写进断言的既有测试：
    `test/models/dict_engine_max_results_alignment_test.dart` 的
    「N 个结果必凑够 N 条词头预算」改成真的数词头（原断言 `entries.length == 10`
    在 fixture 每词头 2 条注释下其实只断言了 5 个词头 —— 正是本 bug 的本体）；
    `test/pages/dictionary_popup_webview_test.dart` 的 `respects maximumTerms limit`
    原本断言「maximumTerms=2 ⇒ 单个词头只剩 2 条注释」，把丢第三本词典释义写成了契约。
- **备注**：⚠️ 有一个未验证前提 —— 用户词典里 `永遠【とわ】` 这条记录是否真的存在
  （取决于装的 Yomitan 词典版本）。**一分钟判定法**：把设置里的「最大词条数」临时调到
  100 再查「永遠」，出 とわ ⇒ 确认为本根因；仍不出 ⇒ 是词典数据问题不是代码问题。
  本次修复不依赖该前提成立 —— 按行计预算本身就是错的。
