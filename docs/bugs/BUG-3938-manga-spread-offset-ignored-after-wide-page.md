## BUG-3938 · manga-spread-offset-ignored-after-wide-page
- **报告**：2026-11-01（用户：反馈 haetN22fJI，iOS，双页模式跨页配对错误，「错开一页」开关无效）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/manga_spread_model.dart` 的 `buildMangaSpreads` 只在卷首应用 `spreadOffset`（封面独占），之后遇到宽页（见开き，`_widePageSolo` 默认开）就从宽页后一页重新两两配对——第一张宽页之后的整卷配对与偏移完全无关，读到后面发现配对不对时拨「错开一页」画面不变。另：旋转进双页时按全卷奇偶配对，当前聚焦页常被配到后页。
- **[x] ① 已修复** — 配对改按「段」（独占页切开的连续普通页）进行：首段按封面惯例、锚点段让锚点页做前页、其余段段首配对；偏移为 0 时首段与锚点段整体错开一页。阅读器会话锚点 `_spreadAnchorPage`：单页→双页时取当前聚焦页（`mangaSpreadAnchorLeading`，聚焦页按阅读方向放先读那侧）；在宽页之后的段里拨「错开一页」前先把当前对的前页记成锚点（`_anchorSpreadShiftAtCurrentPage`）。提交 75f1ff3bbc。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/manga_spread_anchor_test.dart`（根因复现 + 锚点 / 偏移组合 + 聚焦页做前页）。
- **备注**：锚点是会话状态，换卷 / 重开书清掉；偏移本身仍是本书覆盖持久化。真机未验证（iOS 双页旋转）。
