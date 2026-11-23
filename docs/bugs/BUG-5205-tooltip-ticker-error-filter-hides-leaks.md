## BUG-5205 · main.dart 吞 RawTooltip ticker 错误的过滤会藏掉真实 ticker 泄漏断言
- **报告**：2026-11-15（用户：Flutter 3.50 升级遗留变通盘点）
- **真实性**：✅ 真问题。`fushi/lib/main.dart:1024-1030` 的 `FlutterError.onError` 吞掉同时含 `SingleTickerProviderStateMixin` 与 `RawTooltipState` 的错误，原意是规避老框架 tooltip 建多个 ticker；Flutter 3.50 的 `widgets/raw_tooltip.dart:552-564` 用 `_backingController ??=` 懒建唯一一个 `AnimationController`，不再出现「multiple tickers」，而这条过滤同样命中「RawTooltipState was disposed with an active Ticker」，会把真实泄漏断言藏掉。
- **[x] ① 已修复** — 删掉这条过滤，错误照常 `presentError` + 落盘。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/raw_tooltip_single_ticker_test.dart`：debug 下反复显隐 / 动画中改时长 / 动画中销毁 tooltip，断言无异常；并守住 main.dart 不再加回该过滤。
- **备注**：过滤只在 debug 生效（mixin 检查都是 assert），release 行为不变。
