## BUG-729 · MDX/StarDict/DSL 等 simple 词典屈折形查词命中丢失
- **报告**：2026-07-11（内部审计：讨论 MDX 支持时发现「查词大概率有问题」，沿代码路径证实）
- **真实性**：✅ 真 bug。根因 `native/hoshidicts/hoshidicts_src/importer.cpp:889`（改前 `rules_len=0`）
  ＋ `native/hoshidicts/hoshidicts_src/lookup.cpp:139-142`（`filter_by_pos`）。
  MDX/StarDict/DSL 全走 `write_simple_dict`；`process_simple_entries` 给每条词写
  `rules_len=0`（无词性）。查词时 `Lookup::filter_by_pos`：当查询经过去屈折
  （`d.conditions != 0`，如动词过去式 食べた→食べる）时，会 `std::erase_if` 删掉
  `(pos_to_conditions(term.rules) & d.conditions) == 0` 的词条；空 rules →
  `pos_to_conditions([])=0` → 与任何 `d.conditions` 无交集 → **被删**。
  结果：simple 词典只有「词头原形直接命中」（conditions==0 那支）才留得住，凡屈折形
  命中一律丢结果。Yomitan 词典自带真实词性（v5/adj-i…）不受影响——这是「其他格式
  词典查词有问题」的真根因，不只是缺媒体/CSS。
- **[x] ① 已修复** — 「修数据结构」而非特例化共享过滤器：
  - `importer.cpp` `process_simple_entries`：simple 词条改写 `rules="*"`（通配词性）。
  - `deinflector.cpp` `pos_to_conditions`：遇 token `"*"` 返回全 1 位（`~0`），使
    `filter_by_pos` 的 erase 判据对通配词条永不触发。只影响 simple dict；Yomitan
    词条从不用 `"*"`，行为不变。提交哈希：cf5f817d5。
- **[x] ② 已加自动化测试** — `native/hoshidicts/tests/simple_dict_deinflection_test.cpp`
  （CMake 注册 `simple_dict_deinflection_test`）：① `pos_to_conditions({"*"})==~0`、真
  tag/未知 tag/空各自正常且通配与真位有交集；② `write_simple_dict` 写一条后
  `DictionaryQuery::query` 取回 `rules=="*"`，证明通配真落到 term 记录。全套 15 个
  native 测试通过（含 kanji/media/freq/pitch/ipa 查词回归门）。提交哈希：cf5f817d5。
- **备注**：term 记录读取侧 `query.cpp:229-230` 本就按 `rules_len` 变长读取（Yomitan
  词条 rules 非空），故 `rules_len 0→1` 安全无需改读取。真机复测：桌面导入一本 MDX/
  StarDict 后查一个动词屈折形，应能命中释义（待真机）。号从 724 改到 719 以避开另一
  未合分支的 BUG-724（扩展弹窗 deploy channel，PR#34）撞号。
