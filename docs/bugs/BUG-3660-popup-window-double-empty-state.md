## BUG-3660 · popup-window-double-empty-state
- **报告**：2026-10-21（用户：截图「修一下」——Android 从 QQ 选中 `fushi` 调起 app 外查词窗，「未找到搜索结果」空态叠了两份，上面一份图标不同、错位）
- **真实性**：✅ 真 bug。app 外查词窗基础层传 `overrideFillColor: Colors.transparent`（`fushi/lib/src/pages/implementations/popup_dictionary_page.dart` `_buildLayer`，整卡由外层 surface 画），而 BUG-2588 的热槽空结果「不透明」盖板是 `ColoredBox(color: fillColor)`（`dictionary_popup_layer.dart` `_buildBody` 热槽分支）——实际全透明。热槽 WebView 在真实空结果时仍挂载，popup.js 自己画「未找到」（`fushi/assets/popup/popup.js` `renderPopup` 空结果分支），透过透明盖板露出来，Flutter 的 `FushiPlaceholderMessage` 又盖一份。搜索中盖板（`FushiDeferredLoading` 的 background）同样透明。
- **[x] ① 已修复** — `DictionaryPopupLayer` 新增 `coverFillColor`（搜索中 / 空结果盖板底色），基础层由宿主传外层卡片的不透明色（`_cardColor`，与卡片共用一个值）。提交 `8fbcd3a563`。
- **[x] ② 已加自动化测试** — `fushi/test/pages/popup_dictionary_empty_result_cover_test.dart`：真 PopupDictionaryPage 搜索 → 热槽空结果，断言盖板 alpha=1 且等于卡片色。变异实测：去掉宿主传 `coverFillColor` 一行 → 红（Expected 1.0 / Actual 0.0）。
- **备注**：真机未复测（Android 截图路径）。只有 app 外查词窗基础层传透明面板，其余宿主不受影响。
