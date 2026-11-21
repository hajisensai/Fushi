## BUG-5015 · 竖排分页 progress 0.9 落点在度量缓存作废后第一次与之后几次不一致
- **报告**：2026-11-20（路线图 #3722 第 3 节 c05 遗留：「竖排 progress 0.9 的落点在度量缓存作废后第一次与之后几次不一致（改动前后都有）」，c05 测 settle 重算耗时时的旁注，无用户报告、无原始装置与数值）
- **真实性**：✅ 真 bug，已在真 Chrome 跑生产引擎复现；与「度量缓存作废」无关，那只是 c05 装置里恰好同时发生的动作。
  - 第一轮调查（同文件旧版）用纯正文章节没复现：落点换算确实不读 `paginationMetrics`，对**画出来的**文本是 `矩形起点 + 当前滚动量` 的不动量。
  - 真根因：进度计数口径含**没有排版盒的文本节点**——正文里的 `<script>` / `<style>`、书自带 `display:none` 的元素（`createWalker` 只滤 `rt` / `rp`，计数与 `calculateProgress` / 度量 `totalChars` 同源，不能改）。目标字落在这种节点上时，
    `fushi/lib/src/reader/reader_pagination_scripts.dart` `scrollToProgressPaged`（修前 `:1336-1344`）对它的首字 range 调 `getRect`：`getClientRects()` 为空，退回 `getBoundingClientRect()` 得**全零矩形**（真 Chrome 实测，三种隐藏方式、任意滚动量都是 `[0,0,0,0]`），
    于是 `anchor = 0 + 当前滚动量`，落点变成「调用前停在哪页」的函数；竖排 `contentStart`(24) > `column-gap`(22) 时 `alignToPage(scroll)` 每次再退一页，正是「第一次与之后几次不一致」。竖排对开（xr）的 `bodyRight − 0` 则往前漂。
    连续 shell 同源：`scrollToProgressContinuous` 对 `display:none` 父元素 `scrollIntoView` 是空操作，停在原处。
  - c05 的装置把生产引擎 `<script>`（约 15.6 万字符）放在 `<body>` 里（与 `paginated_page_first_fixed_point_harness` 同一做法），11.5 万字的章 progress 0.9 恰好落进这段脚本文本——推测这就是当时的现场（原装置没留存，未逐字核对）。
  - 修前实测（`paged_progress_landing_invariant_harness.mjs`，章中段一段 `display:none`、章末一段 `<style>`）：竖排从章中段起落 0.45 得 `19582` 再落得 `18970`，从章末起 `38552 → 37940`；横排 / 竖排对开 / 连续同样随起点变化。
- **[x] ① 已修复** — `fushi/lib/src/reader/reader_pagination_scripts.dart`：
  - `findNodeAtProgress` 计数不变，命中节点没有画出来的片段时，往后取第一个画出来、有字的文本节点（进度把隐藏段的字算在下一个画出来的节点之前，`progressStops` 只给有矩形的节点立桩）；后面全都没画出来时往前取最近的一个。分页与连续两个 shell 共用这一处。
  - 新增 `renderedTextStartRect(node)`：节点第一个宽高都 > 0 的 client rect，与度量给 `progressStops` 立桩的「节点首片段」同口径。`scrollToProgressPaged` 的锚改取它，不再经 `getRect` 的全零包围盒兜底。
  - VN shell 的 progress 走屏的进度锚（`screenIndexForProgress`），不经这条路径，未改。
- **[x] ② 已加自动化测试** — `fushi/test/reader/paged_progress_landing_invariant_test.dart` + `paged_progress_landing_invariant_harness.mjs`（`chrome` 标签，真 Chrome 跑生产 shell）：横排 / 竖排单条 / 竖排对开（生产 `verticalSpreadCss`）× 三种字号、小数页步，章中段与章末各一段不画出来的文本（前向 / 后向兜底），每个 progress 从章首 / 中段 / 章末三个起点（直接设页位置，不经被测的落点）作废度量后各落两次，再走 `restoreProgress` 与作废度量后的 `reapplyImageLateAnchor`，所有落点相同且在页网格上；连续 shell 的 `scrollToProgressContinuous` 从三个起点落点相同。变异实测：撤掉修复，四个几何全红（竖排即上面的逐次退页）；带修复全绿。第一轮留的 `tool/reader_pitch_headless/progress_landing_repeat_probe.mjs` 被此测试取代，已删。
- **备注**：真机 WebView / WKWebView、Windows 离屏集成测试与三种 view mode 的真 app 复测都没做；VN 不经此路径。`getRect` 的同类全零兜底在 `scrollToCharOffset` / `alignToFragmentTarget` 等按字符 / 元素定位的路径上也存在，但那些目标来自已画出来的位置或书内锚点，本轮没有证据显示会落到无排版盒的节点上，未改。
