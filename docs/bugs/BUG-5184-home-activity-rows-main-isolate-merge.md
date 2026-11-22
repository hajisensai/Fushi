## BUG-5184 · 首页活动流 `StatFacts.activityRows` 在读方 isolate 上把全部段映射 + 排序
- **报告**：2026-11-22（BUG-4960 修复时发现，PR #4116 遗留项）
- **真实性**：✅ 真问题（代码路径确认，未单独测量）。`packages/fushi_engine/lib/stats/stat_facts.dart` 的
  `StatFacts.activityRows` 是 getter：每次读都把 legacy 活动行 ∪ `segmentsAsActivityRows(segments)`（全部段）∪
  游玩会话合成行拼起来、`List.sort` 后截前 `activityLimit` 条。BUG-4960 把 `loadStatFacts` 的读库与派生挪进了
  后台 isolate、派生搬进 Rust，但这个 getter 仍在调用方（首页 `home_dashboard_page.dart`、游戏首页
  `galgame_home_page.dart`、互联 host 的远端活动端点）现算，大库上是与段数成正比的同步段。
- **[ ] ① 未修复** — 方向：并进 `ffc_stats_derive`（`native/fushi_compute/src/stats.rs`）在后台 isolate 一并产出
  截好的活动流（排序要照搬 Dart `List.sort` 的并列去向），`StatFacts.activityRows` 改成字段，删 Dart 合并。
- **[ ] ② 未加自动化测试** — 对拍向量 `packages/fushi_engine/test/stats/fixtures/stat_facts_parity.json` 已含
  `activity`（迁移前实现冻结），迁完直接用它对拍。
- **备注**：与 BUG-4960 同一读口，不在那条「统计中心总览」的范围内。
