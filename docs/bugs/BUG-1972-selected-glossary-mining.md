## BUG-1972 · 桌面选中释义制卡丢失选区
- **报告**：2026-08-30（用户：选中词典释义后制卡）
- **真实性**：✅ 真 bug。`fushi/assets/popup/popup.js` 的制卡 payload 已支持
  `popupSelectionText`，但制卡按钮只在 `touchstart` 快照选区；桌面鼠标点击没有在
  focus/click 清空原生 Selection 前保存释义文本，因此 Lapis `SelectionText` 为空。
- **[x] ① 已修复** — 制卡按钮在 `pointerdown` 统一快照鼠标、触笔与触屏选区，保留
  旧 WebView 的 `touchstart` 回退；提交哈希见本 PR。
- **[x] ② 已加自动化测试** —
  `fushi/test/utils/misc/popup_asset_behavior_test.js` 模拟 pointerdown 后浏览器清空选区，
  断言原释义仍进入 `mineEntry.popupSelectionText`；提交哈希见本 PR。
- **备注**：不改变未选中文本时的制卡字段，也不改变长按选词典（整本释义）的现有语义。
