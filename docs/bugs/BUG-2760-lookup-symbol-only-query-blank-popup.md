## BUG-2760 · 点到纯符号（♡ ♪ ～ ‼）时查词弹窗是空白框
- **报告**：2026-09-28（BUG-2763 调查中发现，全平台）
- **真实性**：✅ 真 bug（代码路径确认）。查词前 `normalizeSearchTerm`（`fushi/lib/src/models/app_model.dart`）剥掉首尾标点/符号，点纯符号时查询词变成空串，`searchDictionary` 返回 `DictionarySearchResult(searchTerm: '')`。弹窗层 `fushi/lib/src/pages/implementations/dictionary_popup_layer.dart` `_buildBody` 的「真实空结果」判据要求 `searchTerm.isNotEmpty`（本意是区分热槽空闲占位），于是这个真结果被当成占位：热槽上既没有词条也没有「未找到」盖板，露出空 WebView。
- **[x] ① 已修复** — 判据改为「不是空闲占位单例 `kPopupSearchingPlaceholderResult`」（`identical`），占位本来就是按对象身份识别的单例；查过但无可查内容的结果照常显示「未找到」。
- **[x] ② 已加自动化测试** — `fushi/test/pages/dictionary_popup_warm_slot_empty_result_test.dart` 两条 `BUG-2760` 用例（空查询词真结果显示盖板；空闲占位单例不显示）。
- **备注**：
