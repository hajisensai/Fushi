## BUG-169 · 阅读器滚轮/翻页有时一次翻两页（misaligned scroll 经 round 跳页）
- **报告**：2026-06-11（用户：滚动可能会翻两页）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/reader/reader_pagination_scripts.dart` 的 JS `paginate()`（旧 forward `Math.round((currentScroll + columnPitch) / columnPitch) * columnPitch`，旧 line ~1078）。
- **[x] ① 已修复** — commit 见下方「修复提交」。
- **[x] ② 已加自动化测试** — `hibiki/test/reader/reader_paginate_step_test.dart`（纯函数影子）+ `hibiki/test/reader/reader_paginate_js_guard_static_test.dart`（JS 源码守卫）。

### 根因
`window.hoshiReader.paginate(direction)` 从 `getPagePosition()` 读到的 `currentScroll` 出发计算下一页：

```
// forward（旧）
targetForward = Math.round((currentScroll + columnPitch) / columnPitch) * columnPitch;
```

`Math.round((cur + pitch)/pitch)` 恒等于 `Math.round(cur/pitch) + 1`。当 `currentScroll` **未对齐到整页**
（落在两页之间）时——`registerSnapScroll` 的 snap 监听器是 `{passive:true}` 的 `scroll` 事件回调，在布局
之后异步跑，且 `columnPitch = pageSize + columnGap` 在不同 `getScrollContext()` 调用间会因 `clientWidth` /
`columnGap` 的分数像素而微变——`Math.round(cur/pitch)` 会把**视觉上的当前页 N** 舍入成 **N+1**，于是
forward 落到 `(N+2)*pitch` = **一次跳 2 页**。backward 对称（`round((cur-pitch)/pitch)`）会卡在原地或跳回。

附带：旧的边界 guard `(currentScroll + columnPitch) <= (maxAlignedScroll + 1)` 同样从错位的 `currentScroll`
出发，在「末页前一页 + cur 错位」时会误判已到边界、提前返回 `"limit"`。

### 修复（根因，非补丁）
把翻页从「当前页边界整页步进」重写，消除「错位」特例（floor/ceil 在对齐时与旧实现等价，错位时永远只走一页）：

- forward → `Math.floor(currentScroll / pitch) + 1` 的整页边界（严格在 cur 之后）；
- backward → `Math.ceil(currentScroll / pitch) - 1` 的整页边界（严格在 cur 之前）。

先算 target → clamp 到 `[minScroll, maxScroll]` → 用「clamp 后的 target 与 cur 的方向性比较」判定是否真翻页，
首/末页判定与步长计算共用同一个 target，不再有 guard 与步长各算一套的错位漏洞。

新增纯 Dart 影子 `ReaderPaginationScripts.resolvePaginateStepForTesting`（返回 `ReaderPageStep{scrolled,
targetScroll}`），与 JS 同算法，供单测覆盖（headless WebView 不可用，按项目测试范式）。

### 测试
- `test/reader/reader_paginate_step_test.dart`：对齐时单页步进 / 错位时不跳 2 页（核心回归断言：cur=2600,
  pitch=1000 → forward 必须落 3000 而非 4000；backward 必须落 2000）/ 首末页 limit / clamp。撤掉修复改回
  `round((cur±pitch)/pitch)` 影子会让「不跳 2 页」用例变红。
- `test/reader/reader_paginate_js_guard_static_test.dart`：扫 JS 源码，锁死 `paginate` 用 `Math.floor(...)+1` /
  `Math.ceil(...)-1`，且不再含 `Math.round((currentScroll + context.columnPitch)...)`。

### 备注
- 修了分页（paginated）模式的滚轮/键盘/手柄/音量键翻页（都汇聚到 `_paginate` → JS `paginate`），连续
  （continuous）模式不走 paginate 整页步进、不受影响。
- reader/WebView 类修复需**设备肉眼复测**原始失败路径（滚轮快速连滚、字号/主题切换后立即翻页、竖排/横排、
  首末页边界）——本轮纯函数 + 源码守卫 + analyze 全绿，真机复测待用户/集成环节。
