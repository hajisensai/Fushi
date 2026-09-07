## BUG-2227 · 关书结算的是上次采样单元而非此刻可见页
- **报告**：2026-09-06（用户：「检查一下触发其他翻页是否还有这样的问题」——枚举翻页触发源时发现）
- **真实性**：✅ 真 bug（窄边界）。根因 `navigation.part.dart:315-320`（`_handleReaderScroll` 的 B-3 窗）：`_reanchorClearedAt` 后 250ms 内的 scroll 回传直接 return **且无补刷**（打点处 `chrome.part.dart` 样式重锚 commit / 界面缩放 / chrome inset、`audiobook.part.dart` reveal）。窗内用户紧接着的真实滚动 / 翻页落点不会 arrive，只能等 10s 轮询；期间 `onSourcePagePop` / dispose 的 `leave()` 结算的是上一次采样的旧页（退出探针 `_syncPositionFromWebViewProgress` 有意不碰账本，见 wiring guard），最后一屏漏计。
- **[x] ① 已修复** — B-3 窗内丢弃 scroll 回传时按同一个窗常量排一次窗关后补刷：`_scheduleRevealProgressRefresh` 改名 `_scheduleReanchorSettleProgressRefresh`，听书 reveal 与 B-3 丢弃共用这一个单 Timer（丢弃语义不变，仍治 reflow 归零落库）。退出探针仍不 arrive（否则「拖有声书进度条 → 250ms 内关书」会把没读的落点页也记上）。
- **[x] ② 已加自动化测试** — `reader_read_ledger_wiring_guard_static_test.dart`（`_handleReaderScroll` B-3 分支在 return 前排补刷；`_scheduleReanchorSettleProgressRefresh(` 恰三处）。
- **备注**：
