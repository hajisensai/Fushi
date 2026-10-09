## BUG-3216 · 查词页制卡卡片没有句子
- **报告**：2026-10-09（应用内反馈，Windows 2.10.0-debug.18345，匿名：「查词页制卡卡片没有句子」；截图里搜索框输入整句「働き手として専用できるような状態に置く」、点源文本条上的 専用 后制卡，Anki 预览无 Sentence）
- **真实性**：✅ 真 bug。弹窗 `buildMinePayload`（`fushi/assets/popup/popup.js`）从不带 `sentence`，各媒体页都在自己的 `onMineEntry` 里注入当前句；
  独立查词页（`fushi/lib/src/pages/implementations/home_dictionary_page.dart`）把结果区 `DictionaryPopupWebView.onMineEntry` 直接接到
  `DictionaryPageMixin.onMineEntry`（`dictionary_page_mixin.dart` `sentence: fields['sentence'] ?? ''`），于是 Sentence 恒空。
  查词页并非没有语境：源文本条 `_sourceLookupText` 就是用户输入 / 粘贴 / 桌面取词送来的原文，`_sourceHighlight` 标着这次查的那几个字。
- **[x] ① 已修复** — 新增 `fushi/lib/src/lookup/source_lookup_sentence.dart`：`sourceLookupMiningSentence` 取扫描高亮所在的那一句（字素簇下标换算 UTF-16 后走 `extractSentenceAt`，与 Yomitan 搜索页 / 阅读器同一句读口径）；
  只查了一个词（源文本条与词头重复、`_sourceStripRedundant`）时不造句。查词页结果区的制卡与覆写都经 `withFallbackMiningSentence` 补句，JS 已带非空句子时不覆盖。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/source_lookup_sentence_test.dart`：整句 / 多句取所在句 / 代理对下标 / 单词不造句 / 空源 / 无高亮 / 不覆盖已有句子，外加结果区制卡与覆写接线的源码守卫。
- **备注**：从释义里点出来的嵌套浮层（截图二的 大統領）不补句——源文本那句不是它的语境；那条路的例句应取释义里的句子，另议。
