## BUG-438 · 手柄重连后阅读器无限 loading

- **报告**：2026-06-27（TODO-889 症状2）
- **真实性**：✅ 真 bug（纯逻辑死锁，investigator 已定位 file:line）

### 根因

手柄连/断引发系统 inset 抖动，触发以下死锁链：

1. `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` `didChangeMetrics`（原 1503-1510）每帧 `addPostFrameCallback` 直连 `_syncPageSize`（**未去抖**）。
2. inset 抖动让 `_syncPageSize` 的宽变判定（`readerViewportNeedsRepaginate`）命中 → 走整章重载 `_navigateToChapter`。
3. `hibiki/lib/src/pages/implementations/reader_hibiki/navigation.part.dart` `_beginNavigation`（250-275）把 `_readerContentReady=false` 重挂 loading 遮罩，并调 `_startContentReadyTimeout`。
4. `_startContentReadyTimeout`（原 21-35）每次 `cancel` 旧 8s timer 再起新 8s（**相对** deadline）。抖动间隔 <8s 时兜底 timer 永远被推迟、到不了点 → loading 遮罩永挂 = 无限 loading。断+重连多次抖动解释「重连概率更大」。

### [x] ① 根因修复 — commit a5cb4e3a3

1. `reader_hibiki_page.dart` `didChangeMetrics`：改走与 `_onReaderConstraintsChanged` 同一条 ~50ms 尾沿防抖（复用现有 `_resizeRepaginateDebounce`），inset 抖动不再每帧触发重导航。
2. `navigation.part.dart` `_startContentReadyTimeout`：改 wall-clock 绝对 deadline（新纯函数 `contentReadyTimeoutDeadline` + `_contentReadyDeadline` 字段 + `_clearContentReadyTimeout` 配套清理）。抖动重武装保留仍在未来的旧 deadline 不外推 → 兜底仍能在原 deadline 到点解除 loading。content 真正就绪（`_onRestoreComplete` / spread ready / lyrics ready）与 `dispose` 清空 deadline，下次真实导航重新拿到新 8s 窗口。
3. 症状1 加固（系统焦点框残留）：`hibiki/android/app/src/main/java/app/hibiki/reader/MainActivity.java` 把 `disableSystemFocusHighlight()` 从只挂 `onCreate` 扩到 `onResume` + 新增 `onConfigurationChanged`（manifest 已声明 `keyboard` configChange，手柄连/断走 `onConfigurationChanged` 而非 recreate）。

### [x] ② 自动化测试 — `hibiki/test/pages/reader_gamepad_reconnect_loading_test.dart`

- 纯函数 `contentReadyTimeoutDeadline` 行为：null/过期/等于 now 开新窗口；**future deadline 在多次抖动（+10ms…+7990ms）下恒保留同一 deadline 不外推**（撤 wall-clock 修复转红）；越过后重开新窗口。
- 源码守卫：`didChangeMetrics` 不再 `addPostFrameCallback` 直连且必经 `_resizeRepaginateDebounce`(50ms)；`_startContentReadyTimeout` 必用 `contentReadyTimeoutDeadline`+`_contentReadyDeadline`、不得复活固定 8s 相对 timer；`MainActivity` 必有 `onConfigurationChanged` 且 `onResume` 重应用 `disableSystemFocusHighlight()`。

### 备注

- 与 TODO-699/700（app 内焦点环）不重叠；与 BUG-437（`_initBook` init 链异常逃逸致 WebView 从未构造）不同源——437 修不了 889。
- 症状1（系统焦点框）主修已合（TODO-889 症状1），本任务只做 onResume/onConfigurationChanged 低风险加固。
