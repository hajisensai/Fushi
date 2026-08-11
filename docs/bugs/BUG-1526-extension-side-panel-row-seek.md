## BUG-1526 · 浏览器侧边栏字幕行点击不能跳转
- **报告**：2026-08-11（用户：）
- **真实性**：✅ 真 bug。`tools/browser-extension/side-panel.js:renderCues` 只给时间戳按钮注册 `fushiSubtitleSidePanelSeek`；字幕正文的第一次 click 被独占为查词，整行没有 seek listener。`event.detail > 1` 只能挡住双击的第二击，第一击仍已查词，既不符合 asbplayer 的行跳转，也会与浏览器原生双击选区竞争。
- **[x] ① 已修复** — 对齐 asbplayer：普通字幕行点击直接 seek；若当前行拥有非折叠原生文本选区则 return，不跳转也不清选区。时间戳 stopPropagation 后单独 seek；Shift+指向文字负责查词，普通正文 click 不再查词或等待 dblclick。提交：本提交。
- **[x] ② 已加自动化测试** — `tools/browser-extension/side-panel-performance.test.js` 守卫整行 seek、当前行原生选区 guard、时间戳事件隔离、正文没有 click 查词，以及 Shift 路径不调用 `preventDefault`/`removeAllRanges`。按用户要求本轮跳过执行自动化测试。提交：本提交。
- **备注**：asbplayer 的 `SubtitlePlayer` 同样在行 click 时检查 `document.getSelection()`；只有无当前行选区时才调用 `onClickSubtitle`，正文保持浏览器原生可选择。
