## BUG-3444 · book-collection-continue-next-volume
- **报告**：2026-10-15（用户：哈吉千歳——20 卷的书合集读完第 1 卷，首页「继续」里这套书直接消失，不出现第 2 卷；视频合集看完一集会推进到下一集）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/home_dashboard_page.dart` 的 `_collectContinueEntries` 对书逐本走 `isDashboardContinueBook`（只收 `ShelfReadStatus.reading`），没有合集概念：卷 1 读完判 finished 出局，卷 2 位置 0 判 unread 也进不来。视频侧早有合集 Next-Up（`_collectionResumeTarget` + `continueMemberIndex`），书侧缺同口径实现。另：`_bookCollectionKey` 只按 uid 键查合集归属，v83 前以 bookKey 记的旧成员行（`getLocalPrimaryCollectionMembership` 两种键都收）在页面侧查不中。
- **[x] ① 已修复** — 书按主合集归组，每个合集最多一张卡，续读目标走新纯函数 `dashboardBookCollectionContinueIndex`（复用 `continueMemberIndex`：锚点 = 最近阅读时刻那卷，读完推进下一卷；整套读完 / 一卷没读不出卡），角标显示「第 N 卷」（新 i18n `home_continue_volume`）；`_bookCollectionKey` uid 键查不中时回退 bookKey 旧键。散书行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_continue_book_test.dart`（纯函数三组）+ `fushi/test/pages/home_dashboard_page_test.dart`（「书合集续读」三条 widget 用例：读完卷 1 推进卷 2 / 整套读完不出卡且同合集只出最近读的一张 / bookKey 旧成员行）。
- **备注**：行为变化——同一合集多卷同时在读时，「继续」区从「每卷一张」收敛为「每合集一张（最近读的那卷）」，与视频 / 游戏合集同口径。
