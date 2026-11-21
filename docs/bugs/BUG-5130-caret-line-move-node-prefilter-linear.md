## BUG-5130 · 阅读器光标每次行移动仍对章内每个文本节点各做一次行盒查询（随章长线性）
- **报告**：2026-11-22（HBK-AUDIT-023 修复 BUG-5094 时实测发现的残留成本，不是 023 本身）
- **真实性**：✅ 实测成立（性能，待评估优先级）。`fushi/lib/src/reader/reader_caret_scripts.dart` 的
  `_collectVisibleStops` / `_firstVisibleStop` 从 body 起逐个文本节点调 `_visibleSpan`，每个节点至少一次
  `Range.getClientRects`（BUG-5021 的节点级预筛）。真 Chrome、9 600 个文本节点 / 52 800 字的分页章：
  每次行移动约 13 400 次几何查询，其中约 9 600 次是不在页上的节点的行盒查询，随章长线性增长。
- **[ ] ① 未修复** — 方向：阅读器内按翻页 / 滚动轴对 `fushiReader._textIndex().nodes` 二分出页上首个节点
  （分页可复用 `_textNodeTurnSide`），向后扫到整段越过页尾即停；连续模式与竖排对开（xr）各需对应的轴判据，
  且须保证可见节点不被漏掉（插图页、浮动元素）。弹窗 DOM 很小，保持整树扫描。
- **[ ] ② 未加自动化测试** — 可在 `fushi/test/reader/paged_text_index_caret_harness.mjs` 多段落用例上把
  每次移动的几何查询断言收紧到与页上字数同量级。
- **备注**：BUG-5021 当时对同一章实测约 13 ms / 次，未在 Android WebView 上量过。
