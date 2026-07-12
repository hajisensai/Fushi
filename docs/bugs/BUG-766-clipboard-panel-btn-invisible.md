## BUG-766 · 剪贴板面板图钉/关闭按钮暗背景不可见
- **报告**：2026-07-13（用户：截图 — 剪贴板面板栏右上的图钉📌和关闭×几乎看不见，要求「有个背景或者什么」）
- **真实性**：✅ 真 bug。根因 `hibiki/assets/popup/global_lookup_host.js:358-365`（面板栏按钮样式）+ 缺失的主题转写。
  面板栏 `#global-lookup-panel-bar` 是 `position:fixed` 挂在 `document.body`，在**任何 shell 之外**，所以永不继承 `applyShellStyle` 给每个 `.global-lookup-frame-shell` 打的 `data-theme`。`.panel-btn`（图钉/关闭）只定义了一个固定字色 `rgba(60,60,67,0.6)`（为亮主题设计的深灰），且默认无背景（仅 `:hover` 才出现背景）。暗窗上深灰字贴着暗底＝完全看不见。对照 `.global-lookup-close`（每卡 ×）在 `:334` 有 `[data-theme="dark"]` 浅色变种，面板栏按钮独独没有。
- **[x] ① 已修复** — `global_lookup_host.js`：
  1. `renderStack` 面板分支把 root descriptor（`popups[0].theme`）转写到面板栏 `data-theme`（`:1194` 附近），镜像 shell 的主题机制。
  2. `.panel-btn` 加**常驻 chip 背景** `rgba(120,120,128,0.16)`（不再只 hover 才有）——直接满足用户「给它个背景」的诉求，在任意窗底都是可辨识的可点区。
  3. 新增暗主题变种 `#global-lookup-panel-bar[data-theme="dark"] .panel-btn`：浅色字 `rgba(235,235,245,0.72)` + 浅色 chip，暗窗不再吃掉字形。
  提交：<待填>
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/clipboard_panel_guard_test.dart` 新增 group「面板栏图钉/关闭可见（BUG-766 暗背景不可见）」三钉：① renderStack 把主题转写到面板栏 `data-theme`；② `.panel-btn` 规则块到 `:hover` 之间必含 `background:`（常驻 chip，防退回只 hover）；③ 暗主题浅色变种存在。全 23 例通过。提交：<待填>
- **备注**：单源文件（其余为 build 产物），无 3-way 镜像需求（那是 popup.css）。行为级验证靠真机 / node harness；本轮离屏只跑源码守卫。待真机复测暗/亮两主题下图钉与关闭均清晰可见、图钉未固定态 `opacity:0.45` 仍生效。
