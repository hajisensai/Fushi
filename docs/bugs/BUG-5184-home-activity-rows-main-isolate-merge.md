## BUG-5184 · 首页活动流 `StatFacts.activityRows` 在读方 isolate 上把全部段映射 + 排序
- **报告**：2026-11-22（BUG-4960 修复时发现，PR #4116 遗留项）
- **真实性**：✅ 真问题（代码路径确认，未单独测量）。`packages/fushi_engine/lib/stats/stat_facts.dart` 的
  `StatFacts.activityRows` 是 getter：每次读都把 legacy 活动行 ∪ `segmentsAsActivityRows(segments)`（全部段）∪
  游玩会话合成行拼起来、`List.sort` 后截前 `activityLimit` 条。BUG-4960 把 `loadStatFacts` 的读库与派生挪进了
  后台 isolate、派生搬进 Rust，但这个 getter 仍在调用方（首页 `home_dashboard_page.dart`、游戏首页
  `galgame_home_page.dart`、互联 host 的远端活动端点）现算，大库上是与段数成正比的同步段。
- **[x] ① 已修复** — 根因：活动流的合并排序挂在 `StatFacts` 的 getter 上，没跟着 BUG-4960 进后台派生。修法：
  并进 `ffc_stats_derive`（`native/fushi_compute/src/stats.rs` `derive_activity`，输入版本 2：表头加 `activityLimit`、
  新表 13 legacy 活动时刻），在后台 isolate 与事实面一起把 legacy ∪ 非零段 ∪ 游玩会话按时刻倒序排好（`dart::sort`
  照搬 Dart `List.sort` 的并列去向）、截到上限，只回（来源，下标）；`stat_derive.dart` 只给截出的几条建
  `ActivityEventRow`。`StatFacts.activityRows` 改成字段，删掉 `segmentsAsActivityRows` /
  `galgameSessionsAsActivityRows` 两个整表合成函数，不留 Dart 回退。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/stats/stat_facts_parity_test.dart` 四个口径（overview /
  home / game / book）的 `activity` 与迁移前冻结的 `fixtures/stat_facts_parity.json` 逐条相同；Rust
  `stats/tests.rs` `activity_merges_sources_sorts_desc_and_truncates` 钉来源合并、倒序与截断。
- **备注**：与 BUG-4960 同一读口，不在那条「统计中心总览」的范围内。
