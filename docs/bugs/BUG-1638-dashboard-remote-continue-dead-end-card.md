## BUG-1638 · 首页远端继续卡对不可下载条目是死路
- **报告**：2026-08-14（互联全域盘点发现）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/misc/dashboard_remote_merge.dart` `remoteContinueCandidates`：书类候选只看 `0 < progressPercent < 100`，不过 `hasContent` 门控——host 在读的漫画/PDF（`format!='epub'`，无可导出 EPUB 树，`hasContent=false`）会出现在 client 首页「继续」，点它切到书架 tab，而书架远端列表早已按 `hasContent` 过滤掉同一条目（`reader_history/remote.part.dart`）→ 卡片点了就"消失"，死路。
- **[x] ① 已修复** —（本分支提交）`remoteContinueCandidates` 书类候选补 `hasContent` 门控，与书架远端列表同判据。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_dashboard_feed_test.dart`（纯函数：hasContent=false 的在读条目不进「继续」）。
- **备注**：漫画的互联完整支持（可见+可下载）另行落地后，此门控自然放行（届时 hasContent/format 语义按新契约走）。
