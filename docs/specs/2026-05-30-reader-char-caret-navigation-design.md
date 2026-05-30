# 阅读器字级焦点导航（手柄 / Tab 进入书籍）— 设计规格

- 日期：2026-05-30
- 范围：`hibiki/lib/src/pages/implementations/reader_hibiki_page.dart` 主阅读器（Hoshi WebView），`hibiki/lib/src/reader/` 脚本层，`hibiki/lib/src/shortcuts/` 输入层。
- 状态：已确认设计（用户已就 3 个关键 UX 决策拍板）。

## 1. 目标

让手柄、键盘 Tab 等硬件输入能够「进入书籍正文」，并在书内以**字（单个可见字符）为粒度**移动焦点；在某个字上激活即触发该字所在词的词典查询。要求从根本上正确实现，不用「简单但不易维护」的临时方案。

非目标（本期不做）：歌词模式（独立 HTML）内的字级光标；触摸用户的光标态（触摸仍走现有坐标查词，与光标互不干扰）。

## 2. 关键约束与既有事实

- 书内文本由 `InAppWebView` 渲染的 EPUB DOM 承载。Flutter 焦点只能到 WebView 这个 widget；WebView 本身 `canRequestFocus=false`，按键全部被外层 `Focus.onKeyEvent`（`reader_hibiki_page.dart:967`）捕获，**不进入 DOM**。因此「书内字级焦点」必须由一个 **JS 层光标**承载，Flutter 侧只负责状态机与按键路由。
- 现有查词链路纯坐标驱动：JS `hoshiSelection.getCharacterAtPoint(x,y)` → `selectText(x,y)` → `onTextSelected` handler → `_handleTextSelected` → 词典/高亮/Anki。光标查词必须**复用同一条链路**，不得另起炉灶。
- 默认排版 `vertical-rl`（日文竖排），存在 `hoshiReader.isVertical()`；存在分页 / 连续滚动两种模式。方向移动必须区分横竖排与两种模式。
- 输入系统：`HibikiShortcutRegistry` 按 scope 顺序解析（reader → audiobook）。reader scope 现有：翻页(方向键/LB/RB)、ToggleChrome(Esc/Y)、DismissDict(Esc/B)、ToggleBookmark(Ctrl+D/X)。gamepad A 当前解析到 audiobookPlayPause。Tab 未注册。

## 3. 用户已确认的 3 个决策

1. **手柄进入键 = X**。X 原为「书签」的手柄绑定；为不丢失「手柄加书签」能力，把书签的 gamepad 绑定迁到未占用的 **R3 (thumbRight)**，X 专用于「切换字级光标模式」。
2. **Tab = 逐字前进**。焦点不在书内时按 Tab → 进入并落到当前页首个可见字；之后 Tab = 下一字、Shift+Tab = 上一字；走到书末/书首再 Tab/Shift+Tab → 退出书籍，把焦点交还框架（chrome 等）。Esc/B 可随时快速退出。
3. **全支持**：横排 + 竖排、分页 + 连续滚动。

## 4. 核心数据结构：JS 层「字光标」`window.hoshiCaret`

新文件 `hibiki/lib/src/reader/reader_caret_scripts.dart`，类 `ReaderCaretScripts`，与 `ReaderSelectionScripts` / `ReaderPaginationScripts` 同构（`source()` 返回 JS、静态方法返回 invocation 字符串、静态方法解析返回值）。注入位置：`_buildReaderSetupScript`（与 selection/pagination JS 并列）。

光标状态：
- `active: bool`
- `node, offset`：当前聚焦字符（单个可见字形；跳过 furigana 的 rt/rp；跳过纯空白/换行；保留标点/CJK/假名/拉丁字形）。
- 一个绝对定位的焦点环覆盖层 `#hoshi-caret-ring`（`position: fixed; pointer-events:none`），每次移动后按当前字 `getBoundingClientRect()` 重新定位。**不切割 DOM 节点**（不 wrap，避免 offset 失效）。环样式用强对比 accent，由 Dart 经 setup script 注入颜色。

