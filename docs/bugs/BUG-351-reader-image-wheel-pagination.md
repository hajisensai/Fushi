## BUG-351 · PC阅读遇插画滚轮翻不了下一页
- **报告**：2026-06-20（用户：）TODO-627
- **真实性**：✅ 真 bug（两处独立根因，覆盖默认竖排分页 + 连续模式两情形）
- **[x] ① 已修复** — 见下「根因」与「修复」
- **[x] ② 已加自动化测试** — 纯函数影子 + 源码守卫（headless WebView 不可用）
- **备注**：commit 待填；真机待验（Windows 整页插画 EPUB）

### 根因（两处独立）

**A 分页模式（默认竖排分页 + 桌面滚轮翻页）— 图片晚 load 致 metrics 陈旧 + 落点卡死**

- `hibiki/lib/src/reader/reader_pagination_scripts.dart` `buildPaginationMetrics`
  （约 `:1133`）枚举 `img/svg/image/video/canvas` 用 `getBoundingClientRect()`，**图片
  未 decode 完时 rect 为 0×0 被 continue 跳过**，不计入 `lastContentEdge` →
  `metrics.maxScroll = min(maxAlignedScroll, lastContentScroll)` 漏掉图片所占的列 →
  偏小。
- 两处 `initialize` 的 `Promise.all(imagePromises).then(...)`（约 `:1526` 分页 /
  `:1873` 连续）在 `buildNodeOffsets()` 后**没有失效 `paginationMetrics`**（对照
  `updatePageSize` `:1497` / `reanchorAfterStyleChange` `:1529` 都 `paginationMetrics = null`）
  → 图片 decode 完成后缓存的低估 metrics 仍被 `paginate`（`this.paginationMetrics ||
  buildPaginationMetrics()`，约 `:1340`）沿用 → paginate 在图片页前就误判到末页 →
  `_handlePageTurnLimit` 跳过插画页跨章。
- 即便走 BUG-240 的 `_stepWithFreshMetrics` settle 复核（约 `:1311`），其 forward
  **落点** `dest = Math.min(targetF, Math.max(metrics.maxScroll, currentScroll))`
  在 metrics 低估、currentScroll 已停在被低估的「末页」时取 currentScroll →
  `setPagePosition` 不动却仍 `return "scrolled"` → 滚轮在插画页**既不翻页也不跨章**（卡死）。

**B 连续模式 — 滚轮无跨章通道**

- `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` 连续模式 wheel 监听器
  （约 `:2499`）：横排放行原生滚动、竖排把 delta 投影到横向 scrollBy，但**到章末/章首
  都没有回传 `onBoundarySwipe`** → 滚到底再滚没反应。触摸/指针有边界手势 IIFE
  （`reader_pagination_scripts.dart` 约 `:1925`，touch/pointer → `onBoundarySwipe`），
  唯独滚轮缺这条跨章通道。

### 修复

**A-1** 两处 `Promise.all(imagePromises).then` 块内 `buildNodeOffsets()` 后加
`window.hoshiReader.paginationMetrics = null;`（与 updatePageSize/reanchor 失效一致），
图片 decode 完成后强制下次 paginate 用纳入图片真实尺寸的几何重建。

**A-2** `_stepWithFreshMetrics` forward 落点改 `var dest = Math.min(targetF, maxF);`
（`maxF = max(metrics.maxScroll, trueMaxAligned)`，与跨章复核同一容差上界），消除低估
被 clamp 回 currentScroll 的卡死；落点仍不越过真实可滚整页边界。

**B** 连续模式 wheel 监听器：原生滚动已到该内容轴尽头（复用边界 IIFE 同款
`atStart/atEnd` 判定）时回传 `onBoundarySwipe`（复用 `_handlePageTurnLimit`），未到底
仍放行/投影正常滚动；统一手势纯谓词 `continuousWheelBoundaryDirection`。

### 测试（headless WebView 不可用 → 纯函数影子 + 源码守卫）

- `hibiki/test/reader/reader_paginate_step_test.dart`：新增 `resolveFreshStepForTesting`
  组——低估 metrics 时 forward 落点必须推进到真实整页边界（`scrolled=true` 且
  `targetScroll` > currentScroll），而非 clamp 回 currentScroll。
- `hibiki/test/reader/continuous_wheel_boundary_test.dart`（新建）：
  `continuousWheelBoundaryDirection` 横排/竖排到底跨章、未到底放行、零 delta 不触发。
- `hibiki/test/reader/reader_image_metrics_invalidate_guard_static_test.dart`（新建）：
  源码守卫锁两处 imagePromises 块含 `paginationMetrics = null`、`_stepWithFreshMetrics`
  落点用 `Math.min(targetF, maxF)`、连续 wheel 含 `onBoundarySwipe`。
- 全量 `flutter test test/reader/` 505 绿（含 BUG-169/239/240 守卫不回退）。
