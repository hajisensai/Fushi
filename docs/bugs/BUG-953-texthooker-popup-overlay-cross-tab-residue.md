## BUG-953 · games tab 保活时查词弹窗与 barrier 跨 tab 残留遮挡
- **报告**：2026-07-21（PR#295 落地审查 H4，fable5）
- **真实性**：✅ 真 bug（代码路径核验）。根因 `hibiki/lib/src/pages/implementations/texthooker_page.dart:961-999` + `home_page.dart:898-902`：games 加入 `_keepAliveTabs`（Offstage 保活不走 `deactivate`），而查词浮层/全屏 barrier 插在 root Overlay 且 `_overlayInert` 只在 deactivate/activate 翻转——开着弹窗切到其它 home tab 时弹窗 + barrier 残留覆盖新 tab。home 层保活仍是 Offstage 非 IndexedStack，BUG-750 红线未违反。
- **[x] ① 已修复** — `texthooker_page.dart` 加 `didChangeDependencies`：home_page 保活用 `Offstage`+`TickerMode(enabled: visible==tab)`，故 `TickerMode.of(context)`（InheritedWidget，变化触发 didChangeDependencies）是现成的可见性信号。tab 不可见时把插在 root Overlay 的查词浮层置 `_overlayInert=true` 并 `markNeedsBuild`（收起为 SizedBox），防弹窗/barrier 跨 tab 残留；重新可见恢复，保留浮层状态。补上 deactivate 覆盖不到的 Offstage 隐藏这一路。
- **[x] ② 已加自动化测试** — `test/pages/texthooker_page_test.dart`「保活 tab 被 TickerMode 隐藏时查词浮层置 inert，恢复可见时复原」：套可切换 `TickerMode`，经 `@visibleForTesting debugOverlayInert` 断言隐藏→inert、恢复→非 inert。
- **备注**：
