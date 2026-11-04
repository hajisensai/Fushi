## BUG-4112 · apple-widget-parity-lost-in-merge
- **报告**：2026-11-05（用户：#2833 合并后 Apple 小组件比 PR 原版少了 SRS 逐小时到期预排、16 周热力图、零点切换、游戏 / 远程条目的「继续」，拍板补齐）
- **真实性**：✅ 真 bug（合并回归）。#2833 切到 #2819 的共享快照（方案 A）时，原版自带的几块没进共享 schema：
  - `fushi/apple/HomeWidgets/Extension/FushiWidgetTimeline.swift:36`（origin/develop）：timeline 只有「现在」一个 entry、6 小时后重取，没有复习预排点也没有零点节点——不开 app 时待复习数不涨、零点不换日。
  - `fushi/lib/src/platform/widget_snapshot_source.dart:581`（origin/develop）：`_collectSrs` 只给当前计数，没有学习步 `dueAt` / 次日到期的预排；`:554` 沉浸只留 35 天，排不出 16 周热力图；快照里没有下一个统计日边界。
  - `fushi/lib/src/platform/widget_snapshot_source.dart:279`（origin/develop）+ `fushi/lib/src/platform/widget_links.dart:16`：「继续」只收本机书 / 漫画 / 视频，`WidgetMediaKind` 没有游戏，互联远端补位与服务器条目不进 `shelf`（原版由首页 feed 提供，合并时整条 feed 被删）。
- **[x] ① 已修复** — 共享快照加 `srs.timeline`（`buildWidgetSrsDueTimeline`）、`heatmap`（112 天固定阈值档位）、`rollover`（同一个按天构建器对下一个统计日再算一遍）、`shelf[].link`；「继续」唯一来源 `WidgetSnapshotSource` 接进游戏（`GalgameRepository`）、互联远端（首页发布的 `RemoteContinueFeed`）、服务器条目（与「接下来」同一份 `ServerContinueFeed`）。Apple：timeline 按预排点 + `rollover.at` 出 entry，各自 `resolved(at:)`；16 周热力图视图。Android：`WidgetStore.load` 按时刻取 `srsDueAt` / `resolveRollover`，卡片走 Dart 给的 `link`。分支 `claude/apple-widget-parity`。
- **[x] ② 已加自动化测试** — `fushi/test/platform/widget_snapshot_test.dart`（预排 / 热力图 / 零点切换 / 链接与游戏门控），`fushi/test/platform/home_widgets/apple_widget_contract_test.dart`（Swift 解码键 ⊆ Dart 输出、rollover 块形状一致、两端都在渲染时解析时间字段），`fushi/test/platform/widget_links_test.dart`（`kind=game` 落游戏 tab），`fushi/android/app/src/test/kotlin/app/fushi/reader/widgets/WidgetSnapshotTimeTest.kt`（Kotlin 取值规则）。
- **备注**：Swift 本机编不了，靠 PR 的 macOS / iOS CI 编译；真机 / 模拟器上小组件 timeline 换画面未复测。互联远端卡没有封面（host 封面要经互联取图，小组件不另发请求）。
