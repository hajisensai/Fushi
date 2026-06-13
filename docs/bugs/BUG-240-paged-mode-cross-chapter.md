## BUG-240 · 分页模式未到章节末页就意外跨章

- **报告**：2026-06-13（TODO-290 ②：翻页模式会意外跨章；书：転生王女と天才令嬢の魔法革命）
- **真实性**：✅ 真 bug。沿真实代码路径定位到 limit 误判 → 跨章。
- **根因**：分页 `paginate()`（`hibiki/lib/src/reader/reader_pagination_scripts.dart:1141`）forward 时把目标页 clamp 到 `metrics.maxScroll`，若 `targetForward <= currentScroll + 1` 返回 `"limit"`；Dart 侧 `_paginate`（`reader_hibiki_page.dart:5488`）见 `!_didScroll` 即调 `_handlePageTurnLimit`（`reader_hibiki_page.dart:3948`）→ `_navigateToChapter(_currentChapter + 1)` 跨章。
  - `metrics.maxScroll = min(maxAlignedScroll, lastContentScroll)`（`reader_pagination_scripts.dart:1039`），其中 `lastContentScroll` 由 `getClientRects()` 测出的最后内容边缘推导。当 metrics 在某个 `columnPitch` 下构建后，字体/chrome-inset 变化让 `columnPitch` 漂移、或末列内容边缘被略微低估时，`metrics.maxScroll` 会**小于真实末页**。
  - 结果：用户其实还没到章节末页，`paginate` 却用陈旧/低估的 `maxScroll` 判 `"limit"` → 把「翻不动」误当「到章节边界」→ 提前跨章，跳过章尾内容。这是 limit 判据把「这一次没滚动」和「真到章节首/末页」两件事混为一谈。
- **[x] ① 已修复**：在 `paginate()` 即将返回 `"limit"` 前，强制 `buildPaginationMetrics()` **重建一次** metrics（用当前 settle 后的 `columnPitch`/真实滚动量重算 max/minScroll），并用重建后的几何重新判定步长；只有重建后仍翻不动（确实到章节首/末页）才回 `"limit"`。同时把末页判定锚到 `getScrollContext().maxScroll`（DOM 实时滚动上限，永不陈旧）派生的整页边界，给 1px 级测量噪声留容差，避免亚像素低估触发跨章。不破坏 BUG-169 的 `floor+1`/`ceil-1` 错位不跳页修复（步长公式不变，只在 limit 边缘多一道 settle 复核）。`reader_pagination_scripts.dart` paginate forward/backward limit 分支改动。
- **[x] ② 已加自动化测试**：
  - 纯函数 `ReaderPaginationScripts.shouldCrossChapterOnLimit`（把跨章触发条件抽成可测纯谓词：给定重建后的 currentScroll / pitch / metricsMax / trueMax，判定是否真到边界该跨章），单测 `hibiki/test/reader/paged_cross_chapter_limit_test.dart`（红→绿：未到真实末页时不跨章；真到末页才跨章；min/max clamp；pitch<=0）。
  - 源码守卫 `hibiki/test/reader/reader_paginate_js_guard_static_test.dart` 追加断言：JS limit 分支在跨章前重建 metrics 且用 `context.maxScroll` 作真末页复核（防回退）。
- **备注**：分页几何敏感，声明「修好了」前需真机/模拟器复测「快速连续翻到章尾不提前跨章」+「真到章末正常跨章」+「切字体/字号后翻页不跨章」三条路径；本轮到代码 + 单测层。
