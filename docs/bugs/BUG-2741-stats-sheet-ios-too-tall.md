## BUG-2741 · 统计时段明细/会话 sheet 在 iOS 上过高（顶进状态栏）
- **报告**：2026-09-27（用户：统计模块点击阅读「每日 / 每周」弹出的抽屉在 iOS 上容易过高）
- **真实性**：✅ 真 bug。`adaptiveModalSheet`（`fushi/lib/src/utils/adaptive/adaptive_widgets.dart:213`）在 `auto` 设计系统下 iOS 也走 MD3 `showModalBottomSheet(isScrollControlled: true)`、不开 `useSafeArea`：sheet 高度只受内容约束，路由还抹掉了顶部安全区。时段明细（`stat_period_detail_sheet.dart` `showStatPeriodDetailSheet`）与「全部会话」（`stat_session_list.dart` `showStatSessionsSheet`）两个 sheet 的内容都是无上限的 `SingleChildScrollView`，条目一多 sheet 就长到屏幕最顶，拖动条压进状态栏 / 灵动岛之下，盖满页面且难以下拉收起；iOS 刘海 / 灵动岛机型顶部安全区最高，症状最明显。
- **[x] ① 已修复**（pr/stats-sheet-ios-height）— `stat_shared.dart` 新增 `statSheetHeightCap` / `kStatSheetMaxHeightFactor = 0.8`，两个统计 sheet 的内容统一截到屏高 80%，超出在 sheet 内滚动；内容少时照常按内容收缩。
- **[x] ② 已加自动化测试** — `fushi/test/pages/stat_period_detail_sheet_test.dart`（iPhone 尺寸 40 条：内容截到上限、顶边在安全区下、末条可滚到；1 条时仍收缩）、`fushi/test/pages/stat_session_list_test.dart`（「全部会话」40 条截到上限且可滚到末条）。
- **备注**：未在真 iOS 设备上复测，结论来自 widget 测试（393×852 视口）。