JS API（全部经 `evaluateJavascript` 同步取返回值，除查词复用 push handler）：
- `enter(atEnd)`：激活；把光标放到当前页**视口内**第一个（`atEnd` 时最后一个）可见字；渲染环；返回 `{ok, rect}`。「视口内」= 字 rect 与 `[0,innerWidth]x[insetTop, innerHeight-insetBottom]` 相交。
- `exit()`：清环，`active=false`。
- `move(dir)`：`dir ∈ {forward,backward,lineNext,linePrev, up,down,left,right}`。物理方向(up/down/left/right)由 JS 用 `isVertical()` 映射成逻辑方向（单一真相在 JS，因为它握有 computed style）：
  - 横排：right=forward,left=backward,down=lineNext,up=linePrev。
  - 竖排 vertical-rl：down=forward,up=backward,left=lineNext,right=linePrev。
  返回 `{status, rect}`，`status ∈ {moved, pageForward, pageBackward, blocked}`。
  - 字符移动 forward/backward：DOM 阅读序前后挪一个可见字。
  - 换行 lineNext/linePrev：几何最近邻——横排取上下相邻行band内 x 最近者；竖排取左右相邻列内 y 最近者（笨而清晰的全字遍历最近邻）。
  - **越过当前页边界**：分页模式 → 返回 `pageForward/pageBackward`，由 Dart 翻页后调用 `reanchor`；连续滚动模式 → JS 自己 `scrollIntoView` 把目标字带入视口并返回 `moved`（连续模式没有「页」，滚动归 JS 这个 DOM 真相所有者）。
  - 无更多字（书末/书首）→ `blocked`（Dart 据此决定 Tab 退出书籍）。
- `reanchor(edge)`：翻页/重排后把光标放到新页进入边（`edge ∈ {forward→页首, backward→页末}`）的第一个可见字。
- `lookup()`：在 `(node,offset)` 处**直接调用**重构后的选区核心 `hoshiSelection.selectFromPosition(node, offset, maxLength)`，触发既有 `onTextSelected`，进入既有词典管线。
- `refresh()`：重排（字号/chrome/写作模式变化）后重新测量环位置；若光标 node 已脱离文档则 `reanchor(forward)`。
- `isActive()`：bool。

## 5. 选区脚本重构（消除特殊情况）

`reader_selection_scripts.dart` 的 `selectText(x,y,maxLength)` 拆成两段：
- `selectFromPosition(node, offset, maxLength)`：现有从 `(node,offset)` 起向后收词、算 sentence、算 normalizedOffset/Length、回调 `onTextSelected` 的**全部逻辑**移到这里。
- `selectText(x,y,maxLength)`：仅负责 `getCharacterAtPoint(x,y)` 命中、a 标签/重复点击/清除等坐标特有分支，命中后委托 `selectFromPosition`。

这样坐标查词与光标查词共用同一核心——「好品味」：光标只是产出一个 `(node,offset)` 喂进同一管线，没有第二套查词代码。

## 6. Flutter 侧：状态机与按键路由

`reader_hibiki_page.dart` 增加：
- 状态 `bool _caretActive`（+ 必要的串行化，复用既有 re-anchor 串行机制以避免与翻页/重排竞态）。
- 方法：`_enterCaret({bool atEnd})` / `_exitCaret()` / `_caretMovePhysical(TraversalDirection)` / `_caretTab({bool backward})` / `_caretLookup()` / `_caretReanchor(...)` / `_caretRefresh()`。
- 新增一个 reader scope action `readerCaretToggle`：键盘默认空（Tab 走专门处理），gamepad 默认 **X**。`readerToggleBookmark` 的 gamepad 改为 **R3**，键盘保留 Ctrl+D。

