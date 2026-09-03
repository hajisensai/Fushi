## BUG-2067 · 工作台实时台词折叠后仍显示中间态前缀
- **报告**：2026-09-03（SGRE 真机 E2E：本句音轨面板已是「エル・プサイ・コングルゥ」、复制按钮也复制到整句，实时台词列表里同一条却停在「エル・プ」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/texthooker_page.dart:3409`（旧 `_TexthookerWordCache`）按行 id 缓存分词结果，并假设「行文本按 id 不可变」；但渐进折叠（`fushi/lib/src/sync/texthooker_service.dart:811` 起，BUG-1952）在引擎逐段重绘同一句时**复用最早那条的 id 并把文本换成合并后的整句**。列表项用 `_wordCache.wordsFor(line.id, line.text)` 取词（`texthooker_page.dart:2106`），id 命中即返回第一次入缓存的前缀分词，整句永远显示不出来；条目数据本身是对的，所以复制/制卡都是整句。
- **[x] ① 已修复** — 抽成 `fushi/lib/src/sync/texthooker_word_cache.dart`（`TexthookerWordCache`）：缓存项同时记文本，`wordsFor(id, text)` 文本不一致就重新分词并覆盖，同 id 同文本仍只分一次；页面改用它（本提交）。
- **[x] ② 已加自动化测试** — `fushi/test/sync/texthooker_word_cache_test.dart`：同 id 文本增长必须重分词、同文本不重分、越界淘汰最旧项（本提交）。
- **备注**：SGRE 的 draw 边界按可见字形数逐帧发布，是折叠最频繁的引擎；KiriKiri/TextRender 逐字重绘同样命中。
