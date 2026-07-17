## BUG-870 · 浏览器扩展弹窗继承宿主页居中对齐
- **报告**：2026-07-17（用户：浏览器扩展在 Bookmeter 查“ていた”时两栏词头、释义整体居中）
- **真实性**：✅ 真 bug。扩展在 `tools/browser-extension/content.js` 的 `hibikiEnsureContainer` 中把 `#entries-container` 放进 Shadow DOM；Shadow DOM 隔离选择器但不隔离继承属性。`hibiki/assets/popup/popup.css` 的 `html, body` 根规则固定了 `direction`，却没有固定 `text-align`，生成后的 `content.css` 因此让容器继承宿主页的 `text-align:center`。浏览器用真实“ていた”词典 JSON、两栏布局及 `body{text-align:center}` 复现，目标释义 computed style 为 `center`。
- **[x] ① 已修复** — 在共享 popup 根规则固定 `text-align:left`，并由生成器重根到扩展 `#entries-container`；ruby、空状态、控件等有意居中的后代继续由更具体规则覆盖。提交：待填。
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/browser_extension_shadow_alignment_guard_test.dart` 锁定共享根规则、两份生成扩展 CSS 和 Shadow DOM 接线；另以真实浏览器复测宿主页 center 场景。
- **备注**：真实性浏览器证据（修前）为 body/host/container/目标释义四级 computed `text-align` 均为 `center`；修后 container/目标释义恢复为 `left`，宿主页与 Shadow host 仍保持 `center`，证明隔离边界生效。性能同次实测：本地词典查询+JSON 约 21ms，最新 popup 首条约 3.5ms、50 条全量约 45ms；扩展请求链路的独立根因见 BUG-871。
