## BUG-1665 · 英语查词制卡词头不还原原形（MDX 重定向别名词条盖过原形）
- **报告**：2026-08-15（用户：查 "belongs" 命中 OALDPEX 的 belong 词条，但弹窗词头/制卡 Term 仍是 "belongs"；Yomitan 会还原成原形 belong）
- **真实性**：✅ 真 bug。根因链：
  - `native/fushidicts/fushidicts_src/mdx/mdx_reader.cpp:563` —— MDX `@@@LINK=belong` 重定向解析时只把**目标释义字节**复制到别名词条，词头仍是 "belongs"，于是导入库里 "belongs" 成了释义与 "belong" 逐字节相同的完整词条。
  - `native/fushidicts/fushidicts_src/lookup.cpp`（排序比较器 trace_len 升序）—— 查 "belongs" 同时命中「别名精确词条（0 次变形）」和「经 en 变形还原出的 belong 原形词条（1 次变形）」，别名恒排前，弹窗词头与制卡 payload 的 `expression` 就是变形面 "belongs"。
  - 英语变形规则本身没问题（`fushi/assets/transforms/en.json` 有 3rd-pers-s 等规则），仅命中排序被别名词条截胡。
- **[x] ① 已修复** — `native/fushidicts/fushidicts_src/lookup.cpp`：导入器按哈希去重相同释义、同库内别名与原形共享**同一压缩 blob**（`importer.cpp process_simple_entries`），这是逐字节精确的重定向判据。lookup 去重后：同一 surface 下，未变形精确命中的每条 glossary 若其 blob 同时支撑「真变形后 expression==deinflected 的原形命中」则删除；删空的结果整条移除。按 glossary 粒度处理，另一部词典对同一变形面的**真实独立词条**保留；无变形规则可达的拼写别名（colour→color）不受影响；已导入词典即刻生效、无需重导。（提交：见本分支）
- **[x] ② 已加自动化测试** — `native/fushidicts/tests/mdx_redirect_lemma_lookup_test.cpp`（注册于 `tests/CMakeLists.txt`，ctest 全套 20/20 绿）：①别名塌缩进原形且 matched/deinflected 正确；②释义不同的真实屈折词条保留且仍排第一；③无规则拼写别名不受影响；④跨词典按 glossary 粒度只删复制来的那份。已做变异实测：将修复条件短路成恒真，仅本测试红（19 绿 1 红），还原后 20/20 绿。
- **备注**：制卡 payload 的 `expression` 取自弹窗分组词头（`popup_json.cpp` 按 expression 分组 → `popup.js buildMinePayload`），lookup 层收敛后无需动 JS/Dart。词形还原后单词音频/查重也统一按原形。
