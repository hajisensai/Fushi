## BUG-284 · 音频跟随退化到章节粒度：位置保存把 -1 覆盖精确字符锚（TODO-375）
- **报告**：2026-06-15（用户：阅读器回归，"恢复回去"）
- **真实性**：✅ 真 bug。引入回归提交 `8d878f155 fix(reader): preserve vertical scroll position`。
  根因 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:4492`（`_persistPosition`）：
  该提交把 `charOffset: charOffset >= 0 ? charOffset : null` 改成直接 `charOffset: charOffset`。
  当 WebView 当帧算不出精确偏移（`getFirstVisibleCharOffset` 返 -1，重排 / 竖排边缘 /
  cue 派生位置常见）时，`_refreshProgress` / `_syncPositionFromWebViewProgress` /
  `_syncPositionFromCurrentCue` 把 -1 直接传进 `ReaderPositionRepository.save`
  （`packages/hibiki_audio/lib/src/audiobook/reader_position_repository.dart:25`），
  `charOffset != null` 分支写 `Value(-1)`，**覆盖同 section 既有精确字符锚**。
  此后恢复 / 有声书跨章重锚读回 -1 → 走 `charOffset<0` 回退到「章首进度分数」=
  章节粒度，不再逐句跟随（症状①）。原 `>=0?charOffset:null` 把同/跨 section 的取舍
  交给 repo.save（同 section `Value.absent()` 保留、跨 section `Value(-1)` 失效），正确。
- **[x] ① 已修复** — 还原 null 守卫 `charOffset: charOffset >= 0 ? charOffset : null`
  （`reader_hibiki_page.dart:_persistPosition`）。提交：见分支 todo-375-reader-regression。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/reader_hibiki_vertical_test.dart`
  源码守卫：断言 `_persistPosition` 含 `charOffset: charOffset >= 0 ? charOffset : null`
  且不含裸 `charOffset: charOffset,`（撤修复即红，正是 8d878f155 的回归形态）。
- **备注**：
  - 同源判定：症状①（音频跟随只到章节）确认即本 bug。
  - 症状②（章内翻页误跳章）：分页边界判定 `paginate` + `_handlePageTurnLimit` 经
    BUG-169/210/240 多轮加固（floor+1/ceil-1 错位不跳 2 页、settle 后 metrics 复核防
    低估提前跨章），HEAD 未见新回归；未在 8d878f155 触及。需真机复测确认是否仍现。
  - 症状③（连续模式翻不了页）：连续模式滚轮经 BUG-239/TODO-345 门控（横排放行原生、
    竖排显式横向 scrollBy），键盘 / 手柄走 `_paginate` 连续分支（8d878f155 已重加
    scrollBy，测试守卫在 `swipe_page_turn_no_animation_test.dart`）。HEAD 代码路径可
    翻页，未见 dead-path 回归。残留可疑点：连续模式触摸横向 swipe 仍经外层 `onSwipe`
    → `_paginate` scrollBy，与原生滚动可能轴向叠加（竖排连续）；此为手感问题，需真机
    复测确认是否即用户所指症状③。
