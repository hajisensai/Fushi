## BUG-3086 · SelectionText 写入上一次查词的旧选区
- **报告**：2026-10-09（用户：「自体」卡的 SelectionText 是「② 好ましくないことばを口に出す。こく。」，往回看很多卡都选飞了；哈吉千歳：真正的 bug 是选中文本制卡不生效）
- **真实性**：✅ 真 bug。`{popup-selection-text}` 取自 `fushi/assets/popup/popup.js` 的全局 `lastSelection`，
  它只在「+」按钮的 `onpointerdown` / `ontouchstart` 里由 `snapshotSelection()` 刷新（`popup.js` `function snapshotSelection`）。
  另两条制卡入口不经那颗按钮的 pointerdown：
  ①「调整上下文」原生对话框确认 → Dart 回调 `window.fushiPopupMineEntryByIndex(idx)` → `b.onclick()`；
  ② 快捷键 / 手柄制卡 → `window.fushiPopupMineFirstEntry()` → `mineButton.click()`。
  两条都直接用上一次点「+」时留下的 `lastSelection`；热槽 WebView 跨查词不重载、`renderPopup` 也从不清它，
  于是上一个词释义里选中的文字被写进这张卡（「選んだ旧释义串到新卡」），而这两条路上**本次**选中的文字反而永远进不去（「选中文本制卡不生效」）。
- **[x] ① 已修复** — `renderPopup` 换词重渲染时 `clearSelectionSnapshot()`；「调整上下文」按钮在 pointerdown / touchstart 快照选区（对话框弹出会清掉 WebView 活选区，确认回点沿用这份快照）；`fushiPopupMineFirstEntry` 点按钮前按此刻选区快照。三份 popup.js 镜像同步。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/popup_asset_behavior_test.js`（由 `popup_mine_audio_fresh_resolve_static_test.dart` 驱动）新增 4 条：换词后确认制卡不得带上一个词的选区；调整上下文按钮快照的选区随确认制卡进 payload；快捷键制卡无选区时不复用旧快照；快捷键制卡带此刻选区。改动前 4 条全红、改动后全绿。
- **备注**：「+」按钮自身的 pointerdown 快照（BUG-1972）不变；未选中文本时字段仍为空。
