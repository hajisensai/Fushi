## BUG-1525 · 浏览器侧边栏查词存在固定延迟
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`tools/browser-extension/side-panel.js:306` 的点击入口为了等待双击，固定延迟 650ms 后才调用查词；`tools/browser-extension/side-panel.js:106` 又先等待 tabs cue 准备完成，再向本地词典服务发请求。固定等待与串行往返共同落在每次首查词的关键路径上。
- **[x] ① 已修复** — 对齐 Yomitan 的 click scan：点击立即调用查词，被动扫描延迟不再用于点击路径；cue 准备与本地 lookup 并行发起，结果层常驻复用，增加 48 项 LRU 与请求序号防止重复请求和旧响应覆盖新结果。词典抽屉放到点击点另一侧，双击原生选区仍不受影响。提交：本提交。
- **[x] ② 已加自动化测试** — `tools/browser-extension/side-panel-performance.test.js` 守卫点击路径无固定定时器、cue 与 lookup 非串行、LRU/请求序号存在，并守卫共享 popup 的鼠标事件只在词典 Shadow DOM 内生效。按用户要求本轮跳过执行自动化测试。提交：本提交。
- **备注**：Yomitan 官方源码 `ext/js/language/text-scanner.js` 中 `_onSearchClick` 直接进入 `_searchAt`，`_scanTimerWait` 只用于 passive mouse-move scan；`ext/js/app/popup.js` 预先创建并复用 iframe，内容设置异步发送，避免每次重建结果表面。
