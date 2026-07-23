## BUG-1036 · 浏览器扩展重开后连接检测误报 API 未开启
- **报告**：2026-07-23（用户：wrds）
- **真实性**：✅ 真 bug。`background.js` 会缓存连接诊断 5 秒；设置页首次自动检测调用 `refreshConnection(false)`，图标弹窗也未传 `force`，因此重开时可能复用上次瞬时离线结果并误报“API 未开启”，而手动重新检测才恢复。
- **[x] ① 已修复** — 设置页和图标弹窗每次打开均发送 `connectionStatus` 且 `force: true`，绕过短时诊断缓存，立即显示当前连接真值。
- **[x] ② 已加自动化测试** — `tools/browser-extension/connection-reopen.test.js` 锁定两个打开入口都必须强制新检测；连接诊断与弹窗既有测试同时通过。
- **备注**：保留后台 5 秒缓存供其它非交互调用降噪；只在用户明确打开 UI 时绕过，不增加常驻轮询。
