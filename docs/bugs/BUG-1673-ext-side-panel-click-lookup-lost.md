## BUG-1673 · 侧边栏行内点击查词在迁移原生 Side Panel 时丢失
- **报告**：2026-08-15（用户：shishamo 群报「侧边栏的点击查词好像不见了，只能 shift 查」）
- **真实性**：✅ 真回归。旧页面内字幕面板（subtitle-panel.js UI 层）的行内文本 click → `window.fushiLookupAtPoint` 是三大契约之一；提交 `4ade5cae5f`（feat: move subtitles to native side panel）把 UI 层削成 headless 数据层时**连调用点一起删了**，且新守卫 `side-panel-performance.test.js` 反把「text 无 click 监听」钉成预期——变更是有意为之但没有替代品，用户只剩 Shift 悬停一条路。`content.js` 的 `fushiLookupAtPoint` 至今是零调用方的遗留死代码（它渲染页面弹窗，Side Panel 也不能直接复用）。
- **[x] ① 已修复** —（提交哈希：bf6fdce9d）`tools/browser-extension/side-panel.js` 的字幕行文本恢复 click=查词：走 Side Panel 自持的 `lookupAtPointer(pointer, true)`（显式手势分支，绕过在途闸、失败有 toast），带选区守卫（拖选/双击选择文本不触发）+ `stopPropagation`（不冒泡成行 seek）。交互契约：**点文字=查词、点时间戳/行空白=跳转、双击=选择文本、Shift 悬停=扫词**；行 title 文案同步更新。
- **[x] ② 已加自动化测试** — `side-panel-performance.test.js` 原「text 无 click」断言翻转为专项守卫：钉 text click 监听存在 + isCollapsed 选区守卫 + stopPropagation + `lookupAtPointer(..., true)` 显式手势分支。
- **备注**：同批一并补的 Side Panel 关闭路径（手动播放反向 dismiss / 面板失焦 / 列表滚动）见 BUG-1670 与 PR 说明。
