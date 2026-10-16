## BUG-3454 · hidden-term-dict-still-in-lookup-engine
- **报告**：2026-10-16（用户：Discord 社区反馈转述——「关掉的词典仍然被查」「有时整词高亮，释义却只是词的一部分」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/models/app_model.dart` `bucketDictPaths` 的 `DictionaryType.term` 分支（及服务端同规则的 `packages/fushi_server/lib/src/dictionary_host.dart` `bucketServerDictPaths` `default` 分支）：被关掉的 term 词典照样装进 FFI 引擎，设计上靠查询后各输出路径再按 `hiddenDictionaryNames` 过滤。
  - 引擎 `native/fushidicts/fushidicts_src/lookup.cpp:410` 先按最长匹配 `partial_sort` 再截断到 `max_results`（= 本次词头预算，默认 10），截断发生在 Dart 过滤**之前**：关掉的词典贡献 ≥ N 个更长匹配的词头（人名词典一个表记几十种读音最典型）时，可见词典的结果被整批挤出 top-N，弹窗显示无结果 / 缺结果，且 `truncated=false` 不出「加载更多」。
  - 「整词高亮、释义只剩一部分」：`bestLength` 曾把关掉词典的长匹配算进去（BUG-2997 已在 develop 修，未进 v2.9.1）；根源同样是关掉的词典进了引擎。
  - 同一根因此前已以漏滤形式出现三次：BUG-419、TODO-865（制卡写入关掉词典的释义）、BUG-2997（entries 不滤）；popup.js 里散着 7 处 `hiddenDictionaryNames` 过滤。
- **[x] ① 已修复** — `bucketDictPaths` / `bucketServerDictPaths`：隐藏的词典四种类型一律不进引擎（term 与 freq/pitch/kanji 同规则）。切换开关本就走 `_editDictionary → _publishDictionaries → _onCacheRebuild` 排期重载并清缓存，无需新增接线；查询后的 `hiddenDictionaryNames` 过滤保留为切换到下次装载之间的第二道保险。
- **[x] ② 已加自动化测试** — `fushi/test/models/bucket_dict_paths_test.dart`（隐藏 term / 隐藏混合词典不进 term 桶）；`packages/fushi_server/test/dictionary_host_test.dart`（分桶规则 + 有原生库时端到端：唯一词典关掉后 `search` 返回 null 而非命中后滤空）。
- **备注**：取舍——Anki 牌组按词频重排（`anki_deck_reposition.dart` 经 `FushiDicts.instance.query`）以 term 词典发现词头，只存在于被关掉 term 词典里的词将不再取到词频；与「关掉 = 不参与」语义一致。
