# 歌词模式行级焦点查词 — 设计文档

- 日期：2026-06-05
- 状态：设计已确认，待写实现计划
- 关联：BUG/记忆 `Reader focus-surface fixes`（B 项当初 deferred：大歌词复用 hoshiCaret 性能炸，需专用行级 caret）

## 1. 背景与问题

有声书「歌词模式」（`LyricsModeHtml`，独立 HTML 文档）当前**只支持点击/触摸查词**：点任意 cue 行 → `window.hoshiSelection.selectText(x, y, 400)`（`lyrics_mode_html.dart:186-211`）。

普通分页阅读器有字级焦点 caret（`window.hoshiCaret` + `ReaderCaretRouter`，A/Enter 查词、方向键逐字/行移动），但歌词模式**没有**：

- 歌词文档只注入 `ReaderSelectionScripts`（`hoshiSelection`），**不注入** `hoshiReader` / `hoshiCaret`（`lyrics_mode_html.dart:36`）。
- `hoshiCaret` 几乎所有行为按 `window.hoshiReader` 分支，且其 `_collectVisibleStops` 对**全文每个字符**调用 `_charRect`（强制 reflow）做可见性测试（`reader_caret_scripts.dart:448-486`）。歌词文档可长达整本书的 cue，直接复用会卡——这是当初 deferred 的根因。

用户诉求：**键盘/手柄在歌词模式也能逐词焦点查词**。

## 2. 需求确认（已与用户敲定）

| 维度 | 选择 |
|---|---|
| 导航模型 | 上下跳 cue 行 + 左右逐字移动焦点；A/Enter 查词 |
| 与播放联动 | 激活 caret 时**暂停**播放自动滚动（跟随）；高亮仍更新；退出恢复跟随 |
| 复用策略 | 写歌词**专用行级 caret**，不复用 `hoshiCaret` |
| 进入键 | 沿用 A/Enter（手柄 A）进入，落在当前播放行；不抢现有方向键快捷 |
| JS 落点 | 新建 `reader_lyrics_caret_scripts.dart`，与 `reader_caret_scripts.dart` 并列 |

## 3. 架构总览

新增轻量级 JS `window.hoshiLyricsCaret`，公开与 `hoshiCaret` 同名的最小 API
（`enter/exit/move/activate/lookup/refresh/init/scrollPage`）。Dart 侧不重写输入路由，
只在已有 `_caret*` 方法里加「lyrics 分支」选择该 JS object。

关键不变式：
- **输入路由零改动**：`ReaderCaretRouter`（up/down/left/right/activate/dismiss 映射）原样复用，现有单测不动。`上下=行、左右=字` 的语义解析放在 JS caret 内（与阅读器把书写模式解析放 JS 同理）。
- **stop 范围限定在当前可见 cue 行内**：cue 已是带 `data-cue-index` 的离散 div，行间移动是索引加减 + 复用 `scrollToCenter`，复杂度 O(可见行) 而非 O(全文字符)。
- **不破坏**：caret 未激活时歌词模式所有现有行为（点击查词、快捷键、播放跟随滚动）原样保留；只有进入 caret 才改变。

## 4. 各单元职责

### 4.1 `hoshiLyricsCaret`（新 JS，`reader/reader_lyrics_caret_scripts.dart`）

| 方法 | 行为 |
|---|---|
| `init({color, insetTop, insetBottom})` | 配置焦点环色（Dart 传 `_caretRingColorCss()`）与视口 inset |
| `enter()` | 在当前播放 cue（`_currentIdx`，无则首个可见 cue）行首第一个可停字符落焦点，画环；返回 `{ok, rect}` |
| `exit()` | 隐藏环、置 inactive、清跟随抑制标志 |
| `move('up'/'down')` | 跳到 `data-cue-index ± 1` 的 cue，落行首字符，`scrollToCenter` 居中该行；越界 `blocked` |
| `move('left'/'right')` | 在当前 cue 文本节点内逐字步进（复用 `hoshiSelection.createWalker` 拒振假名）；行内到边时 `blocked`（不跳行——跳行交给上下） |
| `lookup()` / `activate()` | 先设 `window.__lyricsCueContext = {textFragmentId, cueIndex}`（当前 cue），再 `hoshiSelection.selectFromPosition(node, offset, 400)`；返回是否命中 |
| `refresh()` | relayout 后重测环；节点脱离则重锚当前 cue |
| `scrollPage(forward)` | LB/RB：按视口比例滚动 + 重锚到新可见行（歌词是连续滚动文档，非分页） |

设计要点：
- caret 内部状态 `{active, cueIndex, node, offset}`；焦点环复用 `hoshiCaret` 同款固定定位 ring 实现（可在新文件内独立实现一份精简版，避免耦合 reader 专属逻辑）。
- 查词管线**完全复用点击路径**：设 `__lyricsCueContext` 后调 `selectFromPosition`，下游 `onTextSelected` → 词典浮层、收藏星、句子上下文与点击一致（`reader_hibiki_page.dart:2442-2449` 的 `_lookupSectionIndex` 依赖 `_lookupCue`，由 `__lyricsCueContext` 经现有回路填充）。

