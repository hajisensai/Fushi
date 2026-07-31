## BUG-1308 · 查词弹窗每条目×每词典新建一个 style 节点，触发 10 次全文档样式重算
- **报告**：2026-08-01（查词 4-5 秒调查的顺带产物，主行=BUG-1307）
- **真实性**：✅ 真 bug（已离线量化）。根因
  `hibiki/assets/popup/popup.js:3198`（函数 `createGlossarySection`，定义 `:3111`）：
  ```js
  dictWrapper.appendChild(el('style', { textContent: styleText }));
  ```
  **无条件新建 `<style>`，零去重**。`styleText` 只由 `dictName` +
  `window.compactGlossaries` + `window.dictionaryStyles[dictName]` 决定，三者在一次
  弹窗渲染内**恒定**，所以同一本词典在 10 个条目下产出的是 **10 份逐字节相同**的
  样式表。调用点在 `:3322`（首绘，每条目循环 dictNames）与 `:4120`（增量追加）。
  用户配置（26 本词典 / `maximum_terms=10` / 3 列 / 自动展开 3×3）实测 **60 个节点、
  3.39 MB CSS**。
- **[ ] ① 未修复** — **已量化，等 PM 拍板是否实施**（见下）。
- **[ ] ② 未加自动化测试** —
- **备注 · 离线量化（Chrome 150 headless，CDP tracing + 强制 flush 墙钟双口径，
  2 次热身 + 5 次测量 × 3 轮独立采样，池化中位数）**

  素材是用户真实词典目录 `D:\APP\HIBIKI_date\documents\dictionaryResources` 里
  26 本中带 `styles.css` 的 6 本（合计 285 KB 原始 / 334 KB 作用域化后），
  harness 结构对齐 `createGlossarySection`，10 条目 × 6 词典 = 60 次调用。

  | 组 | style 节点数 | 注入 CSS | JS 段 | 浏览器段 | 合计 |
  |---|---:|---:|---:|---:|---:|
  | A 现状 | 60 | 3.39 MB | 17.6 ms | **138.8 ms** | 156.4 ms |
  | B 只加 memo（仍插 60 节点） | 60 | 3.39 MB | 5.8 ms | 134.0 ms | 139.8 ms |
  | C 按词典去重节点 | 6 | 339 KB | 4.7 ms | **14.1 ms** | 18.8 ms |
  | E 隔离对照：60 节点但只含小规则 | 60 | 50 KB | 1.4 ms | 103.0 ms | 104.5 ms |

  CDP `UpdateLayoutTree`（Recalculate Style）：A 108-114 ms / C **6.3-8.3 ms**。

  🔴 **贵的是节点数，不是字节数**：E 组只有 A 的 1/67 字节，浏览器段仍要 103 ms。
  `ParseAuthorStyleSheet` 在三组里**一次都没出现**——Blink 的 inline style 文本缓存
  已经把 10 份相同副本的**解析**去重了。真正的代价是：每次 `appendChild` 带进新的
  active stylesheet → Blink 只能做**全文档**样式失效，把已插入的条目全部重算 →
  10 个条目 = 10 次全量 recalc，规模上 **O(n²)**，load-more 加条目会更差。

  ⇒ **结论：加 memo 只省 ~12 ms（纯 JS 段），浏览器侧一分不省**（memo 后 styleText
  逐字节相同，浏览器要做的事没变）。**真正的修法是把 60 个节点去重成 6 个**
  （C 组），省 ~138 ms / 占总代价 88%。

  **推荐修法（未实施）**：`createGlossarySection` 里在计算 `styleText` **之前**先查
  `container.querySelector('style[data-hibiki-dict-style="<name>"]')`，已存在就整段跳过
  （连 `constructDictCss` 一起省掉）。用 DOM 查询而不是模块级 Map，因为
  `container.innerHTML = ''` 会自动失效它，不需要额外的状态同步。
  级联安全性已核：① 各词典样式各自 scope 在 `[data-dictionary="X"]` 下，互不冲突；
  ② `@font-face` / `@keyframes` 被 `constructDictCss` 原样透出（全局），但保留「首次
  出现」与保留「末次出现」的**词典间相对顺序相同**，胜负不变；③ `applyCustomCSS`
  的节点挂在 `__hibikiOverlayParent()`（body / shadow root）末尾，永远排在
  `#entries-container` 之后，去重不影响它与词典样式的先后。
  改动须**手工同步三份 `popup.js`**（`hibiki/assets/popup/`、
  `hibiki/assets/browser_extension/vendor/`、`tools/browser-extension/vendor/`），
  守卫 `hibiki/test/build/browser_extension_popup_parity_guard_test.dart:33`。

  **为什么本轮没做**：任务口径是「浏览器侧代价 < 200 ms 就降级为记录不实施」，
  实测 138.8 ms（桌面 Chrome）低于该阈值；且被点名的修法（memo）经实测只值 12 ms。
  节点去重是另一个更大也更有价值的改动，超出本轮授权范围，留给 PM 决定。
  口径边界：测的是桌面 Chrome 150，app 内跑 WebView2 / Android WebView（同引擎族），
  相对关系成立，**中低端 Android 上绝对值会显著更差**。
