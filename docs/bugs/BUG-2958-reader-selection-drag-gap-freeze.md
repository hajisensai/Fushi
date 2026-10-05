## BUG-2958 · 移动端 EPUB 拖选/拖手柄落到字缝·行尾·行距·段间空白就卡住

- **报告**：2026-10-05（用户：手机阅读器长按进选择后，拖动两端手柄到文字之间的空白、行尾或其它没有直接命中字符的位置，手柄停止移动、选择范围无法继续扩大或缩小；松手再拖有时仍过不去）
- **真实性**：✅ 真 bug —— 根因在 `fushi/lib/src/reader/reader_selection_scripts.dart` 的拖动端点解析：**唯一**入口是几何命中 `getSelectableCharacterAtPoint(x, y)`，它要求手指压在某字符的 client rect 上（先精确包含、再 ±6px 容差）。字缝（两端对齐撑开的空白）、行尾/行首空白（text-indent、伸缩空隙）、行距（line box 之外）、段间 margin 上没有任何字符矩形盖住手指 → `hit` 为 null →
  - `updateRangeSelection` 把端点**钉回锚点**（整段选区当场塌回锚点字，继续拖也长不出来）；
  - `moveSelectionHandle` **直接 return**（手柄视觉冻结）；
  松手再拖同样卡在这段空白上。这是**几何判据本身**的问题，不是容差不够大：把 ±6px 调大只是把卡住的位置推迟到下一个缝隙（文字之间的空白在两端对齐 / 行尾 / 行距里必然存在，宽度 > 12px 的缝隙很常见）。
