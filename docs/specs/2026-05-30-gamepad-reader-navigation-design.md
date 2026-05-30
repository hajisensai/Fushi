# 手柄阅读导航：A=上下文激活 / B=返回 设计

> 状态：已实现并通过 Opus 代码审查（C1/I1/I3 三项前轮问题已修），待 Windows 真机用手柄复测原失败路径。
> 触发：在 Windows 真机用手柄使用阅读器时发现：超链接点不了、查词弹窗按钮够不到、释义里的汉字停不上、底栏显示时机别扭。
> 模型修订：早期草案曾设想"底栏默认隐藏、进字光标自动隐藏"，已被用户否决——**底栏只由 Y 切换显隐**，阅读内容与底栏是同层兄弟，见单元 3。

## 目标

让手柄在阅读器 + 查词弹窗里"和正常使用一样"：用一个"激活"键（A）对光标所在内容做正确的事（点击/确定语义），B 逐层返回，底栏跟随导航层级显隐。

## 现状（事实，已核对代码）

- 字光标活在 JS `window.hoshiCaret`（`reader_caret_scripts.dart`），Dart 侧 `ReaderCaretRouter` 把按键映射成 `CaretAction`，`reader_hibiki_page.dart` 执行。
- 现在 A/Enter（光标激活时）→ `CaretAction.lookup` → `hoshiCaret.lookup()` 查词。**没有"激活链接/点按钮"动作**。
- 链接：阅读器内部链接走 `shouldOverrideUrlLoading`（[reader_hibiki_page.dart:1718]）——内部链接跳章/锚点，外链交 OS。但手柄光标无法触发它（A 只查词）。
- 查词弹窗是纯 WebView（`dictionary_popup_webview.dart`，Yomitan 风格）。可交互元素：`a[href]`（跨词/外链）、`[onclick]`（音频▶、音高、频率展开）、`[role=button]`。弹窗光标 scope = `.glossary-content`，只停释义正文 → 按钮/汉字（若在正文外）停不到。
- 底栏 `_showChrome` 初始 `true`（进书即显示），无自动隐藏，只能 Esc/Y 手动切换。
- 手柄绑定（`shortcut_defaults.dart`）：RB/方向→翻页、Y=底栏、B=关字典/退光标、X=书签、A=进光标/查词、L3=播放。

## 设计

### 单元 1：`hoshiCaret.activate()`（JS，上下文点击）

新增方法，按光标所在元素决定动作（返回字符串标识，便于 Dart 侧分流）：

```
activate():
  el = node.parentElement
  hit = el && el.closest('a[href], button, [role=button], [onclick]')
  if (hit && hit.matches('a[href]')) { hit.click(); return 'link'; }  // 走原生导航
  if (hit) { hit.click(); return 'activated'; }                       // 按钮/可点元素
  return this.lookup() ? 'lookup' : 'none';                           // 普通词/汉字查词
```

- 链接 `a[href].click()` 触发原生导航 → 复用现有 `shouldOverrideUrlLoading`（内部链接跳章/锚点、外链交 OS），**不重写链接解析**。
- 按钮/可点元素 `.click()` 直接触发其既有 onclick（音频播放、音高/频率展开等）。
- 普通文本 → 现有 `lookup()` 不变。

### 单元 2：`ReaderCaretRouter` A→activate（纯 Dart，可单测）

- 新增 `CaretAction.activate`；`decideKeyboard`/`decideGamepad` 中 Enter / gameButton A 从 `lookup` 改映射为 `activate`。
- `lookup` 作为内部动作保留（`activate` 的 JS 在普通文本时内部仍走 lookup 管线），但路由层 A→`activate`。
- 单测：`decideKeyboard(enter)==activate`、`decideGamepad(a)==activate`、其余方向/B 不变。

### 单元 3：阅读器接线（`reader_hibiki_page.dart`）

