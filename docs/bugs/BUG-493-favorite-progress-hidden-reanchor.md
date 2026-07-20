## BUG-493 · 重锚时序竞态致进度概率不显示查词100%逼出
- **报告**：2026-07-01（用户：）
- **真实性**：✅ 真 bug。重锚时序竞态。进度 UI 只在 `_refreshProgress` 拿到非 null 快照才
  setState（`navigation.part.dart`）；`stableProgressInvocation`（`reader_pagination_scripts.dart:546`）
  在 JS 侧 `_reanchorPending===true` 时返 null。恢复完成后 `_onChapterLoadComplete` 先
  `_reanchorContinuousAfterRestore`（begin 同步置 `_reanchorPending=true`，`navigation.part.dart:137`）
  紧接同步 fire-and-forget `_refreshProgress`（:149 未 await）撞 pending 窗口 → 那一发返 null 丢弃
  → 顶部进度条隐藏，只剩 10s poll。查词滚 DOM 才补触发到 100%。TODO-933 的 `onAfterCommit`
  （`chrome.part.dart`）只覆盖「重锚 commit 成功」一条；gate 不放行 / begin 采不到锚
  （`beginUiScaleReanchor` charOffset<0 返 -1，`reader_hibiki_page.dart:579` 提前 return）/ 已有别处
  重锚在飞（`:2680` 返 -1）等逃逸路径下 commit 与 onAfterCommit 都不跑 → 进度仍锁死。
- **[x] ① 已修复** — 根因修复：`_refreshProgress` 读到「真实文本章却返 null」（重锚在飞瞬态）时
  经 `_maybeArmProgressReanchorRetry` 武装一次有界短延迟重试（`navigation.part.dart`），重锚一
  清旗即补到真值，覆盖所有逃逸路径；拿到真实快照即 `_cancelProgressReanchorRetry` 撤销并复位。
  只对非图片章武装（图片章 null 是合法稳态，由 `_applyImagePageProgressFallback` 兜底）、有界
  （`_kProgressRetryMax`）、coalesce（已武装不重复排队）、dispose 清理定时器。与 TODO-933 的
  onAfterCommit 补刷互补（保留不回归）。提交 9d2bd1d7f。
- **[x] ② 已加自动化测试** — 源码守卫 `hibiki/test/reader/progress_reanchor_retry_guard_test.dart`
  （断言 null 分支武装重试、只对文本章武装、有界 + coalesce、字段声明 + dispose 清理、
  onAfterCommit 补刷仍在）。
- **备注**：TODO-1053 Bug B。纯时序修复，向后兼容。
- **2026-07-18 后续（轮询 → 事件驱动根因修复）**：120ms×8 轮询重试兜的是「JS 侧
  `_reanchorPending` true→false 转换时机 Dart 不可知」——现已根治：JS 侧把该旗的写入收敛到
  单一 setter `_setReanchorPending`（`reader_pagination_scripts.dart` `_sharedJs`，两 shell
  共用，全部 14 处赋值改走 setter），true→false（重锚 settle）那一刻
  `callHandler('onReanchorSettled')`；Dart 侧（`webview.part.dart`）注册该 handler，收到即
  `_refreshProgress()` 补刷。任何清旗路径（含 commit 之外的逃逸路径）都会通知，
  `_maybeArmProgressReanchorRetry` / `_cancelProgressReanchorRetry` / 重试 timer·计数·
  `_kProgressRetryMax` 等轮询机制整体删除；onAfterCommit 补刷（TODO-933/1309，兼负责
  精确定位后的进度落库）保留不动。守卫测试
  `hibiki/test/reader/progress_reanchor_retry_guard_test.dart` 同步改为断言「清旗单点化 +
  settle 通知 + handler 接线 + 轮询不复活」。