- **[x] ① 已修复**（根因修：补一层真正的「坐标 -> 文本位置」解析，对齐 Android `TextView.getOffsetForPosition()` / Flutter `TextPainter.getPositionForOffset()` 语义）——`reader_selection_scripts.dart`：
  - 新增解析层（插在几何命中层与句子解析之间，只服务拖动入口）：
    `charRangeAt` / `charAxisBounds`（交叉轴·行内轴）/ `compareTextPosition` /
    `nativeCaretAtPoint`（①原生 caret 快路）/ `geometricCaretAtPoint`（②几何兜底）/
    `caretPositionAtPoint` / `normalizeEndpoint` / `caretHasVisibleNeighbour` /
    `spaceDelimitedWordBounds` / `selectionAnchorAtHit` /
    `resolveSelectionEndpoint`（拖动端点解析的唯一出口）。
  - **① 原生 caret API**：`document.caretPositionFromPoint(x, y)`（Chromium / Android WebView，Fushi Android 走的就是 Blink）→ 失败再试 `document.caretRangeFromPoint(x, y)`（WKWebView / 老 Blink）。两者都是「最近 caret」clamp 语义，落在行距/字缝/行尾会按最近行盒给出 DOM 文本位置 —— 正是本 bug 需要的 O(1) 解析。结果**只认文本节点**（BUG-765 的既有纪律：手柄 div / documentElement 的命中不可信），并复核相邻字符可见。
  - **② 几何兜底**：原生 API 缺失 / 命中被遮挡 / 结果不可见时，在 `elementFromPoint` 命中的元素所在**文本块**里逐字符扫描：**交叉轴**（横排 y / 竖排 vertical-rl x）先定行，**行内轴**再按字符矩形**中点规则**取前沿/后沿（与布局引擎 `Layout.getOffsetForHorizontal` 同判据）—— 行尾右侧空白 clamp 到行尾、行首左侧空白 clamp 到行首、行距里的点归最近的一行（不会因为下一行的字在行内轴上更近就跳行）。有界：根是命中元素所在的块 + 字符数上限。
  - **③ 端点规范化 + 可见性收口**：
    - `normalizeEndpoint`：`collectRangeBetween` 的游走用 `createWalker`（REJECT 纯空白节点与振假名），端点若落在被跳过的节点里，游走永远匹配不到 endNode → 会一路扫到文末、选区暴涨（空格字符有真实 client rect，严格命中**能**解析到纯空白节点，这条路是真的可达）。故先挪到游走会访问的正文节点：正向顺延到下一个正文节点首字、反向回退到上一个正文节点末字。
    - ~~`snapEndpointToWord`（端点按词吸附）~~ **已按用户反馈整条移除**：吸附让拉丁文本只能按整词进退、选不到词内任意字符，与浏览器 / 平台的实现不一致。现在端点解析只把坐标换算成端点字符，**拖动逐字跟随手指**（可自由收缩进词内，也可越过词尾向外扩）。
    - `selectionAnchorAtHit`：锚点从单字升级为**区间**（词首..词末 / 单字），**只在原地长按那一刻**决定初始选区（原地长按即选中整词 —— 浏览器 / Android 长按语义）；一旦拖动，端点就逐字跟随手指，锚点区间**不构成**「不能收缩」的下限。空格分词判据复用 BUG-2056 的 `isSpaceDelimitedLetter` / `isIntraWordApostrophe`；CJK / 标点 / 空白 → 单字锚点（与 BUG-609 起的老行为一致）。
    - BUG-1797 可见性收口贯穿新层：分页页边距带里被 clip 掉的相邻页字符（布局期几何仍在）既不能当 caret 快路结果、也不能当兜底端点。
  - `updateRangeSelection`：**端点始终跟随手指** —— 压在字符矩形上就用那个字，落在字缝/行距/行尾等没有字符矩形的位置就走解析层（旧实现在这里把端点钉回锚点 = 选区塌陷）。刻意**不保留**「命中落在锚点区间内就维持锚点」的粘滞判定：那会让拉丁词永远只按整词进退。解析失败才重建锚点选区（保持旧端点、不收缩）。
  - `moveSelectionHandle`：保留 BUG-765 的 `pointer-events` 熄灭 + 严格命中优先；**端点解析必须留在那个「手柄对命中测试透明」的窗口内**（解析层两条路与命中测试同源，手柄一恢复 `pointer-events:auto` 就会命中手柄自身、两条同时失败 → 手指压住 32×32 触控盒时手柄不跟随）；几何兜底另经 `_hitElementUnderPoint` 跳过手柄元素（`updateRangeSelection` 不切 `pointer-events`，只有靠这层才解析得出来）。只有解析失败才 `return`（旧实现在这里直接 return = 手柄冻结）。
  - `beginRangeSelection`：建锚后**直接**用 `collectRangeBetween` 画出锚点区间（**不走**端点解析 —— 手指此刻还压在锚点上，解析会把刚定下的整词截成半截）；`clearSelection`：复位区间锚点（会话状态，选区清掉即复位，不泄漏到单击查词）；`endRangeSelection`：**不再**重新解析一次端点（拖动的每一步已由 `updateRangeSelection` 处理），因此原地长按保留整词。
  - **不做的事**：不动 selection highlight / 手柄外观与定位 / 查词弹窗 / 复制·收藏·导出菜单；不动 `selectText`（单击查词）与 `selectFromPosition`；不碰 `window.getSelection()`（TODO-1279 触屏无双选区）。桌面 Windows/macOS 的鼠标选择走浏览器原生选区 + 右键菜单（`pointer: fine` 分支），单击查词走 `selectText` — 两者都不经过本层（守卫测试钉住：解析层调用点只有 `updateRangeSelection` 与 `moveSelectionHandle`，且 `selectText` 段不含解析层符号）。
- **[x] ② 已加自动化测试**：
  - `fushi/test/reader/reader_selection_drag_hit_behavior_test.js` + 同名 `.dart`（**真行为**，非源码扫描）：Node 真跑生产 JS（从 `source()` 原始字符串 verbatim 抽出 `window.fushiSelection`），配一个复现真实 WebView 几何的 fake DOM（每字符真实行盒 rect、`caretPositionFromPoint` 复现 clamp 语义、可摘掉原生 API 跑兜底、**并建模手柄遮挡**），回放 16 组拖动坐标序列：字缝前进 / 行尾 clamp 本行不跳行 / 下一行右侧空白归该行 / 段末 clamp 段末 / 无原生 API 的几何兜底 / **拉丁拖动逐字精确（不吸附词边界）** / 拉丁长按选整词 / **拉丁拖动可收缩进锚点词内** / CJK 保持字符级 / 竖排 vertical-rl / 分页页边距带不选中被 clip 的相邻页字符 / 严格命中零回归（逐字精确）/ 手柄横扫（跨字缝·行尾·行距）单调前进永不冻结 / 纯空白节点端点规范化（含「不规范化就会撑到文末」的反证断言）/ **手柄盖住手指时（拖手柄 + 拖文字两条）都不冻结**。本机 / CI 无 node 时 skip。
  - `fushi/test/reader/reader_selection_drag_hit_guard_test.dart`（源码契约）：解析层 API 齐全、原生快路优先且两条 WebView 方言都覆盖、几何兜底按交叉轴·行内轴定行定 caret + 有界扫描 + 命中元素经「跳过手柄」的取元素层、端点规范化（跳过的节点必须挪走）、可见性收口（BUG-1797）、**端点不做词边界吸附（`snapEndpointToWord` / `wordSelectMode` 全文件不得再出现）**、**拖动端点始终跟随手指 / 长按原地保留锚点区间 / `endRangeSelection` 不得再解析端点**、解析层不碰原生选区、单击查词段不经解析层、调用点数量哨兵（2 处）。
  - `fushi/test/reader/reader_selection_handles_guard_test.dart` 更新：`beginRangeSelection` 的锚点断言改成「区间锚点 + `selectionAnchorAtHit` + 直接 `collectRangeBetween` 画区间（不得走 `updateRangeSelection`）」；`updateRangeSelection` / `moveSelectionHandle` 补「严格命中落空必须走 `resolveSelectionEndpoint`、不得直接 return 冻结手柄」的断言。
