## BUG-1749 · 浏览器扩展里被关闭的词典仍然出释义
- **报告**：2026-08-19（用户：浏览器的关闭了日语词典，但是还是显示日语词典）
- **真实性**：✅ 真 bug —— 根因 `fushi/lib/src/sync/fushi_remote_api_handlers.dart:99-109`（响应 envelope 不下发隐藏名单）+ `packages/fushi_dictionary/lib/src/language/language.dart:497`（popupJson 生成期不过滤）
- **[x] ① 已修复** — 过滤下沉到 `buildPopupJsonFromLookup` 这个唯一数据出口，四个消费者一次性全对
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_hidden_dictionary_filter_test.dart` 新增两条源码扫描守卫（已做三轮变异实测）
- **备注**：最初以 BUG-1742 提交（见 commit 信息），撞号后 `renumber 1742 1749`。同根顺带修好「扩展制卡把隐藏词典释义写进 Anki 卡片」（BUG-432 在扩展路径上的原样重现）

### 根因：三镜像漏了第三面

「禁用词典」不是 `enabled` 布尔列，是 `dictionary_metadata.hidden_languages_json`（`tables.dart:306-330`），判据 `Dictionary.isHidden(language)`（`dictionary.dart:82-84`）。

关键结构性前提（`app_model.dart` 的 `bucketDictPaths`，注释原文）：**隐藏的 freq/pitch/kanji 不进 FFI 引擎，但 term 词典故意仍进桶**——因为 term 的隐藏「在渲染期按 hidden 过滤」。于是 term 的过滤只活在 JS 里：

- 宿主注入 `window.hiddenDictionaryNames`（`popup_settings_injection.dart:739`）
- JS 消费（`assets/popup/popup.js` 的 `createGlossarySectionWrapper` + 制卡字段组装）

这条注入通道只有 `dictionary_popup_webview.dart` 走（app 内三个表面 + 全局查词窗）。**浏览器扩展是同一份 `popup.js` 的第三面镜子，宿主换成了 HTTP 响应，那一步注入从来没跟过来**：

- `fushi_remote_api_handlers.dart:99-109` 的响应 envelope 只有 `theme` / `audioSources` / `extensionBuild` / `dictionaryStyles*`，**没有 `hiddenDictionaryNames`**
- 扩展侧 `content.js` / `side-panel.js` 只 `window.audioSources = ...`，从不置位 hidden
- ⇒ 扩展里 `window.hiddenDictionaryNames` 恒为 `undefined` → `|| []` → **一条都不滤**

查询侧两边**本来就是同源的**（同一 `AppModel`、同一 FFI 引擎、同一 `buildPopupJsonFromLookup`、同一 `_popupSearchCache`），所以这**不是**引擎问题、不是缓存陈旧、不是 profile 串味：切换开关时 `app_model.dart` 已经 `FushiDicts.initializeTyped` 重建引擎并 `clearDictionaryResultsCache()` 清掉 `_popupSearchCache`，扩展下一次查词拿到的就是全新算的 popupJson——它只是从头到尾没收到过隐藏名单。

守卫看不见第三面镜子：原 `popup_hidden_dictionary_filter_test.dart` 只扫 `assets/popup/popup.js` 与 `dictionary_popup_webview.dart` 的注入，扩展宿主（HTTP 响应）不在扫描面内，所以 BUG-419 / BUG-432 修完之后这条泄漏一直没人发现。

### 修复：过滤下沉到唯一数据出口，而不是给第三面镜子再补一次注入

未选用的方案 A（在 envelope 加 `hiddenDictionaryNames` + 扩展三处 `window.xxx = ...` 置位）：那等于承认「每新增一个宿主都要记得再注入一次」，下一个消费者照样会漏。

采用的方案：`buildPopupJsonFromLookup` 加**必填** `required Set<String> hiddenDictionaries`，在 glossary 循环最前 `continue`（`language.dart`）。

- 必填而非可选带默认值：可选参数等于允许调用点静默漏传，编译器不管；必填让三个生产调用点在编译期强制传。
- `continue` 放在循环最前而不是只跳 `groupGlossaries.add`：只有隐藏词典释义的词头不该撑起一张空卡片，也不该占用 `maximumTerms` 词头预算。
- 隐藏名单收口成 `AppModel.hiddenDictionaryNames` 单一 getter，`popup_settings_injection.dart` 改为消费它（此前那个 `where/map` 表达式只有注入侧独有一份，别的消费者拿不到）。

效果：popupJson 从源头就不含隐藏词典 ⇒ **app 内弹窗 / 全局查词窗 / 浏览器扩展 / 制卡四条路径同时对齐**，JS 侧原有的 `hiddenDictionaryNames.includes` 过滤退化为冗余保险。

### 已知遗留（不在本次范围）

1. `window.collapsedDictionaryNames`（折叠词典）同样没下发给扩展，扩展里「折叠」仍不生效。折叠是纯展示态，不适合在数据源剔除，需要另走 envelope 补下发。
2. 隐藏判据四处都硬编码 `JapaneseLanguage.instance`（`app_model.dart` ×3、`dictionary_dialog_page.dart:1467`）。本仓无全局学习语言，这是既有隐患；本次保持语义不变，未扩大改动面。
