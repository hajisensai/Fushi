## BUG-3652 · dashboard-volume-badge-uses-collection-position
- **报告**：2026-10-21（用户转述第三方反馈 + 截图：「weird ui, why does it say vol 17 here when I'm on volume 2/17」；首页「继续」主角卡封面是第 2 卷，进度条右侧徽标却是 `Vol. 17`）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_dashboard_page.dart` 书合集续读卡把 `idx + 1`（续读目标在合集排序里的**位置**）当卷号传给 `t.home_continue_volume`。合集顺序与卷号一错位，徽标就把位置当成卷号说出来；续读目标本身（锚点 = 最近读过的那卷）是对的。会让顺序错位的形态：手动「建系列 / 并入合集」按选择顺序尾插（`addToCollection` 不排序）、缺卷、只收了部分卷。用户这套书（オーバーラップ文庫 17 卷）的 dc:title 正是混写：1、2 卷是全角空格 + 全角数字 `まで　２`，3 卷起半角 `まで 3`。
- **[x] ① 已修复** — 新增纯函数 `dashboardBookVolumeNumber`：优先取书名里的卷号（与 `BookSeriesGrouper` 同一判据 `parseBookSeriesKey`，全角已折半角），书名没有卷号才退回合集内位置。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_continue_book_test.dart` 的 `dashboardBookVolumeNumber` 组（用户原样书名、第 2 卷排在第 17 位 → 2；无卷号书名退回位置）。变异实测：helper 改回直接返回位置，用例变红。
- **备注**：没有拿到该用户的数据库，无法确认他的合集具体是经哪条路径排成这样；徽标改按书名卷号后与合集顺序无关。
