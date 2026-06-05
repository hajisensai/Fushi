# 阅读器焦点面（focus surface）三项修复 实现计划

> 用户报告（2026-06-04，手柄/键盘场景）：
> - **A（BUG-019）**：焦点在阅读区时，按「下」回不去底栏，反而翻页。
> - **B（BUG-020）**：歌词模式应能查词（手柄/键盘无 caret → 焦点消失、无法查词；触摸查词本身正常）。
> - **C（BUG-018）**：歌词模式「自动音频跟随」开关无效。
>
> 注：BUG-015/016/017 已被并发 agent 占用（外观焦点几何 / 同步按钮可达 / 歌词当前行 CSS 溢出），与本三项不同。

**Goal:** 让 caret/焦点面模型覆盖所有阅读面（阅读正文 ↔ 底栏、歌词页、弹窗），相邻层晋升通路完整；歌词跟随开关真生效。

**根因（均在 `reader_hibiki_page.dart`，B/C 另涉 `lyrics_mode_html.dart`）：**
- A：caret `move('down')` 在页边返回 `pageForward`，Dart 直接 `_paginate` 翻页且无「晋升底栏」通路；caret 未激活的键盘路径也缺「下→底栏」（手柄路径 3608 有、键盘没有）。
- B：歌词页只注入 `ReaderSelectionScripts.source()`，未注入 `ReaderCaretScripts.source()` → `_enterCaret` 在歌词页 `window.hoshiCaret` undefined → 进不了 caret。注入后歌词页无 `window.hoshiReader` → hoshiCaret 走 popup 几何模式（上下在行间跳），lookup → `onTextSelected` → 已实现的 `_handleTextSelected` 歌词分支。
- C：`_onCueChanged` 歌词分支（2316-2330）无条件 `__lyricsSetCue(idx)`，从不读 `followAudio.value`；非歌词路径靠 `shouldRevealCurrentCue`（controller 内已门控 followAudio）。

**确认的 UX：** A=候选①（Down 不翻页；到可视底边再按 Down 晋升底栏；翻页留给 Left/Right 或 LB/RB）。B=手柄/键盘走 hoshiCaret 复用。C=关跟随只停自动滚动、仍更新当前句高亮。

**顺序：** C（最小、纯可测）→ A（中、抽纯函数测）→ B（中、注入 hoshiCaret，需设备复测）。各自 commit + 登记 BUG + 测试。完成后 opus code-review。并发 agent 在动 develop（含 lyrics/focus 区域），合并回 develop 时注意 `lyrics_mode_html.dart`/`docs/BUGS.md` 冲突。