- **备注**：真机（Android / iOS）触屏长按拖选后拖两端手柄跨越字缝·行尾·行距·段间空白必须能连续跟随、查词/复制/收藏菜单无回归 —— 真触屏手势与真实字符矩形只能设备验（离屏 `pointer: fine` 不触发 coarse，`flutter test` 也没有真布局），按 CLAUDE.md 验证纪律标 `implemented_unverified`，待用户或 reviewer 在受支持设备上复验；分页 / 连续 / VN 三种 view mode 都要过一遍（几何不同）。本机已跑：`dart tool/heavy.dart -- flutter analyze --no-pub`（Flutter 3.44.0）→ No issues found；行为测试 16/16；`reader_selection_drag_hit_guard_test` / `reader_selection_handles_guard_test` / `reader_pagination_viewport_selection_guard_test` 全绿。
- **后续反馈（同 PR 内）**：① 用户报「拉丁语言没法随意选择字符」→ 端点按词吸附整条移除（见上）。② 用户报「拖动时手柄不改变位置」→ 根因即本 bug 的 P1：`moveSelectionHandle` 原先把端点解析放在**恢复** `pointer-events` 之后，解析层两条命中路都会命中手柄自身 → 端点解析为 null → 手柄不跟随；已改为在透明窗口内解析 + 几何兜底跳过手柄元素（**保留手柄可见**，不采用「拖动时藏起手柄」那种丢反馈的做法）。③ 用户报「有选区时翻页，选择的条还在」→ 另立 BUG-2959（翻页/滚动换视口时清选区）。

### 2026-10-05 审查与后续补修（以下覆盖前述首轮实现/验证说明）

- `normalizeEndpoint` 的空结果可达，但没有证实“该分支必然选到文末”；规范化现在先沿拖动方向找正文，失败再试另一侧，仍失败则保留旧选择，不回到 anchor。
- 两种 caret API 依次尝试；严格命中与几何解析统一放入 `selectionEndpointAtPoint` 的手柄 pointer-events 透明窗口，finally 精确恢复。
- 长按 begin/update 原先只更新高亮，松手才显示手柄。现在初始/每次移动均同步定位；手柄 touchstart 通知 Flutter 移除旧工具条，touchend 使用最终坐标。源 DOM 被 clear/normalize/detach 时重新命中或结束旧会话，禁止迟到 release 复活菜单。
- 根多列布局支持 manual popover top layer，避免 html 分栏影响 fixed 手柄；老内核保留 fixed 路径。视口边缘触控盒与工具条避让见 BUG-2961。
- 原简报声称恢复 pointer-events 后解析可让第15/16场景变红，实测原16条仍全绿；第15条被 elementsFromPoint 几何兜底救回，第16条不走被变异方法。最终新增无 elementsFromPoint、异常恢复、实时坐标、迟到事件与边界断言：36 场景通过，23 个 mutation 全被检出；Node 缺失直接失败，不再 skip。
- 最终真实 headless Chrome 10/10（含 trusted CDP touch 拖动，在松手前坐标已更新），不等价于手机验收。用户最终要求不再 adb；最终状态仍为 `implemented_unverified`。测试文件为 `reader_selection_drag_hit_behavior_test.{js,dart}`、`reader_selection_handles_guard_test.dart`、`reader_selection_drag_hit_guard_test.dart`；证据在 `.codex-test/reader-selection-audit/`。