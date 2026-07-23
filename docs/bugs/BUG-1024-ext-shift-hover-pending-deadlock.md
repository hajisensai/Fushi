## BUG-1024 · 浏览器扩展 Shift 悬停查词在途闸永久死锁致弹窗不敏感
- **报告**：2026-07-23（用户：）
- **真实性**：✅ 真 bug — 根因 `tools/browser-extension/content.js:1208`（在途闸 `if (hibikiPending) return;`）配 `:1279` 置位、仅在 `:1282` 的 `chrome.runtime.sendMessage` 回调里复位。MV3 background service worker 若在消息在途时被系统终止，回调**永不触发** → `hibikiPending` 永久停在 `true` → 此后所有 Shift 悬停 mousemove 被在途闸整条吞掉，表现为「按 Shift 越来越不敏感 / 时好时坏」。无超时兜底。镜像 `hibiki/assets/browser_extension/content.js` 同源。
- **[x] ① 已修复** — 把布尔闸改成带截止时间的在途判定：`hibikiPendingSince` 记发起时刻，`if (hibikiPending && Date.now() - hibikiPendingSince < HIBIKI_PENDING_TIMEOUT_MS) return;`。回调仍正常复位；截止时间是「回调永不触发」的安全兜底，超时后放行新查词，死锁彻底消失。两份镜像同步。提交：<待填>
- **[x] ② 已加自动化测试** — `tools/browser-extension/shift-hover.test.js` 新增用例：stub `sendMessage` **不回调**（模拟 worker 被杀），推进 `Date.now` 越过超时后再发 Shift mousemove，断言仍能发出第二次 `{type:'lookup'}`（旧代码此处永久卡死）。提交：<待填>
- **备注**：现有 `shift-hover.test.js` 原用同步 stub 回调，测不到此动态死锁。
