## BUG-1380 · 分页滚轮闸门在换章加载期消费手势 token，整段横向惯性被吞

- **报告**：2026-08-02（用户：TODO-2567 第 ④ 项复核）
- **真实性**：✅ 真 bug（时序缺陷：**消费 token 早于确认这个动作能否执行**）

### 根因

`ReaderWheelGestureGate.shouldStartNewGesture`（`hibiki/lib/src/reader/reader_pagination_scripts.dart:50`，PR#670 引入）
**无条件**写 `_lastTickAt = now`；而它的调用点
`hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:2132`（`onWheelPaginate` handler）
在 `_paginate` **之前**。`_paginate` 入口的 `_paginationInFlight` 守卫
（`hibiki/lib/src/pages/implementations/reader_hibiki/chrome.part.dart:91`）会直接 return。

于是：横向触控板一次滑动的首个 wheel tick 若恰好落在换章加载 / restore 在飞的窗口里，
token 已被这个**翻不动页**的 tick 吃掉；加载落定后，整段惯性的后续 tick 全部
（`now - _lastTickAt < settleInterval`）在闸门早退 ⇒ **用户这一次滑动完全没有反馈**。
闸门本身「活在 Dart State 而非 JS document」的设计是对的（翻章会重建 document），
问题只在 token 的消费时机。

### 修复

把 token 的消费挪到「确认这一 tick 能执行」之后，而不是事后回滚：
回滚方案要求调用方在 `_paginate` 早退后再回来改闸门状态，而 `_paginate` 是异步的——
回滚点落在 await 之后就与后续 tick 竞态，正是闸门要防的双翻。
故 `shouldStartNewGesture` 新增必填 `canTurnPage`（阅读器侧传 `!_paginationInFlight`），
同步地决定是否认领手势：

- `canTurnPage == false` 且本 tick 会开启新手势 ⇒ **不写 `_lastTickAt`**（不认领 token），
  返回值仍为 `true` 让 tick 继续送进 `_paginate`——那里的 in-flight 分支要靠这些 tick
  续跨章冷却窗（TODO-1229 v2）。
- 已在手势内的 tick（返回 `false`）无条件滑 trailing edge，保持 BUG-1342 的原始不变量。

纵向滚轮主路径（`axis != 'horizontal'`）短路在闸门之前，行为零变化。

- **[x] ① 已修复** — `hibiki/lib/src/reader/reader_pagination_scripts.dart`（闸门契约）
  + `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart`（传 `canTurnPage`）
- **[x] ② 已加自动化测试** —
  `hibiki/test/reader/reader_paged_wheel_gesture_behavior_test.dart`：复刻
  handler 的真实判定顺序（闸门 → `_paginate` in-flight 丢弃）跑整段惯性时间线，
  断言「换章加载覆盖惯性开头时仍恰好翻一页」（修复前为 0）与「整段被吞后闸门不留 token」；
  `hibiki/test/reader/reader_mouse_paging_boundary_guard_static_test.dart`：钉死
  handler 必须把 `canTurnPage: !_paginationInFlight` 交给闸门。
  变异实测：把 `_lastTickAt = now` 改回无条件写 ⇒ 两条新用例红；
  把 `canTurnPage: !_paginationInFlight` 改成 `canTurnPage: true` ⇒ 静态守卫红。

### 备注

- 阅读器页含真实 `InAppWebView` 平台视图，`onWheelPaginate` handler 注册在
  `onWebViewCreated` 里，widget 测试无法挂载出该回调 ⇒ **未做 widget 行为级复现**，
  测试落在「闸门 token 语义 + handler 判定顺序复刻」这一最强可落地层。
- 同一条 TODO 的第 ③ 项（`axis == 'horizontal'` 无 pointer-type 区分 ⇒ 横向滚轮鼠标 /
  Shift+滚轮只翻 1 页）**本轮未动**：那是产品取舍不是 bug，且与本修复无耦合。
