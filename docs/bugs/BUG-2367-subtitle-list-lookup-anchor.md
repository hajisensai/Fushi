## BUG-2367 · 字幕列表查词：词换行到第二排时被查词弹窗遮住

- **报告**：2026-09-09（用户：视频的字幕列表查词，如果查的词占了两排，查词弹窗会挡住第二排；附截图）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/video_subtitle_jump_panel.dart:449`（`subtitleListCharHitFromParagraph` 返回的 `charRect` 只是**被点那一个字**的盒）与同文件 `_buildRowText` 内 `hitAt` 的同款返回；该 rect 一路当查词浮层锚点传到 `fushi/lib/src/pages/implementations/video_fushi/lookup_favorite.part.dart:82`（`pushNestedPopup(selectionRect: charRect)`），最终喂给 `fushi/lib/src/pages/implementations/dictionary_popup_layer.dart:66` 的 `placeAboveBelow()`。
  - 浮层定位的不变式是 **BUG-098「绝不盖住被查词」**：只按锚点的 `top`/`bottom` 贴在它上方或下方。
  - 但**被查词的长度在推浮层时还不知道**——查询串恒是「被点字位 → 句末」（`subtitleLookupSpan`），真实匹配长度是引擎查完才回报的 `matchedRunes`。
  - 于是锚只有单个字：词被软换行拆到第二排时，第二排不在锚里，浮层贴在第一排下方就正好压住它。列表面板窄、行文本满宽，长句常年换行，这是常态不是边角。
- **[x] ① 已修复** — 锚改为「被点字位 → 句末」的字形盒并集（新增 `subtitleListLookupAnchorRect`，`video_subtitle_jump_panel.dart`）。匹配串恒是这段的前缀，锚**必然包含**被查词，不需要知道它多长，也不需要查完再挪浮层（挪＝肉眼可见的跳）。`SubtitleListCharHit` / `SubtitleListHit` 加 `anchorRect` 字段与既有 `charRect`（命中/去重语义）并存，tap / barrier 换词 / Shift-悬停 / 键盘查词四条入口统一改用 `anchorRect`。纵向只多让出被点字位之后那几行，横向不受影响（横排避让只读 top/bottom）。提交见下。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_list_lookup_anchor_test.dart`：① 纯函数并集跨行 + 不回头包含前面的行 + 越界；② widget 层在 360px 窄面板里真点一个换行句的第一排，把回调拿到的锚喂进真实 `calcPopupPosition`，断言浮层与「被点字位→句末」那段文字零垂直重叠（并先断言语料确实换了行，防空壳）。变异实测：把 tap 路径的锚改回 `charRect` 立即转红（锚底 109 < 需要的 126.5）。
- **备注**：画面底部字幕 overlay（`video_subtitle_overlay.dart`）同样传单字 rect，理论上同病；但底部字幕没有下方空间、浮层恒往上翻，压不到自己，本轮不动。
