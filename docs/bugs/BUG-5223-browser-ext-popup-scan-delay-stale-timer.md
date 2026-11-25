## BUG-5223 · 浏览器扩展弹窗内延迟扫词：关窗 / 换设置后排着的扫描照样触发
- **报告**：2026-11-22（2026-11-22 合并审查 HBK-AUDIT-231，PR #4101 / BUG-5175）
- **真实性**：✅ 真 bug。`fushi/assets/popup/popup.js:10811`（镜像 `tools/browser-extension/vendor/popup.js`）`__fushiPopupMouseMove` 的延迟扫描计时只捕获坐标，只有「松开触发键的下一次 mousemove」与 `mouseout` 会撤。Esc 关窗（content.js `fushiHidePopup` / side-panel.js `hideLookupPane` 清 `__fushiRoot`、推进 `_renderGeneration`，不派 mouseout）、换词重渲染、或热切换触发键 / 延迟后，计时到点仍调 `selectText`，落到宿主网页的选区或新开的弹窗上。
- **[x] ① 已修复** — 计时与「排它那一刻的弹窗 + 设置」绑定：记下 `__fushiRoot`、`_renderGeneration` 与有效延迟，到点三者任一变了即作废（关窗 / 新弹窗 / 重渲染 / 切走 none 模式或改延迟值都会改其中之一，宿主无需另加撤销调用）。
- **[x] ② 已加自动化测试** — `tools/browser-extension/popup-scan-delay.test.js` 新用例（假计时器真加载 `vendor/popup.js`）：关窗、换 ShadowRoot、切走 none 模式、改延迟值四种情形到点均不扫，对照组照常扫；修复前该用例失败。
- **备注**：未在真实浏览器里手测。
