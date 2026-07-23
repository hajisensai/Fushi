## BUG-1029 · 浏览器扩展 YouTube 字幕列表逐字累积为重复行
- **报告**：2026-07-23（用户：wrds）
- **真实性**：✅ 真 bug。`tools/browser-extension/content.js` 每 200 ms 采样 YouTube 自绘字幕 DOM，文本变化即新建 cue；自动字幕逐字扩长时，因此把每个中间快照都追加进 live 轨。
- **[x] ① 已修复** — 当前文本是上一快照的严格前缀时，就地更新当前 live cue 的文本与暂定结束时间；换句仍新建 cue。
- **[x] ② 已加自动化测试** — `tools/browser-extension/universal-subtitle-providers.test.js` 覆盖逐字扩长只保留一行、换句新增一行。
- **备注**：`subtitle-panel.js` 同时刷新长度未变化但 cue 对象已更新的现有行，避免数据去重后界面仍显示旧文本。
