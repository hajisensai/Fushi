## BUG-819 · 桌面查词浮窗顶部图钉/关闭控制栏浅色下太淡看不清
- **报告**：2026-07-15（用户：截图指顶部「图钉+关闭」控制条）
- **真实性**：✅ 真 bug — 根因 `hibiki/assets/popup/global_lookup_host.js`（浅色变体样式注入）
- **[x] ① 已修复** — `assets/popup/global_lookup_host.js` 浅色变体 `#global-lookup-panel-bar` 栏底+`.panel-btn` 芯片/图标对比上调
- **[x] ② 已加自动化测试** — `hibiki/test/pages/lookup_panel_bar_contrast_guard_test.dart`（源码扫描守卫）
- **备注**：与 [[BUG-818]]（浮窗卡片半透明透壁纸）同一截图、不同根因；本条是**顶部控制条自身对比**问题。

### 根因
桌面全局查词浮窗顶部控制条（拖拽 grip + 置顶图钉 📌 + 关闭 ×）是 `global_lookup_host.js` 在 WebView 注入的 `#global-lookup-panel-bar`。其**浅色窗口变体**取值过淡：
- 栏底 `background: rgba(120,120,128,0.10)`（10%）——整条 28px 栏几乎无存在感。
- 按钮 `.panel-btn` 芯片 `rgba(120,120,128,0.16)`（16%）+ 图标 `rgba(60,60,67,0.75)`（75%）。
- 未置顶时 `.panel-pin-off{opacity:0.45}` 再把图钉砍到 45%。

在浅色壁纸/浅色卡片上，栏底+芯片+半透明图标叠加后整条控制栏糊没，图钉/关闭按钮基本看不清。深色变体（`data-theme="dark"`，BUG-768）本就单独调过、正常。

### 修复
只上调**浅色变体**对比（深色变体不动）：
| 元素 | 旧 | 新 |
|---|---|---|
| 栏底 background | 0.10 | 0.18 |
| 按钮芯片 background | 0.16 | 0.30 |
| 按钮图标 color | 0.75 | 0.92 |
| 按钮 hover 芯片/图标 | 0.28 / 0.95 | 0.42 / 1 |
| panel-pin-off opacity | 0.45 | 0.62 |

hover 同步上调避免「base 比 hover 还实」的倒挂。`global_lookup_host.js` 仅 `assets/popup/` 一处、桌面独有，无 extension/content.css 三镜像牵连。

### 测试
`hibiki/test/pages/lookup_panel_bar_contrast_guard_test.dart`：扫描 `global_lookup_host.js`，断言浅色变体已用提升后的值、且旧的过淡值（0.10 栏底 / 0.16 芯片 / 0.75 图标 / 0.45 pin-off）不再复现；深色变体 `235,235,245` 仍在（防误伤）。
