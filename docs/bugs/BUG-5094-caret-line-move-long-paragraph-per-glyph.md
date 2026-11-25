## BUG-5094 · 阅读器方向键行移动对跨页长段落逐字量几何（HBK-AUDIT-023）
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 PR 审查 HBK-AUDIT-023，来源 PR #3830）
- **真实性**：✅ 真 bug（性能）。根因 `fushi/lib/src/reader/reader_caret_scripts.dart:529`（`_collectVisibleStops`）与
  `:632`（`_firstVisibleStop`）（origin/develop cbdc2a45ed）：BUG-5021 的预筛 `_nodeTouchesViewport` 只能整节点跳过
  完全不在页上的文本节点；节点只要有一个行盒进了视口，就从第 0 个字到最后一个字逐字 `_charRect`
  （每字一次 `Range.getClientRects`）。一整段不换段的长文是一个文本节点、跨很多页，于是每按一次
  方向键都把整段逐字量一遍——真 Chrome 实测 76 800 字单节点章节每次行移动 81 602 次几何查询。
- **[x] ① 已修复**（5dce0a157f）— 预筛改为 `_visibleSpan(node, text, vp)`：取节点行盒（每个行片段一个 rect，按内容序），
  定出与视口相交的首 / 末行盒，再对字偏移二分（每次探测量一个字、映射到它所在的行盒，行号随偏移单调），
  得到可能可见的 `[start, end)`；逐字扫描只在这段里进行。量不出的探测（零尺寸字形）按「在范围内」处理，
  只会放宽范围、不会漏掉可见字；起点不落在代理对低半；64 字以下的节点整段扫描。
- **[x] ② 已加自动化测试** — `fushi/test/reader/paged_text_index_caret_harness.mjs`（经
  `paged_text_index_caret_test.dart`，真 headless Chrome + 生产分页 shell）新增「整章一个文本节点」横排 / 竖排两例：
  每次行移动落点与整节点逐字扫描逐次一致；几何查询修前 81 602 次 / 每次移动 → 修后横排 2 837、竖排 988
  （断言 < 节点字数 / 20）。变异实测：撤掉修复后横排每次移动 81 603 次、用例变红。原多段落两例的落点对照也改用整节点扫描作参照。
  审查补强：只比移动结果覆盖不到页首 / 页尾行（把二分出的 start / end 各偏 45 字、漏掉首末行的字，原用例仍全绿），
  现另在章首 / 0.4 / 章尾三处逐个比对 `_collectVisibleStops` 全部落点与 `_firstVisibleStop`，同一变异在竖排用例上变红。
- **备注**：节点级预筛仍是每个文本节点一次行盒查询（9 600 节点的章每次移动约 9 600 次，BUG-5021 的既有设计，
  当时实测约 13 ms），本条未改；要降到与章长无关需按翻页 / 滚动轴对节点序二分（可复用 `fushiReader._textIndex`），
  另行评估。真机 / Android WebView 上的按键耗时未实测（无真机验证）。
