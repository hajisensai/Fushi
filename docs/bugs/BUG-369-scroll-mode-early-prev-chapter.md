## BUG-369 · 滚动模式向上滚未到章首就提前切上一章
- **报告**：2026-06-21（用户：滚动模式往上拉，还没到章节开头就跳到上一章）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` 滚动模式滚轮监听器（`wheel`，~2208/~2235）：
  - 跨章边界判定 `atStart = root.scrollTop <= 2`（竖排 `Math.abs(root.scrollLeft) <= 2`）是**单次瞬时**几何读数，命中即 `onBoundarySwipe('backward')` → `_handlePageTurnLimit('backward')`（`navigation.part.dart` ~501）→ `_navigateToChapter(prev, progress:0.99)`，Dart 端只透传不复核。
  - 向上快速回滚时，浏览器原生惯性（横排放行原生滚动）/ 竖排 rAF 缓动（TODO-629 的 `_vScrollTarget`/`_vScrollEaseStep`）把 scrollTop/scrollLeft **异步**滑向 0；连发的 wheel 事件会在「内容尚未真正贴住章首、仍在滑动」的某一帧擦到 `<=2` → 提前误判到顶 → 还没到章首就切上一章。
  - 不对称根因（向下正常）：`atEnd = scrollTop+innerHeight >= scrollHeight-2` 是**位置相对**判定，要滚满整章才命中，惯性几像素抖动可忽略；`atStart` 是**绝对零点**判定，而 0 恰是惯性/缓动的天然收敛终点，回滚必经并反复擦过 → 只有向上提前触发。
- **[x] ① 已修复** — 跨章边界改 **arm-then-fire 二次确认**（对齐分页模式 BUG-240「重建后仍翻不动才回 limit」范式）：`reader_hibiki_page.dart` wheel 监听器新增 `_wheelBoundaryArmed` 状态——同方向第一次到边界只「武装」不跨章（吸收惯性/缓动擦边的单次瞬态，仍 `preventDefault` 压住越界滚动不打断手感），同方向第二次到边界才真正 `onBoundarySwipe` 跨章；未到边界 / 方向反转即解除/改写武装。用户「滚到章首后再滚一下」才跨章（与移动端心智一致）。提交于分支 `todo-629-656-reader-flip`（合并后取并入 develop 的实际哈希）。
- **[x] ② 已加自动化测试** —
  - 纯函数 `ReaderPaginationScripts.continuousWheelBoundaryEmit`（`reader_pagination_scripts.dart`）+ 单测 `hibiki/test/reader/continuous_wheel_boundary_confirm_test.dart`（首次只武装、二次才跨章、未到边界解武装、方向反转改武装、**惯性单帧擦边永不跨章**回归场景）。
  - 源码守卫 `hibiki/test/reader/reader_mouse_paging_boundary_guard_static_test.dart`（wheel 监听器须经 `_wheelBoundaryArmed` 武装态、二次确认才 `onBoundarySwipe`、atStart/atEnd 几何不变）。红→绿已验（撤修复 → 守卫红 + 立即跨章）。
- **备注**：本修复**只动滚轮路径**（race 实际所在）。触摸/指针边界 IIFE（`reader_pagination_scripts.dart` `_bEnd` ~2167 `atTop = scrollTop<=2`）是离散 swipe，`touchend` 读已 settle 的位置、无惯性同步读穿，故未改（改它会改动已发布的 touch swipe-to-cross 手势）。UX 影响：**向下到底跨下一章现在也需「到底后再滚一下」二次确认**（对称化、消除特例），属轻微行为变化，若 PM 认为向下应保持单次即跨章可改为只对 backward 二次确认。**需真机复测**：滚动模式横排+竖排向上回滚到章首不提前跨章、到章首后再滚能跨上一章、向下到底跨下一章。

## 复发与真根因修正（2026-06-21 第二轮，用户：触摸仍提前跨章 + 滚轮又滚不动）

- **上次 arm-then-fire 未命中真根因**：二次确认只加在**滚轮路径**（`webview.part.dart` wheel 监听器）。用户是 Android 真机，跨章实际走**触摸路径** `_bEnd`（`reader_pagination_scripts.dart` 边界手势 IIFE，touchend/pointerup 都调它），该路径**一行没改**，仍单次瞬时 `atTop = scrollTop<=2` 命中即 `onBoundarySwipe('backward')`，无任何二次确认 → 对用户原始的「没到章首就跨章」根本无效。
- **arm-then-fire 自身引入回归（用户报「滚轮又滚不动」）**：经对抗式验证，它**不压中部滚动**（中部 `boundaryDir` 恒 null，必放行原生滚动），但到真实章末/章首时「第一格滚轮只武装 + `preventDefault`、既不滚也不翻」会被感知为「滚了没反应」；**向下到章末也对称卡一格**。
- **结构性根因更早（TODO-627 `64244e88f`）**：给滚轮加跨章通道时用**瞬时几何 `scrollTop<=2` / `scrollHeight` 读数**判「到边界」。短章节（内容≤一屏，`scrollHeight≈innerHeight`）时 `atStart` 与 `atEnd` 同时为真、图片未撑开时 `scrollHeight` 偏小 → 在**非真实边界**误判到边界 → 一滚就翻页/推不动。arm-then-fire 是其缓解者（两格才翻），非元凶；**回退它会复活本 BUG-369（向上提前换章 + 丢失阅读位置），净负，不回退**。
- **本轮只加诊断日志（`[xchapter]`，零行为变化）**，供真机一次复现锁定到底走哪条路径、什么几何值触发：
  - JS `_bEnd`：加 `src`（touch/pointer）入参 + 打印 dx/dy/scrollTop/scrollLeft/innerH/scrollH/dir（`reader_pagination_scripts.dart`）。
  - JS wheel：仅边界附近打印几何 + armed 状态（对照组，`webview.part.dart`）。
  - Dart `onBoundarySwipe` handler + `_handlePageTurnLimit`：打印 dir + chapter（`webview.part.dart` / `navigation.part.dart`）。
  - 守卫 `hibiki/test/reader/diagnostic_logging_guard_test.dart` 锁这些埋点不被回归删。
- **根本修法（待真机取证 + 用户确认后实施）**：跨章判定的真正特例是「用瞬时坐标阈值 `<=2` 判到边界」。正解换成「**先按滚动量试着滚，真的滚不动（位移≈0）才跨章**」——复用键盘翻页 `paginate`（`reader_pagination_scripts.dart` ~1973，先 `scrollBy` 再比较 before/after 的 `moved?"scrolled":"limit"`）已验证的范式，**滚轮/触摸/键盘三路径统一**：还能滚就绝不跨章（根除短章误翻 + 图片未撑开误判 + 触摸瞬时误判），到真边界自然跨章（去掉 arm-then-fire 的卡顿），且不复活本 BUG。唯一实现摩擦是竖排 rAF 缓动要与「试滚」协调，必须真机验证。
- **[x] 根本修法已落地（commit `5c6dc689f`，build +146，未真机验证）**：跨章判据全面改为「内容真的滚不动」——
  - 触摸/指针 `_bEnd`：记 touchstart 手势起点 `downSPos`，跨章要求**手势起点已在边界**（纯函数 `touchBoundaryCrossDir`），消除从章中滚到边界的瞬态误跨。
  - 滚轮 wheel：arm/cross 改判「内容真滚不动」——横排相邻 wheel 事件 scrollTop 无变化、竖排 rAF 投影 `target` 被 clamp 卡死（纯函数 `wheelBoundaryStuckDir` + 既有 arm-then-fire 二次确认），删 `atStart/atEnd` 瞬时几何，消除短章误翻 + 边界卡顿。
  - 键盘 `paginate` 已是试滚范式，不动。
  - 测试：`hibiki/test/reader/scroll_cross_chapter_try_scroll_test.dart`（纯函数 + JS 接线守卫）+ 更新 `reader_mouse_paging_boundary_guard_static_test.dart` / `reader_image_metrics_invalidate_guard_static_test.dart`。analyze 0、test/reader 562 绿、test/pages 1165 绿。
  - **待真机验证**：竖排 rAF 协调 + 横排 trackpad 高频 momentum 的 stuck 采样时机（见 `docs/superpowers/plans/2026-06-21-scroll-cross-chapter-try-scroll.md` 风险项）。横排普通鼠标滚轮（离散 notch）已逻辑稳健。
