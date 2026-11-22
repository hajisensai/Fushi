## BUG-5097 · 台词栏悬停在同一气泡逐字节点间反复重量整屏 OCR 框（HBK-AUDIT-045）
- **报告**：2026-11-22（外部审计 Codex 2026-11-21 PR 审查 HBK-AUDIT-045，来源 PR #3844）
- **真实性**：✅ 真 bug（性能）。根因 `fushi/lib/src/media/manga/manga_bubble_focus_js.dart:383`（origin/develop cbdc2a45ed）：
  台词栏 / 文字条的 `pointerover` 监听挂在容器上，事件从每个逐字节点（`.ocr-char`）冒泡上来，
  同一气泡里划过一个字就触发一次；每次都调 `_bzSequenceOnScreen()`（`manga_bubble_zoom_js.dart:137/147/185`：
  对每个可见页和页上每个 OCR 块 `getBoundingClientRect`，再按行排序），只为按 key 找回气泡，
  随后 `_tsOutline` 再做一次全窗口 `querySelectorAll` 清 / 加描边。条目本来就是同一次 `_tsBuild`
  从这份序列建出来的，悬停没有理由重新量几何。
- **[x] ① 已修复**（0132a9f6f6）— `_tsBuild` 建条目时同批建 `tsIndex`（key → 气泡），可见页 / OCR 数据变化时
  `_tsBuild` 重建条目，索引随之重建；悬停走 `_tsHover(key)`：与当前悬停 key 相同直接返回，换气泡 /
  移出条目才改一次描边；重建条目时清掉旧悬停描边并重置去重 key。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_bubble_focus_js_test.dart`
  「台词栏悬停：同一气泡内划过逐字节点不重量 OCR 框…（HBK-AUDIT-045）」：跑生成文档里真实的
  `_tsBuild` / 悬停 / `_bzSequenceOnScreen`，DOM 桩计数。同一气泡 40 次 pointerover：几何请求
  修前 280 次（每次 1 页 + 6 块）、描边扫描 40 次 → 修后 0 次、1 次；换气泡只多一次描边；重建条目时
  量一次（7 次）后悬停仍 0 次。变异实测：撤掉修复后 actual 280 / expected 0，用例变红。
- **备注**：真机 / WebView 内悬停的帧耗时未实测（无真机验证）。
