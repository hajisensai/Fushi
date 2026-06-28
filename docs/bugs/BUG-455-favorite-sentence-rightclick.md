## BUG-455 · 右键查词弹窗顶栏收藏句子误报未选择句子

- **报告**：2026-06-29（用户：Windows 11 阅读书籍）
- **真实性**：✅ 真 bug，根因 `lib/src/pages/implementations/reader_hibiki/chrome.part.dart:262`（右键「查词」case）与 `lib/src/pages/implementations/reader_hibiki/webview.part.dart:1105`（移动端原生菜单「查词」action）。
- **现象**：书籍里通过右键/原生菜单「查词」打开弹窗后，点弹窗顶栏的收藏星想收藏句子，toast 报「未选择句子」(`no_sentence_selected`)。

### 根因

弹窗顶栏的收藏星读 `appModel.currentMediaSource.currentSentence.text`（`chrome.part.dart:1478` `_toggleFavoriteSentence`），空串就报「未选择句子」。`currentSentence` 的唯一“真·查词”写点是 tap 查词 `_handleTextSelected`（`lookup.part.dart:166`，TODO-956 已用 `resolveCurrentSentenceText` 保非空）。

但渲染同一个 index-0 弹窗顶栏（`buildPopupAudioControls` 含收藏星）的路径其实有**三条**，另两条**绕过** `_handleTextSelected`、从不写 `currentSentence`：

1. **Windows 右键「查词」**：`chrome.part.dart` `_showReaderTextContextMenu` 的 `case 'search'` 直接调 `searchDictionaryResult(searchTerm: selectedText, ...)`（用浏览器原生选区文本，非 `ReaderSelectionData`）。
2. **移动端原生菜单「查词」**：`webview.part.dart` 的 `ContextMenuItem(id:1, title: t.search)` 同样直接调 `searchDictionaryResult`。

于是 `currentSentence` 停在默认空串（会话首次查词，或上次弹窗关闭时 `_dismissPopupAt(0)` → `clearCurrentSentence` 清掉之后），收藏星读空 → 误报。TODO-956 的两次修复（JS block-walk + Dart 词兜底）只加固了 tap 路径，故这两条菜单路径的症状未消。用户在 Windows 11、走右键「查词」正中此缺口。

### 修复

把右键「导出片段」(`_exportAudiobookClipFromSelection`) 早已在做的「原生选区 → 查词状态」解析抽成共享 helper `_fillLookupStateFromNativeSelection()`（`chrome.part.dart`），用 `nativeSelectionSentenceRangeInvocation()` 复用 tap 路径同一套 JS 算句级 norm 区间，并经 `resolveCurrentSentenceText` 把 `currentSentence` 写成非空（句子优先、派生不出退回选中词），同时填 `_lookupCue` / `_cachedSelectionRange` / `_cachedSentenceRange` / `_cachedSentenceOffset`。两条菜单「查词」路径都先调它再弹查词（helper 返回 null 时退回 `selectedText` 补满非空契约），收尾 `_checkFavoriteStatus()` 让收藏星状态正确；导出路径改为复用同一 helper（消除重复解析）。这样**每条**渲染收藏星的弹窗路径都保证 `currentSentence` 非空，消除特例。

### 影响范围 / 兼容

- tap 查词路径不变（仍走 `_handleTextSelected`）。
- 导出路径行为等价；唯一差异：`data.sentence` 为空时 `currentSentence` 从空串改为退回选中词（严格更正确，空串本就无用）。
- `prunePopupStack(0)` 只清弹窗 WebView 选区、不动 `currentSentence` 与阅读器原生选区，故先 prune 后填状态安全。

- **[x] ① 已修复** — `lib/src/pages/implementations/reader_hibiki/chrome.part.dart`（新增 `_fillLookupStateFromNativeSelection` + `case 'search'` 写穿 + 导出复用）、`lib/src/pages/implementations/reader_hibiki/webview.part.dart`（原生菜单「查词」写穿）。提交：<待填>
- **[x] ② 已加自动化测试** — `hibiki/test/reader/favorite_sentence_lookup_state_guard_test.dart`（源码接线守卫：共享 helper 写穿非空 currentSentence；两条菜单「查词」路径都经 helper + selectedText 兜底；导出复用同一 helper）。非空契约纯函数 `resolveCurrentSentenceText` 由 `test/reader/reader_selection_scripts_test.dart` 覆盖。提交：<待填>
- **备注**：整页 WebView（原生选区 JS + DB + provider）不便在 widget 测试里 mount，故用源码接线守卫锁死「弹窗顶栏收藏星的每条来源都写穿 currentSentence」契约，防回归。
