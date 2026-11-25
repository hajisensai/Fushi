## BUG-5462 · 超过扫描长度的英文单词查不到（characteristically 等）
- **报告**：2026-11-26（排查 BUG-5461 时发现）
- **真实性**：✅ 真 bug。对运行中的 app 发 `/api/lookup/dictionary`：`characteristically`（18）、`internationalization`（20）、`counterproductive`（17）均 `result: null`，`responsibilities`（16）正常。app 内查词页、阅读器、字幕同样受影响。
- **根因**：`native/fushidicts/fushidicts_src/scan/word_scan.cpp` `scan_candidates`：最长窗口取前 `scan_length`（出厂 16）个码点，切点又不得落在两个空格分词类字母之间。单词长于窗口时，窗口内没有任何合法切点，候选为空。
- **[ ] ① 未修复** — 方向：窗口末尾落在首个单词中间时，把窗口延伸到该词结尾。牵涉缓存前提：`tokenize.cpp` `build_window` 只拷 `scan_length + 1` 个码点、匹配长度 LRU 按窗口建键，`lookup.cpp` 的关西方言保护与 `next_char_in_window` 都假定「结果只依赖前 scan_length 个码点」，Dart 侧 `_lookupMatchedLength` 缓存键同理，要一起改。
- **[ ] ② 未加自动化测试** — `native/fushidicts/tests/word_scan_test.cpp` 补长单词用例 + tokenize 窗口用例。
- **备注**：
