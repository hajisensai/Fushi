## BUG-2983 · 浏览器扩展查词先露空毛玻璃底板、内容晚到
- **报告**：2026-10-06（用户：「查词时动画先出现一块毛玻璃，过一会儿查词框内容才出来」）
- **真实性**：✅ 真 bug。玻璃模糊（`:host([data-fushi-glass])` 的 backdrop-filter）、M3E 投影、描边都画在 shadow 宿主 `#hibiki-popup-host` 上，但 `tools/browser-extension/content.js` `fushiRender` 在等落点 / 尾批时只把内容根 `#entries-container` 设成 `visibility:hidden`（旧 `content.js:3106`），宿主本身一直可见。于是 rAF 落点 → 首查样式门（`<link>` load，最多 800 ms）→ 尾批等待（`FUSHI_REVEAL_WAIT_MS` 最多 260 ms）这几段里，页面上先是一块没有内容的模糊底板（还先钉在视口左上角 0,0），内容在 reveal 时才出现。嵌套子层（`nested-popup-host.js`）一直是整框一起藏，没有这个问题。
- **[x] ① 已修复** — 新增 `fushiSetPopupShown(c, shown)`（`content.js`）：内容根、shadow 宿主、拖拽把手同显同隐；新宿主出生即 `visibility:hidden`，新建的把手跟随宿主状态。reveal 时三者同一任务放出，入场 opacity/transform 动画仍加在带 backdrop-filter 的宿主自身上，模糊层与内容同帧、同一条曲线进场。材质（玻璃 / 投影）原样保留。
- **[x] ② 已加自动化测试** — `tools/browser-extension/nested-lookup.test.js`「新开弹窗：玻璃宿主与内容同显同隐，等待期间不露空模糊底板」：在真加载 content.js 的沙箱里逐段记录时序。修复前：`lookup-response-rendered` / `placed-waiting-css-and-tail` / `css-settled-waiting-tail` 三段都是「宿主已上屏、内容隐藏」，到 `revealed` 才有内容；修复后三段宿主都隐藏，`revealed` 一步同时可见（已用旧 content.js 变异确认测试会红）。
- **备注**：未在真 Chrome 里录帧；时序差异来自沙箱时序记录。
