# Hibiki 手柄导航全面优化设计（Gamepad Navigation Comprehensive Design）

> 日期：2026-05-31 ｜ 状态：实现中；期1-3 已有代码/单测覆盖，期4-6 部分已有，仍缺真实设备复测闭环 ｜ 平台：Windows / iOS / macOS / Linux（轮询 gamepads 插件）+ Android（引擎 key-event）

本设计是 Hibiki 手柄可用性的**总纲**，统一定义全局按键语义、独立滚动通道、焦点默认可达策略、查词弹窗焦点语义，并把全部缺口拆成 6 期可独立交付的迭代。

它**衔接而非重复**已落地的手柄基础：
- [2026-05-30-gamepad-reader-navigation-design.md](2026-05-30-gamepad-reader-navigation-design.md) — 阅读器手柄导航
- [2026-05-30-reader-char-caret-navigation-design.md](2026-05-30-reader-char-caret-navigation-design.md) — 阅读器字级光标
- [2026-05-30-popup-char-caret-design.md](2026-05-30-popup-char-caret-design.md) / [2026-05-31-popup-gamepad-navigation-plan.md](2026-05-31-popup-gamepad-navigation-plan.md) — 弹窗字级光标 + sibling-layer 两层协同
- [2026-05-31-gamepad-long-press-plan.md](2026-05-31-gamepad-long-press-plan.md) — 长按 A 等价

---

## 0. 当前实现审计（2026-06-01）

这份总纲已经不再是“待写实施计划”。代码里已有一批实现，剩下的问题不是重写，而是继续按缺口收口。

| 阶段 | 状态 | 当前证据 | 剩余缺口 |
|------|------|----------|----------|
| 期1 滚动通道 + 默认可达 | 已有 | `HibikiFocusScroll.scrollByViewportFraction/scrollPrimary`、`PageScrollRegistry`、`globalScrollPageUp/Down`，测试见 `hibiki_focus_scroll_test.dart`、`hibiki_page_scaffold_scroll_test.dart`、`gamepad_focus_nav_test.dart` | 仍需 Windows 手柄与 Android 模拟器复测统计页、日志页等原始失败路径 |
| 期2 数值控件可调 | 已有 | `settings_shared.dart` 的 `_GamepadAdjustableValue`、`_KeyboardStepper`、slider/stepper 行统一 D-pad 左右调值 | 仍需真实设置面板路径复测，确认所有数值页都已走统一组件 |
| 期3 导航 + 查词入口 | 已有 | `ShortcutAction.homeTabPrev/homeTabNext/homeFocusSearch` 与 LT/RT/Y 默认绑定，`home_page.dart` 消费这些 action；测试见 `shortcut_defaults_test.dart` | 仍需手柄端到端复测首页 tab 循环与词典搜索聚焦 |
| 期4 手势等价动作 | 部分已有 | `GamepadLongPressActions` 已覆盖历史/集合/搜索历史等条目；标签页有 X 删除；重排按钮与 `gamepad_reorder_test.dart` 覆盖索引补偿 | 覆盖面未审完：集合/标签/字体/词典/同步 URL/音频源等所有长按、删除、重排入口还要逐页核对 |
| 期5 阅读器 + WebView 专项 | 部分已有 | 弹窗上下跳项/左右逐字、图片停点、reader 图片 `onImageTap`、R3 振假名、LB/RB 复用滚动/翻页均有代码与 `reader_caret_scripts_test.dart` 结构测试；本轮修复了 disabled 按钮误入停点 | 词典结果 WebView 是否纳入 caret、全屏插图 LB/RB/R3、真实 WebView DOM/边界证据仍需补齐 |
| 期6 手柄软键盘 | 部分已有 | `HibikiGamepadKeyboard`、`showGamepadKeyboard`、`HibikiTextField`、`HibikiSearchField`、`HibikiCompactSearchRow`、`HibikiEditorPanel` 已在桌面提供软键盘入口；文本插入/删除/提交测试见 `hibiki_gamepad_keyboard_test.dart`、`hibiki_text_field_keyboard_test.dart` | 仍需真实桌面手柄复测重命名、标签/Profile/WebSocket、歌词和书籍 CSS 编辑路径，不能只靠 widget 结构测试宣称完成 |

