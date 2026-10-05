## BUG-2952 · 移动端划词后翻页，选择高亮与两端手柄留在新页面上

- **报告**：2026-10-05（用户：划词选中一段文字后上下翻页，选择的高亮条与两端手柄不消失，停在新页面上）
- **真实性**：✅ 真 bug —— **翻页路径从来没有清过选区**。`fushi/lib/src/reader/reader_pagination_scripts.dart` 里只有两处 `window.fushiSelection.clearSelection()`，但两处都挂在**有声书句子音频**的收口上（`applySentenceAudioCues` / `resetSentenceAudioCues`），与翻页无关；两个 shell 的 `paginate()`（**分页** shell / **连续** shell）都只做 `clearImageLateAnchor()`（放弃迟到图片重锚），从不碰选区。于是翻页后旧页面的 CSS highlight / wrapper（或 `CSS.highlights` 里的 `fushi-selection`）、两端手柄（`.fushi-sel-handle-*`）与浏览器原生 range 全部留在屏幕上 —— 它们描述的是**旧页面**的内容。
- **[x] ① 已修复**（根因修：把「换视口」统一成一个收口，在收口里清选区）——`fushi/lib/src/reader/reader_pagination_scripts.dart`：
  - 新增共享 `_clearSelectionOnViewportChange()`：调 `window.fushiSelection.clearSelection()`（清 app 自绘选区 + highlight / wrapper + 两端手柄 + 浏览器原生 range，并复位拖动锚点）。**拖选中途不打断**：`s.dragAnchor` 还在（手指没松）时直接返回 —— 那次视口变化是手势自身的一部分。
  - `noteUserScroll()`（用户亲手挪视口的既有收口：连续模式滚轮 / 触摸原生滚动 / 拖滚动条 / 方向键原生滚动 / 查词弹窗遮罩转发的滚动）追加调用 → 连续模式滚动一并覆盖。
  - 分页 shell `paginate()`：**两个方向**都在 `setPagePosition(...)` 之后调用 —— 只在真的翻页了（`"scrolled"`）的分支清；`"limit"` 早退不清（页面没换就不该丢选区）。
  - 连续 shell `paginate()`：在 `moved` 为真时调用。
  - **刻意不放在 Dart 的 `_paginate`**：JS 侧还有别的换视口入口（用户滚动、重锚、查词遮罩转发），收口放在 JS 一处才不会漏；Dart 侧 `_paginate` 只是其中一个调用者。
  - 与既有的 `applySentenceAudioCues` / `resetSentenceAudioCues` 里那两处清除**职责不同**：那两处服务有声书 cue，有 cue 才发生，翻页不经过它们 —— 这正是本 bug 能长期存在的原因。
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_pagination_viewport_selection_guard_test.dart`（源码契约）：换视口的三个入口（`noteUserScroll` / 分页 `paginate` 的两个方向 / 连续 `paginate`）都必须经 `_clearSelectionOnViewportChange`；该函数必须调 `clearSelection` 且在 `dragAnchor` 非空时早退；分页的清必须**在 `setPagePosition` 之后**（不能提前到 `"limit"` 早退路径上）；连续 shell 的清必须挂在 `moved` 判定上；并钉住「有声书 cue 的两处清除不是翻页清除」这一事实，避免以后被误当成已覆盖。
- **备注**：与 BUG-2951（拖动端点解析：字缝 / 行尾 / 行距 / 段间空白处手柄冻结）同属移动端划词一组，同一 PR 内提交；两者都只做移动端触屏路径，桌面鼠标走浏览器原生选区不受影响。
