## BUG-3892 · 浏览器扩展 Shift 悬停查词要晃一下鼠标才触发
- **报告**：2026-10-29（用户：应用内反馈 pBDjgW3T4v「鼠标已经停留在某个单词上时，直接按下 Shift 并不会立即弹出查词窗口，必须再稍微移动一下鼠标」）
- **真实性**：✅ 真交互缺陷（根因 `tools/browser-extension/content.js` 的 Shift 悬停入口只挂在 `document` 的 `mousemove` 上，且有 4px 位移阈值；全文件没有 Shift `keydown` 入口，指针静止时按 Shift 什么都不发生）
- **[x] ① 已修复** — 把 mousemove 处理体抽成共同入口 `fushiShiftHoverAt(x, y, target, clearNativeSelection, bypassMoveThreshold)`；新增 `document` capture 阶段 `keydown(Shift)`：用 window 捕获阶段 mousemove 记下的 `fushiHoverPointerX/Y` 立即扫一次、跳过位移阈值，其余门控（批量录制、宿主模式、总开关、在途闸 + 待补查、同词去重）与 mousemove 共用；`keyup(Shift)` 复位同词去重。`fushi/assets/browser_extension/content.js` 镜像同步。分支 `pr/fb-browserext`。
- **[x] ② 已加自动化测试** — `tools/browser-extension/shift-hover.test.js` 新增 4 条（vm 真加载 content.js：静止按 Shift 发查词且用最后坐标 / repeat 不重发、松开再按可重查 / 无指针、输入框、组合键、总开关关闭不查 / 在途闸同样拦 keydown）。改前 2 条红、改后全绿。
- **备注**：Side Panel（`side-panel.js`）早已有同样的 modifier-on-keydown 路径，这次补的是页面内容脚本。未在真 Chrome 装扩展验证。

### 边界

- 只认首次按下（`e.repeat` 自动连发不重复扫）；Ctrl/Alt/Meta 同按的组合键不算查词。
- 焦点 / 事件目标在 input、textarea、contenteditable 里：Shift 是在打大写或扩选，不查词。
- 还没见过指针、或指针已移出文档（`fushiPointerOutsideDocument`）：没有可信坐标，不扫。
- keydown 入口不清原生选区：单按 Shift 不会扩选，清了反而毁掉用户正要 Shift+点击 / Shift+方向键扩的选区。
- 宿主模式（应用内浏览器）用 `elementFromPoint` 取指针下元素，仍只处理扩展自绘字幕覆盖层，与 mousemove 入口同判据。
