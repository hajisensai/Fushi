## BUG-2773 · 浏览器扩展查词弹窗先落字幕下方再翻到上方
- **报告**：2026-09-29（用户：「浏览器插件弹出动画很怪，最终弹窗之前又往下弹了」，附 YouTube 字幕查词录屏：每次查词弹窗先在字幕**下方**闪一帧、下缘被视口截断，下一帧才跳到字幕上方的最终位置）
- **真实性**：✅ 真 bug。`tools/browser-extension/content.js` 的 `place()`（rAF 首帧）调 `fushiApplyPlacement()` 后立即 reveal；此刻 popup.js 只同步建了首词条 + 第 1 个词典块（`vendor/popup.js:5805` `_firePopupRendered(true)`，尾批仍在 MessageChannel 宏任务里追加），`fushiComputePlacement` 按这个矮高度判「下方放得下」→ 弹窗落字幕下方并显示；随后 BUG-1726 的 ResizeObserver 复算见弹窗长高、下方放不下 → 翻到词上方。用户看到的就是「先往下弹再跳上去」。
- **[x] ① 已修复** — `content.js:3056` 未锁边且 `window._renderInProgress` 时按 theme 上限（弹窗最终可能长到的高度）**选边**、按实测高度**定位**；`content.js:3000` reveal 时把所选一侧锁进 `fushiPlaceSide`，此后复算走 `fushiComputePlacement(..., side)`（`content.js:2617` 新增可选强制侧）只在同侧夹高、不再翻边；新查词与关窗清锁。显示前（CSS 门未放行）的复算不锁，仍按真实高度改选。
- **[x] ② 已加自动化测试** — `tools/browser-extension/popup-placement.test.js` 的 5 条 `BUG-2773` 用例：vm 沙箱真跑 `fushiApplyPlacement` 模拟「首帧矮 + 尾批在途 → 逐步长高」全程不翻边、显示后锁下方只夹高、空间充足仍落下方、强制侧纯函数不压词不出视口、reveal/清锁布线。旧代码 5 条全红，修复后全绿。
- **备注**：嵌套查词（`nested-popup-host.js` 的 iframe 子层）同样在首发 `popupRendered`（尾批在途）时就显示、第二发再落点，理论上有同类翻边；它拿不到「尾批在途」信号（`popupRendered` 参数只有高度/token/innerHeight），要修得改 `fushi/assets/popup/popup.js` 三份镜像，本次未动。未在真 Chrome 里录屏复测。