【核心判断】
✅ 值得继续做：这是实打实的可达性缺口，不是臆想优化。坏状态已经从“没有方案”变成“实现散落、文档过期、设备证据不足”。

【关键洞察】
- 数据结构：真正的状态不是单个“手柄支持已完成”布尔值，而是“action 绑定 + 焦点注册 + 页面消费 + 设备验证”四段链路。
- 复杂度：不要再造第二套手柄系统；所有新增能力必须落回 `ShortcutAction`、`HibikiFocusTarget`、`HibikiFocusScroll`、`window.hoshiCaret` 这些现有入口。
- 风险点：结构测试只能证明脚本/绑定存在，不能证明 WebView、DocumentsUI、真实手柄事件在设备上跑通。未复测的路径不得标成完成。

---

## 1. 背景与问题

### 1.1 现状机制（已确认）

手柄/键盘焦点由 [HibikiFocusController](../../hibiki/lib/src/focus/hibiki_focus_controller.dart) 驱动：`move(direction)` 只在**已注册的 `HibikiFocusTargetEntry` 可聚焦目标**之间做几何移动；移动成功后 `_scheduleReveal → HibikiFocusScroll.ensureVisible` 滚动让焦点可见。手柄输入经 [gamepad_service.dart](../../hibiki/lib/src/shortcuts/gamepad_service.dart) 的 `gamepadMoveFocusInDirection` 进入。

### 1.2 两条结构性根因

