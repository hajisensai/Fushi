## BUG-2594 · 后台任务弹窗已完成列表硬截 260px，下半截空白
- **报告**：2026-09-19（用户截图：「后台任务 → 当前任务 → 已完成」列表只占上半截 ~260px 内部滚动，到「关闭」按钮之间约 300px 空白；「顺便修复一下显示不全」）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/video/metadata/video_source_scrape_dialog.dart`（改前 `:592-595`）`_buildReport` 用 `ConstrainedBox(maxHeight: 260)` + `shrinkWrap: true` 的内嵌 `ListView`；外层 `_buildActivity`（`:239`）又把整个 tab 包成一个 `ListView.builder`，内层处在无界高度里只能硬截。`_buildConfirmation` 的候选列表同样 `maxHeight: 300`（`:558`）。弹窗本身 content 固定 880 × (屏高 × .65，夹 240–640)，`TabBarView` 用 `Expanded` 撑满——tab 区域是有界的，问题只在 tab 内部又丢了边界。
- **[x] ① 已修复** — 「当前任务」tab 改成**一个**平铺的 `ListView.builder`：状态头 → 报告汇总行 → 每条说明一行（或待确认头 → 每个候选一行）→ 排队请求，全部是同一列表的条目，铺满 tab 整个高度、单一滚动区，删掉两处 `ConstrainedBox(maxHeight)` + `shrinkWrap`。PR #1550（`f264f396926`）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_source_scrape_ui_test.dart`「finished report issues fill the whole activity tab」：1400×1000 视口、60 条说明 → 至少 8 行说明的矩形中心真正落在列表可视区（旧 260px 只露 4 行）、列表高度 == `TabBarView` 高度、能滚到第 60 条。
- **备注**：`video_task_center_ui_test.dart` 的 1500 条待确认（另一 tab，本来就 `Expanded`）不受影响。
