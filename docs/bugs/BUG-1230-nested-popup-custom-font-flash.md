## BUG-1230 · 嵌套查词显示前闪过系统字体
- **报告**：2026-07-29（用户：嵌套查词时仍会短暂看到非自定义字体）
- **真实性**：✅ 真 bug。宿主把弹窗保持隐藏直到收到 `popupRendered`，但 `hibiki/assets/popup/popup.js:3520` 在 DOM 构建完成后同步发信；`popup_settings_injection.dart` 注入的 data URL 自定义字体仍在异步解码，故冷槽/嵌套查词会先显示一帧 fallback 字体。
- **[x] ① 已修复** — `865508b29` 让宿主明确注入“本次配置了自定义字体”的状态，并让 `popupRendered` 在强制样式发现后等待 `document.fonts.ready`；加入 render generation 校验，防止旧查询的字体等待回调提前显示新查询。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/popup_font_ready_gate_test.js` 真实执行 `_firePopupRendered`，覆盖字体未就绪时不显示、无自定义字体时同步显示，以及旧 generation 不得显示新查询；2026-07-29 Node 行为用例通过。
- **备注**：本修复只把既有隐藏层的揭示门控对齐到字体完成时机，不引入固定延时。Flutter wrapper 因 `pdfium_dart` 构建 hook 下载 GitHub 资源超时而未进入用例；按用户要求未继续等待完整编译/设备验收。
