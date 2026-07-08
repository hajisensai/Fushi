## BUG-651 · 分页阅读器翻页看到上下页内容(相邻页泄露)复诉·真机WebView2实测已修

- **报告**：2026-07-08（用户复诉 TODO-1285：「还是会看到上下页的内容·你实机测试完在发解决」）
- **真实性**：✅ 泄露机制真实存在，但**当前 origin/develop 已根因修复、真机不漏**。用户看到的是修复落地(Jul 7–8)之前的旧构建。本条为「真机 WebView2 实测复验」结论，不改阅读器代码（重做会引回归）。

### 真机验证（Windows WebView2 = Chromium/Blink，与安卓 WebView 同族）

新增 itest `hibiki/integration_test/reader_page_edge_leak_verify_itest.dart`：在**真实 WebView2 引擎**里注入 `ReaderContentStyles.css`(`reader_content_styles.dart`) 生成的真实分页 CSS、填入内容色(红 `#dc1414`)多列内容、滚到跨页位置，用 `takeScreenshot()`（CDP `Page.captureScreenshot`，捕获引擎真实绘制含 clip-path + `html::before` 覆盖条）取真像素量页边距带颜色。横排/竖排 × 单列/多列 × 3 变体，`.\hibiki\tool\run_windows_itest.ps1` 跑，全 PASS（exit 0，"All tests passed!"）。页边距带「相邻页内容色占比」实测（0=干净、1=整带泄露）：

| 布局 | develop 全量修复 | no-fix 对照(去 clip-path+去覆盖条) | overlay-only(去 clip-path 留覆盖条) |
|---|---|---|---|
| 横排单列 H1 | 0.00 / 0.00 ✅干净 | 0.89 / 0.89 ❗泄露 | 0.00 / 0.00 ✅干净 |
| 横排双列 H2 | 0.00 / 0.00 ✅干净 | 0.89 / 0.89 ❗泄露 | 0.00 / 0.00 ✅干净 |
| 竖排单列 V1 | 0.00 / 0.00 ✅干净 | 1.00 / 1.00 ❗泄露 | 0.00 / 0.00 ✅干净 |
| 竖排双列 V2 | 0.00 / 0.00 ✅干净 | 1.00 / 1.00 ❗泄露 | 0.00 / 0.00 ✅干净 |

（`centerContentFrac=1.00` 全部布局 = 正文确实渲染出来、采样有效。截图证据 `H*/V*-{full-fix,no-fix-control,overlay-only}.png`：no-fix 对照肉眼可见页边缘露相邻列红条 / 竖排红条顶到 y=0；full-fix 与 overlay-only 页边距带干净留白。）

结论三点：
1. **泄露是真的**：no-fix 对照(把 clip-path + `html::before` 覆盖条都去掉)在 WebView2 上页边距带露相邻页内容色 89%–100% → 用户报的症状真实、探针有牙齿。
2. **develop 全量修复真机不漏**：full-fix 四布局页边距带均 0.00。
3. **覆盖条这层引擎无关的兜底单独就够**：overlay-only(故意关掉 clip-path，只留 `html::before`)也 0.00 → 即使目标 WebView 的 clip-path(paint 期特性)失效，`html::before` 背景色覆盖条独立遮住 padding 带泄露，引擎无关。这正是原 339a433be 兜底设计的目的，现由真机像素证实。

### 根因

分页把整章当一根 multicol 横/竖溢出、靠 body `scrollTop/Left` 移动看每页；`overflow:hidden` 只在 padding-box 裁剪，**裁不掉 padding(页边距)带内**滚过的相邻列 → 相邻页内容露进页边距。根因文件 `hibiki/lib/src/reader/reader_content_styles.dart` `_paginatedLayoutCss`：
- `body{clip-path: <contentClip>}`（:721，裁到正文内容盒，paint 期）。
- `html::before` 四边 border(宽逐项 == body padding)背景色覆盖条（:743，引擎无关兜底，未被 body clip-path 裁）。
- `column-fill:auto`（:711，防规范引擎均摊列高错位）。

### 修复

- **[x] ① 已修复** — 根因修复已在 origin/develop 落地（本条不再改阅读器代码，避免重做引回归）：
  - `339a433be` fix(reader): hide multi-column adjacent-page leak in padding band — `body{clip-path}` + `html::before` 覆盖条 + `column-fill:auto`（`reader_content_styles.dart:711/721/743-755`）。
  - 覆盖条 border 四边宽与 body padding 四边逐项一致（`clampedMarginTop/Right/Bottom/Left` 与 `padding-*` 同源），几何上恰盖住页边距泄露带、不挡正文；`pointer-events:none` 不拦选词、极大 z-index 压正文之上、低于 caret。
- **[x] ② 已加自动化测试** — 新增真机渲染层像素守卫 `hibiki/integration_test/reader_page_edge_leak_verify_itest.dart`：真实 WebView2 引擎注入真实分页 CSS + `takeScreenshot()` 取真像素，横/竖排 × 单/多列 × 3 变体，断言 develop 全量修复与 overlay-only 页边距带 ≤10% 内容色、no-fix 对照 ≥40%（探针防假绿）。这是**第一个在真实 WebView 引擎里像素级验证「翻页不露相邻页」的守卫**，补上此前 339a433be 只能靠字符串守卫 + 本机人工真机门的缺口。CI 跑不到真 WebView，故为本机 harness 守卫（与 `desktop_reader_css_dom_test.dart` 同类，`run_windows_itest.ps1` 驱动）。

- **备注**：
  - 与 `BUG-634`（每页列数不生效）、`BUG-588`（手机统计数字，同名号但不同问题）区分：本条专记「相邻页/列泄露到页边距」的真机验证。
  - **用户侧行动建议**：更新到含 `339a433be`（Jul 7–8 落地）的构建即不漏，无需任何设置迁移。
  - 证据截图落 `HIBIKI_LEAK_EVIDENCE_DIR`（本机 `leak-evidence/`）+ runner `.codex-test/windows-itest/<run-id>/`（gitignored 不入库）。
