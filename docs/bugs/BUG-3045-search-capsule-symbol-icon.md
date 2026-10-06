## BUG-3045 · 搜索框图标迁到 FushiIcons.search 后不再被认成搜索框：MD3 丢全胶囊、Apple 丢 36 高胶囊
- **报告**：2026-10-06（PR #1984 CI：`fushi_search_field_shape_test` / `fushi_search_field_large_test` 红）
- **真实性**：✅ 真 bug。`fa0e6fa8619`（FushiIcons 语义名迁移）把 `FushiSearchField` 的前缀放大镜从 `Icons.search` 换成 `FushiIcons.search`（FushiSymbols 字族码位 0xef7a），而搜索框判据 `_isSearchDecoration`（`fushi/lib/src/utils/components/glass/fushi_glass_inputs.dart:57`）只认 `Icons.search*` / `CupertinoIcons.search`。于是 MD3 regular 档圆角退成 12（应为 999 全胶囊）、Apple 分支 `FushiTextFieldControl` 退成 48 高普通输入框（应为 36 高 iOS 搜索胶囊）；所有用语义图标做前缀的搜索框同受影响。
- **[x] ① 已修复** — `_isSearchDecoration` 增认语义图标层的 search（`isFushiSymbol` + 码位比较，线框 / 实心两字族都认），`fushi_glass_inputs.dart:79`。提交 `eb9afd83c1b`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_search_field_shape_test.dart`（全胶囊 999 + 前缀是 `FushiIcons.search`）、`fushi/test/widgets/fushi_search_field_large_test.dart`（Apple large 36 高）。
- **备注**：
