## BUG-1030 · 浏览器扩展字幕列表覆盖页面而非挤压画面
- **报告**：2026-07-23（用户：wrds）
- **真实性**：✅ 真 bug。`tools/browser-extension/subtitle-panel.js` 的推挤目标仅覆盖 Netflix 容器；YouTube 找不到目标时仍挂载 fixed 侧栏，于是直接覆盖页面右侧。
- **[x] ① 已修复** — YouTube 优先压缩 `ytd-app`，通用站点回退到视频父容器；关闭/暂停侧栏时精确恢复原始行内宽度和 CSS 优先级。
- **[x] ② 已加自动化测试** — `tools/browser-extension/subtitle-panel.test.js` 覆盖 YouTube 独立右栏的压缩与恢复。
- **备注**：侧栏保持 320 px 固定宽度，页面主体使用 `calc(100% - 320px)` 为其腾出空间。