- `_runCaretAction` 处理 `CaretAction.activate`：调用 `hoshiCaret.activate()`；返回 `'link'` 时无需额外处理（导航已由 WebView 触发，翻页后照常 reanchor）；`'lookup'` 时既有 onTextSelected 管线照常弹词典。
- 弹窗侧（`DictionaryPopupWebViewState`）同样把 A 接到 `hoshiCaret.activate()`（点弹窗内按钮/链接），与阅读器同构。
- **层级模型（阅读内容 ↔ 底栏 = 同层兄弟）**：
  - 顶层有两个兄弟焦点目标：阅读内容、底栏。手柄 D-pad **上/下在两者间切换焦点**（Down→进底栏，Up→回阅读内容）；D-pad 左右 + RB/LB 才是翻页，故上下不抢翻页。
  - A 逐层下降（阅读内容 → 进字光标 → 在光标内激活），B 逐层上升；**顶层 B = 退出阅读器**（`Navigator.maybePop`），字光标内 B 仅回到阅读内容、不退出。
  - 底栏可见性**只由 Y 切换**：`_showChrome` 进书即 `true`，无自动隐藏；**B 不收起底栏**（B 在顶层是退出）。
  - 进底栏（Down）仅当底栏确有可聚焦控件时才消费按键（`_chromeFocusScope.nextFocus()` 为真），否则交 `GamepadService` 方向焦点兜底，避免把焦点搁浅在阅读内容（I3）。
  - **键盘路径**：方向键 ↑/↓ 是既有翻页绑定（向后兼容，不动），所以"上下切层"是**手柄专属**；键盘用 **Esc 进/出底栏**（`readerToggleChrome`），底栏内 ↑ 回到阅读内容。
- **焦点指示（不是红框，且恰好一个环）**：用 App 标准焦点环（`colorScheme.primary`、2.5px、圆角 8）。阅读内容的环由阅读器**自绘并按底栏插边内缩**，保证在屏内、不被底栏遮挡；同时全局 `HibikiFocusRing` 对"接近全窗口（两轴 ≥92%）"的 focusable 不再画环（C1，避免与内缩环重叠成双环）。环只在键盘/手柄高亮模式（`FocusHighlightMode.traditional`）显示，触屏不显示（I1，随输入设备翻转实时刷新）。

### 单元 4：弹窗光标可达按钮 + 汉字（scope）

- 弹窗 caret 不再只限 `.glossary-content`：导航整个弹窗可视内容（去掉/放宽 scope），并把可交互元素（`a[href], button, [role=button], [onclick]`）显式纳入停靠点，使音频▶/音高/频率/跨词链接都能停且 A 可激活。
- 汉字：释义正文里的汉字本就是文本节点（furigana `rt/rp` 被 walker 正确跳过、停在基底汉字）；放宽 scope 后，正文外的汉字（如词头/词条标题）也可停。
- 实现期对照真机弹窗 DOM 校准选择器（用运行中的 WebView 控制台核对 Yomitan 结构），保证非占位。
- **可交互元素 = 原子停靠点**：交互元素（`a[href], button, summary, [role=button], [role=link]`）整体作为**一个**停靠点（环覆盖整控件，如 `<summary>` 折叠键），光标不停在控件内部单字。此原子化**仅弹窗生效**（JS 内 `!window.hoshiReader` 分支）；阅读器正文里仍按字停靠（即便 EPUB 含交互元素，每个内部字按 A 经 `activate()→click()` 触发同一控件，功能等价），避免改变长期的逐字阅读手感。

### 单元 5：验证

- 纯 Dart 单测：`ReaderCaretRouter` 的 A→activate 映射。
- Windows + Android 集成测试（扩展 `reader_caret_test` / `reader_popup_caret_test`）：
  - 光标停在 `<a href>` 上 A → 触发导航（章节变化 / shouldOverrideUrlLoading）。
  - 弹窗内光标停到可交互元素，A → 触发其 onclick（如音频/展开）。
  - 弹窗内光标停到释义汉字，A → 查词（嵌套弹窗或选区）。
  - 进入字光标后底栏隐藏；Y 显示、退回阅读隐藏。
- 真机复测原失败路径，留证据。

## 不做（YAGNI）

- 分键方案（A 永远查词 + 另键激活）——已否决。
- 鼠标交互改动（本就正常）。
- 链接解析逻辑重写（复用 `shouldOverrideUrlLoading`）。
- 弹窗外的 Flutter 工具栏/创建器流程改动。

## 风险

- 放宽弹窗 caret scope 可能让光标停到弹窗 chrome/标签文本上（可移动跳过，非阻塞）；实现时按"可交互元素 + 释义正文"收敛停靠集合，避免过度泛滥。
- `a[href].click()` 在竖排/分页下触发导航后需确保 reanchor 不错乱（复用既有翻页后 reanchor）。
