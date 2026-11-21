## BUG-5015 · 竖排分页 progress 0.9 落点在度量缓存作废后第一次与之后几次不一致
- **报告**：2026-11-20（路线图 #3722 第 3 节 c05 遗留：「竖排 progress 0.9 的落点在度量缓存作废后第一次与之后几次不一致（改动前后都有）」，c05 测 settle 重算耗时时的旁注，无用户报告、无原始装置与数值）
- **真实性**：❌ 未复现。
  - 代码路径：`fushi/lib/src/reader/reader_pagination_scripts.dart` `scrollToProgressPaged` 对 `0 < progress < 0.99` 只走
    `findNodeAtProgress`（两遍 walk 计数）→ 目标节点首字 range 的 `getRect` → `turnSpan(axis).start + getPagePosition` →
    `alignToPage`，**不读** `paginationMetrics`；度量缓存只在 `progress <= 0`（`contentFirstPageScroll`）与 `>= 0.99`
    （`contentLastPageScroll`）两支用到。`getScrollContext` 也不读度量。所以「度量作废」本身不改变 0.9 的换算输入，
    剩下唯一的状态是当前 scroll，而 `anchor = 矩形起点 + 当前 scroll` 对 scroll 不变。
  - 实测：新增 `tool/reader_pitch_headless/progress_landing_repeat_probe.mjs`，真 Chrome（headless）跑生产分页引擎
    （`reader_headless_shell_dump_test.dart` 产物），1400 段带注音、与 `paginated_page_first_fixed_point_harness.mjs`
    同一套 padding（24/28/32/20）+ `column-gap:22px` 的横排 / 竖排单条：三种字号切换后作废度量连落三次 0.9、
    `restoreProgress(0.9)`、作废度量后 `reapplyImageLateAnchor` 两次，以及从章首 / 0.3 / 0.95 三个起点作废度量再落，
    12 组落点全部前后一致（竖排 21px 每组都是 109548，页 179）。另用 400 段、无 padding 的几何跑过同样结果。
  - 没覆盖到的：竖排对开（`xr` 轴，需要生产 `spreadCss` 与 Chrome 145+ `column-wrap`）、真机 WebView / WKWebView、
    c05 原装置（11.5 万字 / 8403 个文本节点、机器并发负载下）。若再出现，先拿到原装置与两次落点数值，再沿上面的路径定位。
- **[ ] ① 未修复** — 未复现，不改代码。
- **[ ] ② 未加自动化测试** — 复现探针留在 `tool/reader_pitch_headless/progress_landing_repeat_probe.mjs`（不一致即退出码 1）。
- **备注**：设备复测未做（本轮不做设备验证）。
