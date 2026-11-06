## BUG-3903 · 查词弹窗 Alt+滚轮切词停在释义中间、切回第一条不回顶
- **报告**：2026-10-31（用户：反馈 3LdKiAjwWa，Windows，附录屏对照 Yomitan）
- **真实性**：✅ 真 bug。`fushi/assets/popup/popup.js` 词条导航 `applyCurrent`（原 :6068）用 `scrollIntoView({block:'nearest'})`：比视口高的词条只滚最小距离，停在上一条释义中间；回到第 0 条也只把它滚进视口，到不了结果区最顶（词条前还有汉字卡等头部）。Alt+滚轮、键盘、手柄（`fushiFocusDictionaryEntryMove`）共用此函数。
- **[x] ① 已修复** — dc92af870d：非首条改 `block:'start'`（留白沿用 `.entry` 的 `scroll-margin-top`）；第 0 条把弹窗自身的每层纵向滚动表面归零，扩展里遇 ShadowRoot 即停、绝不滚宿主网页。三镜像同步。
- **[x] ② 已加自动化测试** — `tools/browser-extension/popup-entry-nav-scroll.test.js`（从真源码切 IIFE 在 vm 里跑；旧代码 3/4 红）。
- **备注**：未在 Windows 真 app 里录屏复验，只有 JS 行为测试。
