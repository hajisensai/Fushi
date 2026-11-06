## BUG-3943 · 扩展侧边栏查字幕结果被超长番名挤压、行重叠、看不到集数
- **报告**：2026-11-01（用户：反馈 auJaOKXl3W，Windows，附 Side Panel 截图）
- **真实性**：✅ 真 bug。`tools/browser-extension/side-panel.css` `.subs-results`（原 :96）是 `max-height: 40vh` 的纵向 flex 容器，`.subs-item` 是 `<button>`，全局 `button { min-height: 32px }`（:33）把 flex 项的自动最小尺寸（内容高）替换成 32px，于是结果一多每行被 flex-shrink 压扁到约 32px，换行的长标题溢进下一行（截图里行与行重叠）；集数只在来源给了 `episode` 时才混进 meta 的「·」串里，文件名里的「- 01」被挤出可视区。
- **[x] ① 已修复** — `.subs-item` 改 `flex: 0 0 auto` + 宽度钉在容器内，容器 `overflow-x: hidden`，长串 `overflow-wrap: anywhere`；`side-panel.js` 新增 `findSubsEpisode`（认 ` - 01` / `S01E01` / `EP01` / `第N話` / `[01]` / `#01`）与 `compactSubsName`（超长名中段省略，集号及其后的 `[WebRip 1080p]` 等完整保留），集号单独成块 `.subs-item-ep` 显示在行首，完整文件名进 title 提示。两镜像同步。
- **[x] ② 已加自动化测试** — `tools/browser-extension/side-panel-subs-results-layout.test.js`（CSS 契约 + 从真源码切出集号识别 / 中段省略在 vm 里跑 + 渲染契约）。
- **备注**：未在真浏览器里截图复验，只有 node 测试。
