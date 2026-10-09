## BUG-3142 · 浏览器扩展拖右下角改弹窗大小后词条不重排
- **报告**：2026-10-09（用户群：「拖右下角调整弹窗大小后，当前词条不会立即重新排版，要重新查词才行」；开发者确认是 bug）
- **真实性**：✅ 真 bug。多列词典时 popup.js 的 masonry 把每张词典卡的宽度 / 位置写成 inline px（列宽按铺排那一刻的容器宽算），只在 `window` resize（`vendor/popup.js:6705`）与卡片自身高度变化时重铺；扩展弹窗是宿主页里一个可调宽的 shadow 宿主，拖把手只改宿主宽度（`tools/browser-extension/content.js:2841` 原 `fushiInstallResizeDrag` 的 move），宿主页 window 没变 → 卡片停在旧列宽：拖窄被裁、拖宽留白。真机复现：620→360px 后 2 张卡右缘仍在 864px（宿主右缘 614px），被裁掉。
- **[x] ① 已修复** — `content.js` 新增 `fushiRelayoutPopupContent` / `fushiScheduleRelayoutPopupContent`：拖动中按帧合并、松手再落实一次，调 popup.js 对宿主开放的重铺入口 `window.fushiRelayoutDictionaries`（in-app 改列数也走它）；扩展字号覆盖就地换 zoom 时同样重铺。真机复测：拖到 360px 后卡片右缘 594px、零溢出。提交见 PR。
- **[x] ② 已加自动化测试** — `tools/browser-extension/popup-host-ux.test.js`（vm 真加载 content.js 驱动把手 pointerdown/move/up：同帧多次 move 只排一次重铺、松手立刻重铺、纯点击不重铺；删掉调用即红）。
- **备注**：有效列数仍按宿主页视口宽算（popup.js 的 `__fushiViewportWidth` 在扩展里未注入弹窗宽度，那是 tooltip 等定位也在用的视口语义，本次不动）。
