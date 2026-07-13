## BUG-776 · 竖排累计漂移探针取整假阳性（当前 develop 未复现）

- **报告**：2026-07-13（用户：「翻页漂移问题」）。验证基线为
  `origin/develop@b177f858b50769df43e4736087da5d1d37d158de`；验证分支相对基线的
  reader 生产代码无差异。
- **真实性**：❌ **当前 develop 未复现原「越翻越偏」产品问题；旧 I1 报错是测试探针
  取整假阳性。** 原 harness 在
  `hibiki/integration_test/helpers/pagination_test_harness.dart:64-70` 将 WebView 返回的
  `scroll` 和 `ctx.pageSize` 分别 `Math.round` 后，再由 Dart 对整数取模。正确的亚像素网格
  也会因此显示为 582/583px 交替步长，并伪造出 page 5→29 余数线性增长。
  - 提交 `a6c9904d0` 保留 `scroll/pageSize/minScroll/maxScroll` 的原始 `double`，并将 I1
    改为从 `minScroll` 出发量「当前位置到最近亚像素页网格」的像素误差，不再对取整值取模。
  - 修正探针后在真实 macOS WKWebView 复跑；最终 raw `pitch=582.490967`、完整扫描
    61 页，I1-I7、位置恢复 I9、快速 chrome 切换 I10 全部通过，未出现随页数增长的
    全局网格误差。
  - 本次复跑另发现 I5 在 page 31 提前停止且仍余 17426px 内容；这是同步 `paginate`
    边界误判的独立问题，已另记 BUG-777，不能回写成累计漂移。
- **[x] ① 产品无需新增修复** — 原累计漂移在保留原始小数精度后未复现；本条未修改
  `reader_pagination_scripts.dart` 或分页 CSS。产品侧后续只处理 BUG-777 的提前 `limit`，
  不按旧 I1 整数余数改 pageStep。
- **[x] ② 已修复探针并加自动化测试** — `a6c9904d0`（`test(reader): preserve
  fractional pagination geometry`）新增
  `hibiki/test/integration_helpers/pagination_test_harness_test.dart`，覆盖原始小数保真、
  浏览器 floor 后 30 页不误报、`minScroll` 锚定、真实整数步长漂移仍能报错、JS 不再取整
  五项；`804ab9262` 进一步锁定 1px 正反边界、非末页 I6 负向控制、五个 raw JS 映射，
  并仅对真实 `maxScroll` 末页 clamp 豁免 I1。专项结果 13/13 通过。
- **备注**：文件路径保留 bug 工具实际生成的
  `docs/bugs/BUG-776-vertical-pagination-drift-recurrence.md`，标题按最终验真结论修正。
  BUG-405 的「当前产品未见累计漂移」结论不再被旧 I1 假阳性推翻。
