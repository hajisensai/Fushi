## BUG-1797 · 阅读器页边距能点到相邻页的词查词（不可见却可命中）

- **报告**：2026-08-23（用户：在左右间距或上下间距有的时候可以点击到前一页和后一页的词来查词，但是那块明明没有显示）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/reader/reader_selection_scripts.dart:558`（`getCharacterAtPoint`，修复前）与 `fushi/lib/src/reader/reader_content_styles.dart:900-946`（`padding` + `clip-path` + `html::before` 覆盖条）。

### 根因

分页模式把整章内容排成**一根** multicol，靠移动 `scrollLeft` / `scrollTop` 看每一页。相邻页的列在几何上就**真实地落在 body 的 padding（页边距）带里** —— `body{overflow:hidden}` 只在 border-box 裁，裁不掉 padding 带**内**的东西。`reader_content_styles.dart:918-929` 的注释已经把这点写清楚了，遮住它的是两个**绘制期**机制：

- body 的 `clip-path: inset(...)`（`contentClipCss`，四边各等于 body 实际 padding）
- `html::before` 那条背景色不透明覆盖条（TODO-1285 的引擎无关兜底）

而查词/选词的命中测试是**布局期**的：`caretPositionFromPoint` 把任意落点 **clamp** 到最近字符（与 BUG-748 同一个 clamp），`getClientRects()` 返回的矩形完全无视 clip-path 和覆盖条。于是「看不见」和「点得到」用了两套互不相干的真相 —— 点页边距就查到了相邻页的词。横排时 turn 轴水平，泄露在左右间距；竖排时 turn 轴垂直，泄露在上下间距，与用户描述逐项对上。「有的时候」= 只有相邻列恰好滚进 padding 带、且落点在那个字形矩形 ±6px 容差内时才命中。

命中链上有三个入口都吃这个 clamp，不止最终确认那一处：

1. `getCharacterAtPoint` 的最终字符确认（`caretPositionFromPoint` 快路）
2. `getCaretRange` 第一遍「精确包含」逐字符扫描（快路失效时，BUG-765 / TODO-916 的路径）
3. `getCaretRange` 第二遍「最近字符 + 容差」兜底扫描

只堵第 1 处，页边距接缝上的点会从「查错词」变成「查不到词」（不可见字符赢下最近字符竞争后再被否决，正文内侧边缘出现一条死区），所以三处必须同源。

### 修复

判据从「找得到字符」改成「**这个字符可见吗**」，而不是给页边距加特例分支：

- 新增 `visibleContentBox()`：可见正文盒 = body 的 content box（border-box 内缩 **computed** padding，与 `contentClipCss` 逐项一致）∩ 视口。用 computed 值是为了让引擎去解析 `vh/vw/calc/var`，不在 JS 里重算一遍 CSS，也就不会跟 CSS 那侧漂移。三种布局零特例：分页下 body 是钉在视口帧上的 scroller，content box 恰等于 clip 出的可见区；连续模式 body 随内容滚动，与视口取交后滚出去的那截不会被误判成不可见；VN 模式 body padding 为 0，盒 == 整视口、判据近似恒真。
- 新增 `charRangeVisible(charRange, box)`：字形矩形与可见正文盒有正面积交集才算可见。跨在 clip 边界上、还露出半个的字符仍算可见（用户确实看得到，点它就该查得到）。拿不到盒时返回 `true` —— 守卫只拦**确证不可见**的字符，不在几何未知时误伤正常查词。
- 上述三处接入点全部过这一关；`box` 由 `getCharacterAtPoint` 一次算好沿链下传，逐字符兜底扫描才不会跑上千次 `getComputedStyle`（上千次强制 reflow）。

因为查词/选词的所有入口（`selectText` / `beginRangeSelection` / `updateRangeSelection` / `moveSelectionHandle` / `tapHasCharacter`）都走 `getCharacterAtPoint`，一处收口即全覆盖。

- **[x] ① 已修复** — `fushi/lib/src/reader/reader_selection_scripts.dart`（`visibleContentBox` / `charRangeVisible` + 三处接入）
- **[x] ② 已加自动化测试** — `fushi/test/reader/reader_padding_hit_leak_bug1797_test.dart`：不是源码扫描守卫，而是把生产的 `window.fushiSelection` 对象字面量抽出来在 node 里对着**真的复现 clamp 行为**的 fake DOM 跑 `getCharacterAtPoint`，8 个场景覆盖「页边距点不中相邻页字」「正文照常命中」「跨边界字仍可点」「零 padding 时守卫是 no-op」「caret API 失效时两条兜底扫描同样不泄露」「接缝上退让给本页最近可见字」。三个接入点逐个变异实测均转红（变异 A 的报错正是原 bug 复现：`got {text=隣頁, offset=0}`）。

### 备注

- 同根因的相邻缺陷（**本次未修**）：`fushi/lib/src/pages/implementations/reader_fushi/webview.part.dart:927` 的 `_fushiReaderMouseDragStartAllowed` 末行 `return !_fushiReaderCaretRangeAtPoint(...)` 同样吃 clamp —— 分页模式下页边距按下时 caret 照样 clamp 出一个字符，于是「不在字上才允许拖动翻页」恒为 false，鼠标左键拖动翻页（BUG-368）在页边距起手应该是失效的。改法是让它复用 `fushiSelection.getCharacterAtPoint` 这个同源判据，但需要真机复测鼠标拖动翻页，本轮不做，单独立项。
- 真机验证缺口：本次只做到 node 行为测试层，未在真机/模拟器上复测原始失败路径（用户已取消真机验证要求）。
