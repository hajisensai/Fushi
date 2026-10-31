## BUG-3896 · 切换配置后首页统计不刷新，仍显示上一个配置的数据
- **报告**：2026-10-28（用户：群反馈 FH1toxJJxz，fushi-bot 代提交）
- **真实性**：✅ 真 bug。统计按 Profile 隔离（`loadStatFacts` 用 `resolveActiveProfileId` 取作用域），但首页只订阅 `watchDashboardDataChanges()` 的表集（`fushi/lib/src/pages/implementations/home_dashboard_page.dart:985`），其中没有 `preferences` / `profiles`；切换配置只写 `preferences.active_profile_id`，`ProfileViewModel.onApplied`（`fushi/lib/src/profile/profile_view_model.dart:574`）也不通知首页。首页 tab 保活，切完配置回首页时 `onTabActivated` 只补做「隐藏期间推迟的重载」，而这次根本没有重载被推迟 → 一直停在旧配置的统计，直到别的统计表写入或页面重建（所以是「有时」）。另外快照 `_snapshots[db]`（`:1300`）只按数据库实例缓存、不记 Profile；整批载入没有代次，切换前发出的载入晚到会覆盖切换后的结果。
- **[x] ① 已修复** — 首页另订 `profiles` / `preferences` 表级信号，防抖后核对激活 Profile，与最近一次载入针对的 Profile 不同才走既有 `_scheduleReload`（看不见时照旧推迟到切回）；整批载入开头先解析 Profile 并显式传给 `loadStatFacts(profileId:)`，快照带 `profileId`，屏上是别的 Profile 的数据时退回骨架；载入加代次，被取代的旧轮次不写快照、不上屏、不撤骨架。提交见 PR。
- **[x] ② 已加自动化测试** — `fushi/test/pages/home_dashboard_page_test.dart`「切换激活 Profile 后首页统计立即换成新配置的（反馈 FH1toxJJxz）」：真库两个 Profile、今日字数只属于 Alice，首页在屏上只改 `active_profile_id`，断言统计换成 Bob 的、切回又换回 Alice 的。
- **备注**：左上角改成切换配置、「上次看过」按配置分开属于产品需求（wish），本条不改。