### 4.2 播放跟随抑制（`lyrics_mode_html.dart` 的 `setCue`）

`setCue(index)` 当前做「换高亮 class + `scrollToCenter`」（`lyrics_mode_html.dart:165-180`）。

改动：新增 `window.__lyricsCaretActive` 标志。`setCue` 为真时**只换 class，不调 `scrollToCenter`**——播放推进继续更新当前句高亮，但不把屏幕从用户正读的行拽走。Dart 在 enter/exit 时置/清该标志。

### 4.3 Dart 侧（`reader_hibiki_page.dart`）

- `CaretSurface` 枚举加 `lyrics`（与 `none`/`reader`/`popup` 并列）。
- 注入：歌词 HTML 加载时一并注入 `ReaderLyricsCaretScripts.source()` + `initInvocation(...)`（镜像 reader 对 `ReaderCaretScripts` 的注入，`reader_hibiki_page.dart:1537-1542`）。
- `_enterCaret()`：`_lyricsMode` 时叩 `hoshiLyricsCaret.enter()`，成功则 `_caretSurface = CaretSurface.lyrics` 并置 `__lyricsCaretActive = true`。
- `_caretMove / _caretActivate / _caretLookup / _caretScrollPage / _caretExit / _caretRefresh` 等：加 `CaretSurface.lyrics` 分支，把 JS object 从 `window.hoshiCaret` 换成 `window.hoshiLyricsCaret`（其余逻辑不变）。
- `_caretExit`（lyrics 分支）：清 `__lyricsCaretActive`，恢复跟随。

## 5. 交互与边界

- **进入**：歌词模式 + caret 未激活 + 书/WebView 持焦 → A/Enter（手柄 A）进入 caret，落当前播放行。沿用现有 `ReaderCaretRouter.isEnterTrigger*`。
- **激活时**：方向键/D-pad 归 caret；A/Enter 查词；B/Esc 退出（沿用现有 `_caretDismissOrExit` 对非 popup surface 的处理）。
- **inactive 不变**：方向键快捷（音量键句子导航、播放/暂停、seek）、点击查词、跟随滚动原样保留。
- **退出书籍/切歌词模式**：`_lyricsMode` 翻转或页面销毁时，caret surface 归 `none`、清标志（沿用现有 `_lyricsMode` gate，如 `reader_hibiki_page.dart:600-601`）。

## 6. 测试策略（最强可落地层）

1. **生成/字符串测试**：断言 `ReaderLyricsCaretScripts.source()` 含行级 `move`（up/down 跳 cue）、逐字 step（left/right）、`__lyricsCueContext` 设值、`scrollPage`；断言 `LyricsModeHtml.generate(...)` 的 `setCue` 含 `__lyricsCaretActive` 抑制分支且注入了 lyrics caret。
2. **源码扫描守卫**：`CaretSurface` 含 `lyrics`；`_enterCaret` 在 `_lyricsMode` 走 lyrics 分支；各 `_caret*` 有 lyrics 分支。
3. **真机焦点驱动集成测试**：按项目惯例（`FocusDriver` / `sendKeyEvent`，禁 tap/坐标），键盘 + 手柄逐字查词 + 上下跳行 + 查词命中词典浮层，三端可跑。**设备复测留给用户/指定设备**。

## 7. 影响范围 / 风险

- 改动文件：`reader/reader_lyrics_caret_scripts.dart`（新）、`media/audiobook/lyrics_mode_html.dart`（setCue 抑制 + 注入）、`pages/implementations/reader_hibiki_page.dart`（surface 枚举 + `_caret*` lyrics 分支 + 注入）。
- 风险点：
  - `_enterCaret` 的 `!_readerContentReady` 守卫在歌词模式须为真——歌词 HTML 加载进同一 `_controller`，须确认就绪标志在歌词文档同样置位（实现期验证）。
  - 焦点环固定定位层须在歌词文档生效（歌词 body 有 `overflow-x:hidden` + 大 padding，ring 用 `position:fixed` 不受影响）。
  - 跟随抑制不能影响**退出 caret 后**的首次 cue 推进——退出须立即恢复并重新居中当前播放行。
- 向后兼容：未激活路径零改动；新增 surface 与新 JS object 互不干扰现有 reader/popup caret。

## 8. 非目标（YAGNI）

- 不做歌词模式的「整页分页 caret」——歌词是连续滚动文档，沿用滚动语义即可。
- 不改 `ReaderCaretRouter` 映射、不动 reader/popup caret 现有逻辑。
- 不新增按方向键直接唤起 caret 的入口（避免与现有方向键快捷冲突）。