路由策略（在 `_handleKeyEvent` / `_handleGamepadButton` 内，**先于** registry 解析做上下文拦截）：
- `readerCaretToggle`(X) 命中 → 切换：未激活则 `_enterCaret()`，已激活则 `_exitCaret()`。两个平台路径（Android key / desktop intent）都解析到此 action。
- 当 `_caretActive == true`：
  - 方向键 / D-pad → `_caretMovePhysical(dir)`（physical 方向交给 JS 映射）；若 JS 返回 pageForward/pageBackward 则 `await _paginate(...)` 后 `reanchor`。
  - Tab → `_caretTab(backward:false)`；Shift+Tab → `_caretTab(backward:true)`。`_caretTab` 调 `move('forward'/'backward')`；返回 `blocked` 时 `_exitCaret()` 并把焦点交还框架（`focusInDirection`/`nextFocus`，使 Tab 自然移出书籍区）。
  - A(gameButtonA) / Enter → `_caretLookup()`，返回 handled（拦截在 audiobookPlayPause 之前）。
  - B(gameButtonB) / Esc → 若有词典弹窗先 DismissDict（保留光标）；否则 `_exitCaret()`（**不**冒泡到全局 pop，避免退出阅读器）。
  - LB/RB / PageUp/PageDown → 仍翻页（既有），翻页后 `reanchor` 让光标跟到新页。
- 当 `_caretActive == false`：
  - Tab（无修饰）→ `_enterCaret()`（落到首字）。Shift+Tab → 交给框架默认遍历（不强行进入）。
  - 其余维持现状（方向键翻页、A 播放/暂停、B 返回 等）。

物理→逻辑写作模式映射的**单一真相在 JS**；Dart 侧只做「physical 方向 + 状态门」路由，便于纯 Dart 单测。

## 7. 边界与交互

- 翻页（RB/LB/边界自动翻页）后必 `reanchor`，光标跟随当前页。
- 字号/chrome/写作模式变化 → 既有 re-anchor 串行链里调用 `caret.refresh()`，node 失效则重锚。
- 查词弹窗打开后**保留**光标；弹窗关闭（`_clearLookupState` 清选区高亮）不退出光标。
- 触摸点击与光标共存：触摸仍走坐标查词，不自动改变/退出光标（本期最小化）。
- 媒体关闭/页面 dispose：JS 随 WebView 销毁，Dart 仅重置 `_caretActive`。

## 8. 测试策略

- **纯 Dart 单测**：按键/状态机路由——给定 `_caretActive` + 输入键/按钮 → 期望调用的光标操作 / 是否 handled / 是否拦截在 registry 之前；以及 `readerCaretToggle` 绑定与书签迁到 R3 后的冲突检测（registry `hasGamepadConflict`）。把可纯测的路由抽成独立可测单元（参照 `GamepadFrameProcessor` 的做法）。
- **`flutter analyze` + `flutter test`** 全绿。
- **集成验证（真机/模拟器）**：按 `hibiki/CLAUDE.md` 阅读器改动必须在真实设备复测——竖排 + 横排、分页 + 连续，X 进入、方向键/Tab 逐字与换行、边界翻页、A 查词出弹窗。无可用设备时，按规则明确记录「验证缺口」，不写成已通过。

## 9. 涉及文件

- 新增 `hibiki/lib/src/reader/reader_caret_scripts.dart`
- 改 `hibiki/lib/src/reader/reader_selection_scripts.dart`（抽 `selectFromPosition`）
- 改 `hibiki/lib/src/shortcuts/shortcut_action.dart`（+`readerCaretToggle`）
- 改 `hibiki/lib/src/shortcuts/shortcut_defaults.dart`（X→caret，bookmark→R3）
- 改 `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart`（注入、handler、状态机、路由）
- 新增测试 `hibiki/test/shortcuts/` 与/或 `hibiki/test/reader/`
- 视情况更新 i18n（若新增设置项文案，用 `tool/i18n_sync.dart`）
