## BUG-2579 · 查词弹窗里 MDX 词典恒排在所有 Yomitan 词典之后
- **报告**：2026-09-18（用户：「mdx词典的排序始终在所有yomitan词典的后面」，附词典管理页与查词弹窗截图：
  管理页里 4 本 MDX（日本語コロケーション辞典〔研究社〕/ 現代日汉双解词典（修订版）/ 講談社 日本語大辞典 第二版 双解版 /
  新世纪日汉双解大辞典）排在 旺文社国語辞典 之前，查「しんどい」时它们却全部落在 日本国語大辞典 之后）
- **真实性**：✅ 真 bug。根因 `packages/fushi_dictionary/lib/src/language/language.dart`（`_glossariesInDictionaryOrder`）：
  管理页词典顺序只在**单条引擎结果行**（`FushiLookupResult.term.glossaries`）内部排序。引擎 `lookup.cpp:73`
  只把 `(expression, reading)` **完全相同**的词条合并成一行；MDX / DSL / StarDict 走 simple dict 导入
  （`importer.cpp` 的 `write_simple_dict`），读音恒空，于是「しんどい/しんどい」（Yomitan）和「しんどい/」（MDX）
  是两条结果行。`buildPopupJsonFromLookup` / `buildLookupEntriesJson` 随后按 `lookupHeadwordKey`
  （BUG-791：空读音归一为表记）把这两行拼成**同一张词头卡**，但拼接只是顺序追加——后一行的 glossary
  无论管理页排第几都挂在前一行的所有词典之后。用户在管理页上下移动 MDX 词典毫无效果，症状与「MDX 恒在
  Yomitan 之后」完全吻合（引擎排序把 `expression == reading` 的行排前，见 `lookup.cpp:255`，空读音行恒后）。
  汉字词（`辛い/つらい` vs `辛い/`）不受影响：空读音归一成表记后 key 不同，本来就是两张卡。
- **[x] ① 已修复** — `language.dart`：`_glossariesInDictionaryOrder` 改为泛型 `_sortedByDictionaryOrder`，
  排序单位从「结果行」改为「词头组」：`buildResultFromLookup` 先按 `lookupHeadwordKey` 给每条 entry 记组号，
  收齐后按 (组首次出现序, 管理页 rank, 源序) 稳定排序再摊平；`buildPopupJsonFromLookup` 在出 JSON 时对
  每张卡的 `glossaries` 做同一排序（隐藏词典过滤、词头预算、频次/音高去重逻辑不动）。不在顺序表里的
  词典仍稳定排最后。
- **[x] ② 已加自动化测试** — `fushi/test/models/dictionary_order_render_contract_test.dart` 新增两条：
  「显式读音的 Yomitan 行 + 空读音的 MDX 行」合成一张卡后，`entries` 与 popup JSON 的词典顺序都必须
  跟管理页（MDX 排中间），且不同词头之间的顺序不受影响。
- **备注**：`dictionary_popup_webview.dart` 的 `buildLookupEntriesJson`（entries → JSON 的回退路径）
  按 `entries` 原序出 glossary，故 `buildResultFromLookup` 一并修，两条出口同源。JS 侧（`popup.js`）不按
  词典重排，Dart 这一处是唯一数据出口。native 的 `build_popup_json`（`popup_json.cpp`）app 内已不调用。