**根因 A — 手柄没有"滚动"这个动作；滚动只是焦点切换的副作用。**
唯一的滚动入口是 [hibiki_focus_controller.dart:197-203](../../hibiki/lib/src/focus/hibiki_focus_controller.dart#L197-L203) 在焦点请求成功后调 `ensureVisible`。`controller.move` 没把焦点挪到一个更靠下的已注册目标，页面就一行都不滚。在 `HibikiFocusRoot` 下 reading-order fallback 被刻意禁用（[gamepad_service.dart:300-309](../../hibiki/lib/src/shortcuts/gamepad_service.dart#L300-L309)，隔离导航层的正确设计），导致**任何"可滚动但主体无注册目标"的页面对手柄彻底封死**。

**根因 B — 可聚焦性是"显式注册"模型，而非"凡可交互即可达"。**
`controller.move` 只遍历来自 `register()` 的 `_entries`。`HibikiIconButton`(不传 focusId)、`HibikiTagChip`(onTap 分支)、裸 `Slider`/`Stepper`、搜索框、底栏导航等在未注册时退化成裸 `InkWell`，对手柄几何导航不可见。

### 1.3 缺口规模

全 app 扫描得 **33 个缺口**（去重 25 条），分布：
- **Critical**：阅读统计整页够不到、所有 Slider/Stepper 改不了值、首页三大 tab 切不了、词典搜索框够不到、文本输入无软键盘、`HibikiIconButton` 漏注册（放大器）。
- **Major**：词典 WebView 滚动/词内链接、同步比对/日志页滚动、集合/标签侧滑删除+长按、振假名双击、正文图片放大、音频 seek、全屏插图翻页缩放、标签 chip 筛选、字体/词典拖动重排。
- **Minor**：各类次级重排/缩放/长按删除/行内次级动作。

---

## 2. 目标与非目标

### 2.1 目标
- 手柄用户能**走完所有页面、按所有按钮、调所有数值、切 tab、查词、滚动任意长页**。
- 一套**全局统一**的按键肌肉记忆，阅读器内外一致。
- 分 6 期，每期独立交付、独立在真实模拟器/Windows 设备验证原始失败路径。

### 2.2 非目标
- 不引入"虚拟鼠标指针"范式（与现有焦点架构冲突，违背最简原则）。
- 不改 Android 的引擎 key-event 路径语义（仅补齐两端共用的 action 绑定）。
- 不在本设计内做完整 IME/输入法替代；期6 的手柄软键盘是受控子集。

---

## 3. 核心设计

### 3.1 全局统一手柄按键地图

核心原则：**同一个键 = 同一种心智，在不同页面落到最贴近的具体动作**。现有架构按作用域解析 `GamepadButtonIntent`（各页面 registry），天然支持"语义统一、就近落地"。

| 按键 | 统一语义 | 阅读器外（home/设置/词典/对话框） | 阅读器内（保持现状） |
|------|---------|--------------------------------|--------------------|
| 左摇杆 / D-pad | 移动焦点光标（边缘自动滚动） | 控件间移动 | 字级光标移动 |
| A | 确认·激活（长按 = 上下文菜单） | 按按钮·选条目 | 光标进入·查词 |
| B | 返回·取消 | 退页面/关对话框 | 退光标·返回 |
| **LB / RB** | **上一屏 / 下一屏内容** | **整页滚一屏** | 上一页 / 下一页 |
| **LT / RT** | **上一组 / 下一组** | **循环切三大 tab** | 跳章节（预留） |
| X | 标记·书签 | 上下文次级（删除/上移） | 书签 |
| Y | 工具 / 搜索面板 | 聚焦搜索·溢出菜单 | 切换 chrome |
| Start | 主菜单 | 页面溢出菜单 | — |
| L3 | 播放·暂停 | 有声书播放（无音频则空闲） | 有声书播放暂停 |
| R3 | 缩放 | 图片/插图缩放 | — |

**核心导航 7 键（D-pad / A / B / LB / RB / LT / RT）全局完全一致**。X / Y / L3 / R3 是"语义统一、就近落地"，页面无该功能时空闲，不改派成别的意思。

空闲键现状（来自扫描）：LT/RT/Start/Select/R3 全 app 无消费端；LB/RB/X/Y 仅 reader 域有绑定，非阅读器页空闲——这些正是本设计的"落点"。

### 3.2 独立滚动通道（A + B 组合）

为根因 A 引入两条**独立于焦点切换**的滚动路径：

**A — D-pad 边缘自动接管滚动**（有焦点的页面）
在 `gamepadMoveFocusInDirection`（[gamepad_service.dart:294-316](../../hibiki/lib/src/shortcuts/gamepad_service.dart#L294-L316)）`controller.move` 失败、`return false` **之前**，插入"滚动当前焦点最近的可滚动祖先约 80% viewport"：从当前焦点 `context` 经 `Scrollable.maybeOf` 取祖先 `ScrollableState`，`position.animateTo(clamp(pixels ± 0.8*viewport))`。滚成功则吞掉该方向输入；滚到底则照旧 `return false`（停在边缘）。

**B — LB/RB 整页翻屏**（任意页面，含纯展示零焦点页）
新增 action（如 `globalScrollPageUp/Down`），在非阅读器作用域把 **LB/RB** 绑定为"主滚动区翻一屏"：经 `PrimaryScrollController.of(context)` 取当前路由主 `ScrollView`（统计页 `CustomScrollView`、日志页等默认 primary 挂载），`animateTo(± viewport)`。这是纯展示零焦点页（统计/日志/同步比对）唯一可靠的滚动手段——它不依赖焦点，所以"一进页面就能 LB/RB 翻到底"。

> 两条互补：A 服务"有焦点但走到列表底/顶"，B 服务"整页无可聚焦内容"。阅读器内 LB/RB 已是翻页（同心智），不受影响。

### 3.3 焦点默认可达（反转"显式注册"为"默认注册"）

为根因 B：把"漏传 focusId 就不可达"反转为"在 `HibikiFocusRoot` 下默认即注册，focusId 仅用于覆盖/分组"。

- [HibikiIconButton](../../hibiki/lib/src/utils/components/hibiki_icon_button.dart#L188-L206)：删掉 `if (widget.focusId == null) return button;` 的退化分支，无显式 focusId 时自动派生一个稳定内部 id（基于稳定 `GlobalKey`/位置派生）注册 `HibikiFocusTarget` + `ActivateIntent`。一次救活 82 处调用里的几十个工具栏图标键。
- [HibikiTagChip](../../hibiki/lib/src/utils/components/hibiki_material_components.dart#L625-L630) onTap 分支、[HibikiCard](../../hibiki/lib/src/utils/components/hibiki_material_components.dart#L64-L73)、`HibikiColorSwatch`、行内次级 `InkWell`：`onTap != null` 时统一用 `HibikiFocusTarget + ActivateIntent` 注册，不再返回裸 `InkWell`。
- 原则确立：**凡可点即可被焦点经过**。`disabled`/`onTap == null` 仍不可聚焦。

### 3.4 查词弹窗焦点语义（你特别点名的专项）

**问题**：弹窗里现状是**逐字光标**（每个汉字假名都停），但真正该停的只有"能按一下触发动作"的元素。

**目标交互（已选定：上下跳项 / 左右逐字，单模式无切换）**
- **↑ / ↓**：在「可交互元素 + 文本行」之间跳（快速浏览、找可操作项）。
- **← / →**：在当前文本行内逐字移动（用于查释义里的词）。
- **A 在可交互元素 = 激活**（音频/挖词/跟链接/折叠）；**A 在文字 = 查这个词**（保留现有 lookup 压栈）。
- **B = 关闭弹窗**（不为关闭设可聚焦按钮，符合全局地图）。

弹窗元素分**三类**，对应不同停点粒度（这正是"上下跳项/左右逐字"的关键，也回答了"释义正文不能点怎么嵌套查词"）：

**① 动作项 — ↑/↓ 跳项停点，A = 激活**

| 类别 | 元素 | 层 |
|------|------|----|
| 操作按钮 | ♪发音音频 `button.audio-button`、➕挖词 `button.mine-button` | WebView |
| 再查/跳转 | 词内相关词 `a[href]`、外部来源链接、可点词头 `span.expression`、汉字 chip `span.kanji-tag` | WebView |
| 折叠 | 词典展开/折叠 `summary.dict-label` | WebView |
| 看图 | 释义图片 `a.gloss-image-link`（⚠️现状够不到，要补） | WebView |
| 顶栏 | 收藏星 ★、重播 ↺、播放/暂停 ▶、从 cue 续播 | Flutter |

**② 查词文本 — ↑/↓ 跳到该行，← / → 行内逐字，A = 查这个词（嵌套查词入口）**
释义正文 `div.glossary-content`、例句、可查的词条文字。**这类不是"按一下触发动作"的可操作项，但绝不是够不到**：↑/↓ 把光标跳到目标释义行 → ←/→ 逐字定位到要查的词 → A 查词压栈。所以"释义正文不抢 ↑/↓ 跳项焦点" ≠ "不能查"——嵌套查词走 ←/→ + A 这条路。

**③ 纯装饰 — 完全不停（既非动作也非查词目标）**
读音振假名 ruby/rt、词典名 `span.dict-name`、频率数字、pitch 高低线图、词性标签 `span.glossary-tag`、活用还原提示、加载进度条。

**技术落点**（复用同一 `window.hoshiCaret`，按 `window.hoshiReader` 区分模式）
- 弹窗模式（`!window.hoshiReader`）下，让停点集合 `_collectVisibleStops`（[reader_caret_scripts.dart:359-391](../../hibiki/lib/src/reader/reader_caret_scripts.dart#L359-L391)）**按移动方向分粒度**：垂直移动（↑↓）收集「①动作项 `_interactiveEls` ∪ ②查词文本的行级停点」，水平移动（←→）在当前②查词文本块内收集「字级停点」。第③类纯装饰从两种粒度都排除（扩展现有 `_isStop` 对 `.glossary-tag` 等的拒绝，覆盖频率/pitch/词典名/振假名）。阅读器正文保持现状逐字（正文文本即查词目标）。
- 衔接已落地的 sibling-layer（[2026-05-31-popup-gamepad-navigation-plan.md](2026-05-31-popup-gamepad-navigation-plan.md)）：DOM 顶行 ↑ 越界 → Flutter 顶栏；顶栏 ↓ → 回 DOM 首个停点。本设计是其停点模型的升级，不重做两层协同。
- **补 3 个可达缺口**：①`gloss-image-link` 加 `role=button`（或 `_interactiveSelector` 增 `.gloss-image-link`）使 caret 够得到，A 命中 → `openImageLightbox`；②`mine-button` `disabled` 态从停点集合排除，启用后随刷新回归；③统一原则——要可达的元素必须落进 `_markClickables` 三条命中之一（`_interactiveSelector` / `onclick` 属性 / 最外层 pointer），`addEventListener`-only 不算。
- 词典 tab 结果（`definition.html`/`definition.js`，不注入 `hoshiCaret`）是否纳入：作为期5 的可选子项单独决定，纳入则在 `definition.html` 也注入同一套 caret，复用停点/激活逻辑，不另造。

---

## 4. 分期路线图

每期独立交付、独立验证。期1–3 = 治根因 + 全部 Critical；期4–5 = Major 手势补齐；期6 = 软键盘大工程单立。

### 期1 — 🏗 滚动通道 + 焦点默认可达（地基）
- §3.2 A（D-pad 边缘接管）+ B（LB/RB 整页翻屏）。
- §3.3 反转 `HibikiIconButton`/`HibikiTagChip`/`HibikiCard` 默认注册。
- **救活**：阅读统计、调试/错误日志、同步比对滚动；几十个工具栏图标键；书架标签 chip 筛选。
- 验证：模拟器/Windows 进统计页，LB/RB 翻到「按书」列表底；工具栏图标键可 D-pad 聚焦+A 触发。

### 期2 — 🎚 数值控件可调
- `AdaptiveSettingsSliderRow`/`StepperRow` 整行接入焦点注册（[settings_shared.dart:713-906](../../hibiki/lib/src/utils/components/settings_shared.dart#L713-L906)），聚焦后 **D-pad 左右 = 减/增一档**、A 切换编辑态；复用 `_KeyboardStepper` 步进逻辑给 Slider 补"手柄 D-pad → 值增减"桥。
- **覆盖**：字号/行距/亮度/音量/倍速/边距/弹窗宽度 + 卡片创建器/录音音频 seek。
- 验证：阅读器快捷设置面板手柄改字号生效；音频 seek 条 D-pad 左右移动播放头。

### 期3 — 🧭 导航 + 查词入口
- 首页三大 tab：destination 注册 + **LT/RT 循环切 tab**（补 `homeTab*` 的 gamepad 绑定，[shortcut_defaults.dart:80-91](../../hibiki/lib/src/shortcuts/shortcut_defaults.dart#L80-L91)）。
- 词典搜索框：传 focusId 注册 + **Y 聚焦搜索**（补 `homeFocusSearch` gamepad 绑定）。
- 验证：手柄 LT/RT 在书架↔词典↔设置间切换；词典 tab 按 Y 聚焦搜索框。

### 期4 — ✋ 手势等价动作
- 长按菜单：条目包 `GamepadLongPressActions`（hold-A 触发）——集合页、标签管理、搜索历史。
- 侧滑删除等价：聚焦条目后 **X 删除**或长按菜单内删除（标签管理、集合）。
- 拖动重排等价：每行加可聚焦**上移/下移**按钮，或聚焦行后空闲键触发 `onReorder`——自定义字体、主词典优先级、同步 URL、音频源、书架标签。
- 验证：手柄删除一条书签/标签；手柄把某字体上移一位。

### 期5 — 📖 阅读器 + WebView 专项
- §3.4 查词弹窗"上下跳项/左右逐字"停点模型升级 + 3 个可达缺口补全。
- 词典结果页/弹窗 WebView 滚动：复用 reader 的"键→JS scrollByPage"桥。
- 新增 `readerToggleFurigana` action + 绑键 + JS 注入（替代 WebView 双击，[reader_hibiki_page.dart:1423-1429](../../hibiki/lib/src/pages/implementations/reader_hibiki_page.dart#L1423-L1429)）。
- 正文图片放大：`img` 纳入 caret `_interactiveSelector`，activate 命中 IMG → `onImageTap`。
- 全屏插图浏览器：LB/RB 换页（驱动 `PageController`）+ R3 缩放（`InteractiveViewer`）。
- 验证：弹窗手柄只在音频/挖词/链接间跳、纯文本不停；左右仍能逐字查词；振假名一键开关。

### 期6 — ⌨ 手柄软键盘（独立工程）
- 手柄驱动的屏上软键盘组件（D-pad 选字、A 输入、肩键切字符集），覆盖重命名/标签名/Profile名/主题字体名/WebSocket 地址/歌词文本。
- 先把缺 focusId 的文本框统一补注册。
- Android 短期可先保证落系统 IME 触发路径。

---

## 5. 向后兼容与风险

- **不破坏触摸/鼠标**：所有改动是"新增手柄可达性"，不改既有点击/手势路径；`alwaysTouch` 策略保证鼠标点击不留焦点环。
- **不破坏 Android**：Android 走引擎 key-event，本设计的 action 绑定两端共用；新增空闲键绑定不影响现有键。
- **不破坏阅读器**：阅读器作用域语义保持（LB/RB 翻页、字级 caret 逐字），仅"弹窗"caret 升级停点模型；reader 正文 caret 不动。
- **focusId 自动派生的稳定性风险**（§3.3）：派生 id 必须重建后稳定，否则焦点跳变——writing-plans 阶段需明确派生来源（稳定 GlobalKey/树位置）并加测试。
- **PrimaryScrollController 命中风险**（§3.2 B）：少数页面 ScrollView 非 primary 或多滚动区，LB/RB 可能落空——需逐页确认主滚动区，必要时显式注入 controller。

## 6. 验证策略

- **单元/结构测试**：`gamepad_focus_nav_test.dart` 扩展边缘接管滚动用例；caret 停点模型用 `reader_caret_scripts_test.dart` 结构断言（JS 在 Dart raw string，analyze 不查）。
- **真机/模拟器**：每期收尾在 Windows 设备 + Android 模拟器复测**原始失败路径**（统计页滚动、Slider 调值、tab 切换、弹窗跳项），留证据到 `.codex-test/`。
- **回归**：复测相邻功能（阅读器翻页、reader caret、触摸点击不留环）。
- 遵循 [hibiki/CLAUDE.md](../../hibiki/CLAUDE.md) 验证规则：Dart 改动跑 `dart format .` + `flutter test`；声明"修好了"前必须验证原始失败路径。

---

## 附：决策记录

| 决策 | 选择 | 备注 |
|------|------|------|
| 优化范围 | 全面补齐，分 6 期 | 用户确认 |
| 滚动模型 | A+B（D-pad 边缘接管 + LB/RB 整页翻屏） | 用户确认 |
| 按键地图 | 全局统一，7 核心键一致 | 用户确认（要求"所有页面统一"） |
| 弹窗导航 | 上下跳项 / 左右逐字（单模式无切换） | 用户确认 |
