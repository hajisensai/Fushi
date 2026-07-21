## BUG-1001 · 桌面查词浮窗顶栏图钉/防截屏关闭态浅色下太淡
- **报告**：2026-07-22（原始审计线索来自 BUG-819，见备注）
- **真实性**：✅ 真 bug — 根因 `hibiki/assets/popup/global_lookup_host.js:411,413`（浅色变体 `.panel-pin-off` / `.panel-block-off` 的 `opacity:0.45` 过淡）
- **[x] ① 已修复** — `global_lookup_host.js` 顶栏控制条「未置顶图钉」与「防截屏关闭态」两个 dimmed 态 `opacity` 由 `0.45` 上调到 `0.62`（提交见索引）
- **[x] ② 已加自动化测试** — `hibiki/test/pages/lookup_panel_bar_contrast_guard_test.dart`（源码扫描守卫）
- **备注**：源自早期 BUG-819「桌面查词浮窗顶部图钉/关闭控制栏浅色下太淡」的审计。审计当时基于**旧 develop 基底**，认为顶栏 4 个对比常量（栏底 0.10 / 芯片 0.16 / hover 0.28 / pin-off 0.45）全都过淡。核对**当前 develop** 后发现：栏底已改到 `0.18`（并加了 `border-bottom` 轮廓）、芯片已改到 `0.24`/`rgba(30,30,35,0.95)`（比旧提亮方案对比更强）、hover 已 `0.36`/`rgba(20,20,24,1)`——这三项已被其它提交独立修复且优于旧方案。**唯一仍停留在旧过淡值的是 `.panel-pin-off` 的 `opacity:0.45`**，且 develop 后来新增的「防截屏」按钮 `.panel-block-off` 也复用了同一 `0.45`（代码注释明确「与 pin-off 一致」）。因 BUG-819 号已被另一 bug（ass-bold0-fake-bold）占用，本条以新号 BUG-1001 承接这最后一处提亮，同时把 block-off 一并上调以保持二者「一致」不变式。`#global-lookup-panel-bar` 仅存在于 `assets/popup/global_lookup_host.js` 单文件（桌面独有），无 content.css / 扩展三镜像牵连。

### 根因
桌面全局查词浮窗顶栏控制条（拖拽 grip + 置顶图钉 📌 + 防截屏盾 + 关闭 ×）由 `global_lookup_host.js` 在 WebView 注入 `#global-lookup-panel-bar`。其**浅色窗口变体**下：
- `.panel-btn.panel-pin-off{opacity:0.45}`：图钉处于「未置顶」态时被砍到 45% 不透明，叠在浅色壁纸/浅色卡片上几乎看不清。
- `.panel-btn.panel-block-off{opacity:0.45}`：防截屏按钮「关闭态（允许截图）」同样 45%，与 pin-off 共用同一淡度（注释「与 pin-off 一致」），存在相同看不清问题。

栏底/芯片/hover 三项已由其它提交提亮到位；深色变体（`data-theme="dark"`，BUG-768）另有单独样式、不受影响。

### 修复
只上调这两处 dimmed 态 `opacity`，深色变体与其余常量不动：
| 元素 | 旧 | 新 |
|---|---|---|
| `.panel-pin-off` opacity | 0.45 | 0.62 |
| `.panel-block-off` opacity | 0.45 | 0.62 |

两者同步提亮以保持代码注释声明的「block-off 与 pin-off 一致」不变式，避免一个改一个不改造成倒挂。`global_lookup_host.js` 仅 `assets/popup/` 一处、桌面独有，无 extension/content.css 三镜像牵连。

### 测试
`hibiki/test/pages/lookup_panel_bar_contrast_guard_test.dart`：扫描 `global_lookup_host.js`，断言 pin-off/block-off 已用提升后的 `0.62`、旧的过淡 `0.45` 不再复现；同时锁死已在 develop 到位的浅色栏底/芯片对比不得回退、深色变体（BUG-768）`235,235,245` 仍在（防误伤）。
