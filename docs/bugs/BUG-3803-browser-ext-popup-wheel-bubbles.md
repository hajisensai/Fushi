## BUG-3803 · 扩展查词弹窗里滚轮冒泡到宿主页（b 站调音量）
- **报告**：2026-10-26（用户：反馈 UIF7NkYCjL，b 站点词查看后滑鼠标容易改到音量）
- **真实性**：✅ 真 bug。扩展把弹窗滚轮监听挂在 shadow host 上，但只在接管滚动时 `preventDefault`；Ctrl / 横滚 / 祖先自己能滚 / 词条导航 blocked 等早退分支既不接管也不截传播，滚轮冒泡到宿主页，b 站播放器在祖先上把 wheel 映射为音量（`fushi/assets/popup/popup.js` `__fushiPopupWheelListener` 早退段；`tools/browser-extension/content.js:1986` 的截传播列表不含 wheel）。
- **[x] ① 已修复** — 弹窗内（扩展上下文、滚轮穿过弹窗 shadow）的滚轮在任何早退前先 `stopPropagation`，只截传播不 preventDefault，原生滚动照常。三份 popup.js 镜像同步。提交见分支 `claude/feedback-system-fix-d0ccae`。
- **[x] ② 已加自动化测试** — `tools/browser-extension/popup-wheel-lazy.test.js`（Ctrl / 横滚两种不接管的滚轮也截传播且不 preventDefault）。
- **备注**：未在真实 b 站页面上手测。
