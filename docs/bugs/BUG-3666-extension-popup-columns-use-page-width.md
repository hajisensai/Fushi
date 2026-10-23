## BUG-3666 · extension-popup-columns-use-page-width
- **报告**：2026-10-22（用户反馈 Atbl_kOuZK，Windows 3.0.0 浏览器扩展：「希望词典能够上下排序，而不是一行里挤 3 个词典」。截图：b 站页面上约 370px 宽的扩展查词卡里三本词典并排，每列一百来 px、几个字一行）
- **真实性**：✅ 真 bug。词典列数 = min(用户设置, 装得下的列数)，「装得下」按 `__fushiViewportWidth()`（`fushi/assets/popup/popup.js` `effectiveDictColumns`）算——那是 `window.innerWidth`。浏览器扩展把弹窗画进网页里的 shadow root（`tools/browser-extension/content.js` `attachShadow` + `window.__fushiRoot`），`innerWidth` 是整张网页宽（桌面 1000+ px），永远「装得下」用户设的上限，窄弹窗里硬挤三列。app 内 / app 外整窗 WebView 弹窗即视口，不受影响。
- **[x] ① 已修复** — `__fushiColumnLayoutWidth()`：有 shadow 宿主时取宿主 `style.width`（弹窗基准宽，未乘宿主 zoom，正是内容排版的 CSS px），再按 `max-width: calc(100vw - 16px)` 折算；其余宿主沿用视口宽 ÷ 文档 zoom。`fushiRelayoutDictionaries`（扩展拖拽改宽 / 尺寸设置后调）同时重算 grid 列数。三份 popup.js 镜像同步。
- **[x] ② 已加自动化测试** — `tools/browser-extension/popup-shadow-host-columns-and-tooltip.test.js`（CI `node --test *.test.js`）：370px 弹窗 / 1389px 网页 / 设 3 列 → 2 列；300px → 1 列；宿主 zoom + 窄视口按 max-width 折算；非 shadow 宿主口径不变。变异实测：把宽度改回视口宽 → 3 条红。
- **备注**：用户想要严格上下排列的话，把「词典最多列数」设为 1 即可（这是设置项，不是 bug）；本修复解决的是窄弹窗不该超过装得下的列数。真机未复测。
