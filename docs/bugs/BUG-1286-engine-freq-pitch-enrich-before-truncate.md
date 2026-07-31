## BUG-1286 · 词典引擎 freq/pitch 在截断前富化：每次查词按词典数线性放大上千倍无用查询

- **报告**：2026-07-31（用户：「词典出来的速度特别特别慢……某些用户电脑上出来要 4-5 秒」，并附词典管理截图：释义词典 **7 本以上**，含 Pixiv / Nico_Pixiv 这类超大词典，另有汉字/词频/音调三类）
- **真实性**：✅ 真 bug。这是「**为什么词典装得多的人特别慢**」的确切答案，也是 BUG-717 当年自己记下「已识别但未做」的那条（`docs/bugs/BUG-717-lookup-latency-half-second.md:15`：「C++ 引擎微优化（freq/pitch 截断后富化、排序键预计算）……留作后续」）。

  - **根因：富化被放在三层笛卡尔积的最内层，而结果在最外层才被截断。**
    `native/hoshidicts/hoshidicts_src/lookup.cpp:49-54` 是三层嵌套：
    ```cpp
    for (search_str : scan_candidates(...))        // 默认 scanLength=16 → 最多 16 个前缀
      for (variant : text_processor::process(...)) // 7 个处理器笛卡尔展开，日文实测 3-8
        for (deinflection : deinflect(variant))    // 递归深度上限 10，日文动词典型 10-40
          query_.query_raw(deinflection.text);
    ```
    → `query_raw` 每次用户查词被调用约 **16 × 5 × 20 ≈ 1600 次**。
    而旧 `query.cpp:261-263` 在 `query_raw` **内部**做富化：
    ```cpp
    auto results = term_map | ... | std::ranges::to<std::vector>();
    query_freq(results);    // for(terms) × for(freq_dicts_) + 每条 JSON 解析
    query_pitch(results);   // for(terms) × for(pitch_dicts_) + 每条 JSON 解析
    ```
    于是**每一次中间调用**都把当次的中间结果拿去查遍所有频率词典和所有音调词典，各自还要跑 `yomitan_parser::parse_frequency` / `parse_pitch` 的 JSON 解析（`query.cpp:390`、`:453`、`:462`）。
    这些结果**几乎全部在 `lookup.cpp` 的 dedup → `partial_sort` → `resize(max_results)` 中被丢弃**。
  - **放大系数**：`1600 次 query_raw × (频率词典本数 + 音调词典本数) × 每条 JSON 解析`。用户装 7+ 本释义 + 若干频率/音调词典时，单次查词的无用富化工作量是有效工作量的**三到四个数量级**。这就是同样的代码在开发机（4 本词典、SSD、page cache 热）测出 40-66ms、在用户机上变成秒级的原因。
  - **注意富化本身没写错**，位置错了：`query_freq` / `query_pitch` 都是 `for (auto& term : terms)` 外层、内部只用 `term.expression` / `term.reading` 查询，**与这个 term 来自哪一次去屈折无关**——所以把它移到去重之后，结果逐字段相同。
- **[x] ① 已修复** — 提交：见本轮 PR
  - `query_raw()` 不再富化（`query.cpp`），成为纯粹的「查词条」；头文件 `hoshidicts_include/hoshidicts/query.hpp` 上写明这个契约。
  - 新增 private 单条富化 `enrich_freq(TermResult&)` / `enrich_pitch(TermResult&)`（`Lookup` 是 `friend`）。公开的 `query_freq(vector&)` / `query_pitch(vector&)` 改为循环调用它们，**对外签名与行为零变化**。
  - `DictionaryQuery::query()`（单表达式入口，非热路径）自己补上 `query_freq` + `query_pitch`，**契约不变**。
  - `Lookup::lookup()` 里富化只做一次，且各自放在正确的位置：
    - **freq 在去重之后、排序之前**——因为排序比较器 `lookup.cpp:111-117` 按频率排名，必须先有数据；
    - **pitch 在 `resize(max_results)` 之后**——比较器不读 pitch，所以只有用户真正拿到的 ≤max_results 条才需要它。
  - 顺带的正确性收益：`filter_by_pos` 现在跑在富化之前，被词性过滤掉的条目不再白富化。
- **[x] ② 已加自动化测试** — 提交：见本轮 PR。测试文件 `native/hoshidicts/tests/lookup_freq_pitch_enrichment_test.cpp`，注册进 ctest。
  - **为什么必须新写**：既有 `freq_pitch_import_query_test.cpp` / `freq_pitch_merge_query_test.cpp` **全部走 `DictionaryQuery::query()`**（5 处调用点无一例外），而本 bug 改的是 `Lookup::lookup()`——app 真正调用的路径。不补这个文件，整套 native 测试会在 `lookup()` 把 freq/pitch 全丢掉的情况下**照样全绿**。
  - 覆盖：`lookup(猫)` 平常形式、`lookup(猫が)`（更长输入 → 真的跑多轮 `query_raw`，正是被抽掉富化的那个循环）、`lookup(猫, max_results=1)`（强制 `resize` 真截断，证明 pitch 富化跑在存活集上），三种情况都断言 frequency 值、pitch positions、以及 glossary 已 materialize。
  - **变异实测**：① 注释掉 `enrich_pitch` 调用 → 三处断言全红（`term has no pitches`）；② 注释掉 `enrich_freq` 调用 → 三处断言全红（`term has no frequencies`）。均用反向 `sed` 替换还原（不用 `git checkout --`），还原后核验零 `MUTANT` 残留、全套 19/19 恢复绿。
- **备注**：
  - 与 [BUG-1284](BUG-1284-lookup-blocking-network-timeouts.md)（网络超时阻塞，解释「4-5 秒」）、[BUG-1285](BUG-1285-hoshidicts-hash-probe-unbounded.md)（无界探测，解释「卡死」）同轮，是同一句用户报告拆出的三条独立根因。本条解释「**词典装得越多越慢**」。
  - 同轮在引擎里定位到、但**本轮未动**的其它线性成本（留作后续，收益递减排序）：`maxResults=200`（`app_model.dart:1242`）导致每次查词 ~200×词典本数 条 zstd 解压，且 vendored zstd `ZSTD_HEAPMODE=1` 使**每次解压各 malloc 一个约 30KB 的 DCtx**；排序比较器 `get_freq_values_for_dict`（`lookup.cpp:24-41`）在**每一次两两比较**里新建并排序 vector；`text_processor::process` 每个 scan 候选都重建整条 7 个 `std::function` 的处理器链；18 种语言的去屈折规则（8084 条）合并进同一张表，使 `max_suffix_length_` 被韩语拉到约 15 码点，查 3 字日语词每个递归节点仍要构造并哈希约 28 个字符串；`lookup.cpp:45` 的 `std::map` 键是完整 `std::string` 拷贝。
  - 引擎侧**没有任何 mutex**（全仓 grep 确认），所以查词慢与锁竞争无关；C++ 层也**零查询缓存**，缓存全在 Dart 侧（`app_model.dart:3862/3879`）。
