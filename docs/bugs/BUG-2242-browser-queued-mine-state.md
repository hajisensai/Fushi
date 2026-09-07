## BUG-2242 · 浏览器制卡入队后加号恢复且缺少队列状态
- **报告**：2026-09-07（用户：制卡点击入队后加号应显示已加入队列）
- **真实性**：✅ 真 bug。`tools/browser-extension/bridge-shim.js:102` 原来入队返回 true，`fushi/assets/popup/popup.js:3588` 将其解释为 Anki 已写入，随后回查未生成的卡片使按钮恢复加号。
- **[x] ① 已修复** — 桥返回结构化 queued 状态；共享按钮显示勾号和“已加入制卡队列”，不触发 Anki 回查；按词、原字幕句首、站点和视频查询真实队列，重开保留状态，移除可重试。提交见本文件所在提交。
- **[x] ② 已加自动化测试** — `web-video-mine.test.js` 验证桥接，`sentence-context.test.js` 验证真实队列查询及不串句/视频，`fushi/test/utils/misc/popup_asset_behavior_test.js` 验证按钮成功、复点、重开、移除、失败重试。
- **备注**：扩展 Node 475 项及共享 popup 行为脚本通过，镜像一致。实际浏览器/真实制卡 E2E 未完成。
