## BUG-2743 · 扩展悬停查词离开后仍暂停、暂停续播反应不灵敏
- **报告**：2026-09-27（用户：「浏览器扩展悬停继续，会发生移出去还是暂停和继续反应不灵敏啥的」）
- **真实性**：✅ 真 bug，四个根因，全部在真 Chrome（CfT 153 + 本仓扩展 + 假 app，CDP 真鼠标事件）复现：
  ① 页面选词误开递归子层：`tools/browser-extension/vendor/selection.js:487` 的 `selectFromPosition` 每次都 `callHandler('textSelected')`，`bridge-shim.js:170-172` 把它转给 `content.js:2513` 的 `__fushiOnLinkClick` → `fushiNestedPopups.open`。app 里 textSelected 只来自弹窗 WebView 自身，扩展里页面 Shift 悬停扫描 / 悬浮字幕自动查词共用同一个 `window.fushiSelection`，于是根弹窗在场时同一个词上微动 ≥4px 就叠出一层同词子层（并白发一笔查词）；`content.js:283` 判据里的 `nestedPopupOpen` 随之恒真，离开永远不关窗、不续播（主因）。
  ② 离开判定只挂在 document 冒泡阶段（`content.js:2206`）：站点播放器控制层在冒泡阶段 `stopPropagation` 掉 mousemove 时，指针移到画面上就再也不判离开；弹窗 host 截住冒泡时坐标也停在进弹窗前那一点。
  ③ 意图确认到期不看在途（`content.js:324-328`）：查词在途时到期会先关旧弹窗、续播，紧接着在途结果弹出一个已不是悬停会话、永不自动关的新窗，视频也不再归查词管。
  ④ 在途闸只丢不补（`content.js:2163` / `2420`）：上一笔在途时滑到下一个词停住，这个词永远不查；按住 Shift 离开续播后回到同一个词，被同词去重（`content.js:2198`，只在松开 Shift 时复位）吞掉，不再查词也不再暂停。
- **[x] ① 已修复** — `content.js`：`__fushiOnLinkClick` 对 textSelected 只在选区落在弹窗 ShadowRoot 内时开子层（`fushiSelectionInsidePopup`）；离开判定改挂 `window` 捕获阶段并把 host 目标识别为「在弹窗上」；到期时查词在途则顺延（`fushiFireHoverLeave`）；在途闸吞掉的最后一次 Shift 悬停 / 自动查词记进 `fushiDeferredScan`，结果回来后补查（松开 Shift / 离开覆盖层 / 关窗即作废）；关窗复位 Shift 同词去重。分支 `pr/ext-hover-resume-responsive`。
- **[x] ② 已加自动化测试** — `tools/browser-extension/hover-leave-resume.test.js`（测试壳改为按真实传播顺序派发 window 捕获 → document 冒泡、取词桩按位置命中并像真 selection.js 一样发 textSelected、查词响应可延迟；新增 8 条：同词微动不叠子层且离开续播 / 控制层吞冒泡照样续播 / 弹窗上移动撤销判定 / 在途到期不关窗 / Shift 与自动查词的补查 / 松开 Shift 作废补查 / 离开后回同词再查再暂停）；`side-panel-lookup-on-page.test.js`（页面选词的 textSelected 不开子层；弹窗内选词照开）。新用例在上游原版上 8 红、修复后全绿。
- **备注**：真 Chrome 探针对照（上游原版 → 修复后）：控制层吞 mousemove 后移开「永不续播 → +414ms 续播」；悬浮字幕自动查词同词连触两次「叠 1 个子层、一直暂停 → 零子层、+432ms 续播」；按住 Shift 离开「叠同词子层、一直暂停 → 关窗续播，回到同词再次暂停」；慢查词（400ms）时挪到第二行字幕停住「第二行零请求 → 补查第二行」；弹窗内 Shift 悬停释义正文照常开子层（与原版一致）。未在用户具体站点（YouTube / Netflix 等）真机复演，站点是否在冒泡阶段吞 mousemove 属推断，② 的修法对不吞事件的站点无副作用。
