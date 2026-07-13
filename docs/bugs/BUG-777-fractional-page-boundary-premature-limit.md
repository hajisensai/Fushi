## BUG-777 · 亚像素页距在第31页误判边界提前停翻

- **报告**：2026-07-13（复验用户「翻页漂移问题」时发现）。复现于真实 macOS WKWebView；
  当前分支只改变分页测试探针，reader 生产路径与 `develop@b177f858b` 相同。
- **真实性**：✅ 真 bug。修正 BUG-776 的取整探针后，raw `pitch=564.490967`，同步
  `fullChapterScan()` 在 page 31、`scroll=17499` 时由 `paginate('forward')` 返回 `limit`；
  但 I5 量得 `maxScroll - scroll = 17426px`，约还有 30.9 个 pageStep，显然未到章末。
  I1/I2/I3/I4/I6 同时通过，说明当前位置、内容连续性与此前每步翻页均正常，失败点是第 31 页
  的边界判定，而非累计漂移。
- **根因候选**：`hibiki/lib/src/reader/reader_pagination_scripts.dart:1908-1912` 已把 1px 内的
  readback 归一到最近页边界；page 31 会得到
  `stepScroll = 31 × 564.490967 = 17499.219977`。但 JS `paginate`
  `:2191-2202` 随后重新计算 `stepScroll / pitch`，IEEE-754 实际商可能是
  `30.999999999999996`：forward 的 `Math.floor(...)` 回落为 30，算出的 target 仍是第 31 页，
  随即被 `targetForward <= stepScroll + 1` 当作末页并返回 `limit`。backward 的
  `Math.ceil(...)` 对 `N + ε` 有对称风险。Dart 影子
  `ReaderPaginationScripts.resolvePaginateStepForTesting`
  （同文件 `:123-151`）也在 floor/ceil 前丢掉了已有的 1px 页边界容差。
- **[ ] ① 未修复** — 先用精确 `pitch=564.490967/currentScroll=17499` 的 Dart 影子测试
  证实候选根因，再只在 JS forward/back 与 Dart 影子中把距整数页号 ≤1px 的商归一为整数；
  不改 pageStep、maxScroll、CSS 或章节切换逻辑。
- **[ ] ② 未加自动化测试** — 待增加上述第 31 页 forward 红测及 `N+ε` backward 对称红测，
  同时更新 JS 源码守卫；修复后必须复跑真实 macOS WKWebView 全章扫描，确认不再提前
  `limit` 且 I5 通过。
- **备注**：聚焦设计见
  `docs/superpowers/specs/2026-07-13-fractional-page-boundary-design.md`，实现计划见
  `docs/superpowers/plans/2026-07-13-fractional-page-boundary.md`。本条不纳入任何旧分支的
  其它 57 个文件。
