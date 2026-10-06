# Fushi 样式改版审查与修复（2026-10-06）

## Scope

- 对象：Claude Code「应用优化和界面调整」会话 `91f6fb50-9475-423c-9a23-ab4f1ea67667`，集成分支 `claude/shishamo-1005`。
- 固定审查快照：`1a5424c847a`。公共历史基线 `caeb9e02fca2ba1370dd389dee75cbe132e5526d` 距离较远；本报告不把所有差异都归因于本次样式改版。
- 修复工作区：`D:/codehibiki/.worktrees/codex-sh-style-review-1006`，分支 `codex/sh-style-review-1006`。没有编辑 CC 正在使用的工作区，也没有切换正在运行的应用。
- 重点检查：公共搜索/输入/菜单/按钮/滑块/动效控件，HomePage 导航与库页标签，悬浮页头，设置搜索与两套渲染器，主题持久化/系统取色/编辑预览。
- 不等同于逐页穷举、全部设置功能验收、五平台运行验收。未审查所有媒体导入、下载、FFI、数据库迁移及游戏 Hook 业务。
- 审查中 CC 继续提交了 `e887450243a`（标题栏）、`034aa73010b`（顶部渐变）、`529481008d0`（发现页筛选）。这些是快照之后的改动，需在 CC 最终集成版本重新验收，不能由本报告覆盖。

## Findings

### HBK-AUDIT-001 — 连续拖动跨阈值时页头不收起

- severity：P2
- status：已实现修复，行为验证见下方；实机验收待补。
- 根因：`fushi/lib/src/utils/components/fushi_floating_page_chrome.dart:275` 只在 `UserScrollNotification` 方向变化时判断位置。顶部开始同向拖动时尚未超过 56px，后续更新没有再次执行隐藏判断。
- 影响：一次持续滑动不能收起页头，抬手再滑才有效。
- 修复：记录用户方向，在带 `dragDetails` 的真实拖动更新中检测越过阈值；程序滚动及布局修正不触发隐藏。
- 验证：`fushi/test/widgets/fushi_scroll_away_gesture_test.dart`，持续手势/反向/程序滚动。
- 跟踪：BUG-2980。

### HBK-AUDIT-002 — 设置搜索回车与点击使用不同布局判据

- severity：P2
- status：已实现修复，行为验证见下方；实机验收待补。
- 根因：`fushi/lib/src/settings/settings_home_page.dart:463` 的 Enter 路径使用全窗 `MediaQuery.width`，布局和点击使用局部 `LayoutBuilder` 宽度。
- 影响：例如全窗 900px、内容区 680px 时，Enter 清空搜索并选中不存在的右侧详情，点击结果却能正常导航。
- 修复：搜索栏接收当前实际布局的 `wide`，两种输入路径共用同一判据。
- 验证：`fushi/test/settings/settings_home_search_breakpoint_test.dart`，Material/Glass × Enter/点击。
- 跟踪：BUG-2981。

### HBK-AUDIT-003 — Apple 菜单回调可能被随后 pop 的路由覆盖

- severity：P2（共享组件 API 契约）
- status：已实现修复；未定位到已触发的现有业务调用，不称为线上已复现故障。
- 根因：`fushi/lib/src/utils/components/glass/fushi_glass_overlays.dart:2262` 原先先执行 `item.onTap` 再关闭菜单。
- 影响：回调同步打开对话框或页面时，随后 pop 会关闭新路由，旧菜单残留，泛型不同时还可能出现返回值类型错误。
- 修复：与 Flutter PopupMenuItem 契约一致，先关闭菜单再执行回调。
- 验证：`fushi_shared_controls_contract_test.dart` 中两套主题的菜单打开对话框场景。

### HBK-AUDIT-004 — Apple 搜索框丢弃自定义前缀按钮

- severity：P2（共享组件 API 契约）
- status：已实现修复；未找到已受影响的业务调用。
- 根因：`fushi/lib/src/utils/components/glass/fushi_glass_inputs.dart:903` 把所有搜索前缀都替换成静态放大镜，包含上层明确包装的 `FushiSearchLeading`。
- 影响：上层传入的返回按钮或其他动作消失，回调无法触发。
- 修复：保留显式自定义 leading，只替换普通搜索图标。
- 验证：`fushi_shared_controls_contract_test.dart` 的 leading 点击回调。

### HBK-AUDIT-005 — 默认大小 MD3 搜索框忽略 autofocus

- severity：P3
- status：已实现修复。
- 根因：`fushi/lib/src/utils/components/fushi_material_components.dart:1289` regular 分支漏转发 autofocus，large 与 Apple 分支已转发。
- 修复：regular 分支补齐参数。
- 验证：`fushi_shared_controls_contract_test.dart` 的尺寸 × 主题四种焦点场景。

### HBK-AUDIT-006 — 跟随系统强调色的自定义主题不通知界面

- severity：P2
- status：已实现修复；这是公共历史基线已存在的缺陷，并非本次重设计新引入。
- 根因：`fushi/lib/src/models/theme_notifier.dart:856` 刷新系统色后只通知 system-theme，但自定义主题的 followSystemAccent 也消费系统色。
- 影响：操作系统强调色变化后，自定义主题要等其他重建才更新。
- 修复：活跃且跟随系统色的自定义主题也通知；系统颜色未变化的早退保留。
- 验证：`fushi/test/models/custom_theme_system_accent_refresh_test.dart`，派生/钉死主色、同色静默、系统色消失回退、不跟随主题静默。

### HBK-AUDIT-007 — 大字体与双行页头固定高度冲突

- severity：P2
- status：待 CC 页头负责人处理；当前为源码几何证据，未完成运行验证。
- 根因：`fushi_floating_page_chrome.dart:103` 高度固定 48；`:181` 的标题与副标题同时跟随 TextScaler。默认两行合计约 41.4px，1.3 倍后约 53.8px，超过容器。
- 实际入口：`ai_video_acquisition_page.dart:513` 的远端设备副标题，`statistics_center_page.dart:157` 的 Profile 副标题。
- 建议：在共同页头约束里解决字号缩放与副标题布局，连同 AppBar 槽位和安全区域一起验证。仅把胶囊改高会重新触发 BUG-2977 裁切；不应靠关闭系统字体缩放或隐藏错误解决。
- 验证矩阵：字体 1.0/1.3/2.0，单/双行，窄窗口/横屏，检查完整文字与可点击区域。

### HBK-AUDIT-008 — 主题预览与实际应用使用不同配置解析

- severity：P2
- status：已统一解析函数，定向测试结果见最终验证；未运行像素比较。
- 根因：`settings_actions.dart:373` 的自定义色卡重建 scheme 时遗漏 surfaceColor、neutralDerived、系统色解析；`custom_theme_page.dart:270` 的编辑预览遗漏 pureBlackDark。
- 影响：自定义背景色/中性派生/跟随系统色或纯黑设置下，用户看到的色卡及预览可能与应用后不同。
- 建议：提取对任意 CustomThemeEntry 的纯配色解析函数，让活跃主题、色卡、编辑器共用；用同配置输出 primary/surface/container 一致性测试约束，不复制第三套算法。

### HBK-AUDIT-009 — 搜索控件测试不能编译

- severity：P2（验证阻塞）
- status：已补 import，运行结果见下方。
- 证据：固定快照的 `fushi/test/widgets/fushi_search_bar_test.dart:419` 引用 FushiSpringCurve，却未导入声明文件。实跑编译器报“isn't a type / Method not found”。
- 修复：导入 `fushi_motion_tokens.dart` 并改用现有 `FushiSpringCurve.spatial` 常量，没有删测试或放宽断言。

## Validation

最终结果见文末：完整 analyze 零问题，分批累计 90 项定向测试通过；未完成实机视觉验收。失败与中断的历史轮次不计入通过数。

## 给 CC 的建议与集成顺序

1. 先收口当前标题栏/透明渐变修改，记录最终 HEAD，再挑拣本分支修复；共享控件修改按函数范围复核，避免以旧文件覆盖新实现。
2. 优先处理大字体页头问题及主题预览与实际配色不一致。它们影响可用性与用户设置的可信度，优先于继续替换装饰样式。
3. 把“浮动”拆成可验证行为：内容可以滚到哪、渐变覆盖多高、何时收起、焦点进入如何恢复。至少测鼠标滚轮、连续触摸滑动、键盘、窗口缩放与系统文字缩放。
4. 在最终集成 HEAD 上跑完整 analyze，以及本次共享组件/设置/主题定向测试；图标迁移相关测试要实际编译运行。热重载成功只说明当前应用能编译，不代表 test 目录或所有交互正常。
5. 新增接口的同名参数需跨主题转发一致；用行为测试验证 onTap、onBack、autofocus、搜索提交，避免只以源码字符串守卫证明功能。

## Next Scope

- 在 CC 最终集成版本做实机视觉与输入验收：桌面缩窄、Android 字体缩放、库页/发现页/媒体服务器页、亮暗主题与系统减弱动态效果。
- 复核快照之后的标题栏、顶部渐变、媒体服务器背景修复，检查命中区域、焦点及滚动遮挡。
- 本次没有完成全应用逐页验收，不可将本报告解读为“大改全部通过”。

## 第二轮：阅读器、媒体库、无障碍与验证链

### Scope

6 个子代理先后按导航、共享控件、设置主题、阅读器/查词、媒体库、无障碍与测试链分工；并行受本机槽位限制。覆盖范围扩展到媒体库下载/导入入口及游戏页面，但不替代业务端到端验收。

### HBK-AUDIT-010 — 同下载状态的漫画章节使用重复 sibling key

- severity：P1；本轮新样式提交引入（bc6bca9a161）。
- status：已实现修复，自动化结果见最终验证。
- 根因：`fushi/lib/src/media/manga/library/manga_chapter_list.dart:275` 把下载状态作为 Column 直接子节点 key，多章同状态即重复。
- 修复：外层以 chapter.key 保持身份，下载状态探针移到各行内部；排序、下载状态变化保留章节 State。
- 测试：`test/media/manga/manga_chapter_identity_test.dart`。

### HBK-AUDIT-011 — 面板换侧及宽窄切换会销毁阅读器设置会话

- severity：P1；新增侧栏切换器使原有会话生命周期问题可触发。
- status：已实现修复，真实应用窗口操作仍待验收。
- 根因：`reader_desktop_chrome.dart:895` 左右换侧改变无 key 兄弟的次序；compact 断点还在两棵布局间移动会话，销毁共享 controller。
- 修复：内容/rail 稳定 key，路由拥有唯一会话 GlobalKey。
- 测试：`test/reader/reader_panel_switcher_side_state_test.dart` 验证双向换侧、1280→420→1280、草稿与 State 身份和偏好。

### HBK-AUDIT-012 — MD3 迷你播放条缺失跟随音频入口

- severity：P2；本轮样式改版回归。
- status：已恢复 `audiobook_play_bar.dart` 的 AudiobookFollowAudioButton。
- 根因：迷你播放条删除按钮，但 chrome 仍把用户底栏配置中的跟随入口当重复项过滤。
- 测试：`test/media/audiobook/audiobook_mini_player_follow_test.dart`，320/720px，激活及持久化。

### HBK-AUDIT-013 — 导航按钮没有读屏激活动作

- severity：P2。
- status：已补齐 `adaptive_navigation.dart` 的 mini capsule、FAB、rail menu 的 Semantics.onTap。
- 根因：语义包装 excludeSemantics:true 丢弃子节点，但没有提供自身 tap。
- 测试：`test/widgets/adaptive_nav_semantics_actions_test.dart` 直接发出语义 tap，校验回调。

### HBK-AUDIT-014 — Aa 的“更多歌词设置”被记忆页覆盖

- severity：P2。
- status：已实现入口定向修复。
- 修复：仅该入口请求 lyrics，普通设置入口保留 lastSettingsTab；请求页不可见时仍回退有效记忆页。
- 测试：`test/reader/reader_settings_requested_tab_test.dart`。

### HBK-AUDIT-015 — 查词 M3E inline 调色未接入主题热切换

- severity：P2；新增于 6eafd1653db。
- status：源码路径确认，待 CC 修复与真实 WebView 复现。
- 根因：`fushi/assets/popup/popup.js:5687–5713` 写入一次性标记及不可恢复的 inline !important 背景/文本颜色；`dictionary_popup_webview.dart:1475–1478` 热更新只注入 CSS 变量。
- 影响：暗→浅可能残留暗块，浅→暗不运行调色。
- 建议：保留并恢复原始内联值，把可逆调色接到主题更新；避免重建词条破坏选择状态。

### HBK-AUDIT-016 — Mihon 连续重排存在旧排序竞态

- severity：P2；本轮 970b80 系列改动。
- status：源码风险，未运行复现，未改动。
- 路径：`mihon_installed_sources_section.dart:202–233,324` 保存中仍允许重排；`mihon_manager.dart:1250–1261` 依据旧 row.sortOrder 跳过写入。
- 触发：A0/B1→BA 的保存尚未完成，再拖回 AB，第二次可能跳过全部写入，最后数据库仍为 BA。
- 建议：串行提交最后一次排序意图并依据当前存储比较，或保存期间一致禁用拖拽与移动菜单。补受控异步完成顺序测试。

### HBK-AUDIT-017 — 隐藏库页仍可能参与焦点和返回处理

- severity：P2；历史基线风险，不归咎本次样式改版。
- status：源码风险，未复现，未改动。
- 路径：`media_library_shell.dart:229` Offstage 缺 ExcludeFocus；`reader_fushi_history_page.dart:680`、`home_video_page.dart:3801` 的多选 PopScope 未结合当前可见子页。
- 建议：在 section 可见性层统一裁剪焦点/返回参与资格；以切 tab 后键盘遍历、Android back 的真实操作复核。

### HBK-AUDIT-018 — 全量 analyzer 的测试编译错误及 lint

- status：初次完整 analyze 报 41 项，逐项修复后重跑，结果见最终验证。
- 修复包含 import、真实 BuildContext、当前主题预设 API、局部声明顺序和视频高度断言语法；未删除失败用例。字典空态 chip 的未使用删除参数及其不可达状态代码一并清理。

### Next Scope

优先在 CC 最终集成 HEAD 验证大字体双行页头、查词热切换、连续重排竞态、隐藏库页焦点/返回；本轮不宣称这些风险已经修复。


## 第三轮：CC 后续提交只读复核

### Scope

固定后续 HEAD：`535f251b960accfc4248f9456f313e3c698a2ecc`；范围 `1a5424c847a..535f251b960` 共 17 提交、60 文件。另有 18 个 i18n 未提交文件未审查。未编辑 CC 工作区。

### HBK-AUDIT-019 — 发现筛选栏无溢出时仍淡掉首项

- severity：P3；后续快照新增问题。
- status：源码几何证据，待真实页面验收；未在旧快照修复分支修改。
- 根因：`discovery_header.dart:117–123` 将无水平内边距的筛选行直接放进 `FushiHorizontalEdgeFade`；`fushi_horizontal_edge_fade.dart:23–42` 始终把两端 16px 淡掉，未判断溢出及位置。
- 建议：按 extentBefore/extentAfter 独立启用两端渐隐；验证无溢出、起点、中段、终点。先保证首项文字、选中态与图标完整。

### 集成注意

本轮未确认新的 P1/P2；双行大字体、同次拖动阈值等既知问题仍存在。`reader_desktop_chrome.dart` 在后续提交新增 tooltip 分离逻辑，合入本分支时保留该逻辑；不要拷贝整个旧文件覆盖它。其余核心修复相关文件在后续 17 提交未变。本次仍需 CC 最终集成 HEAD 的实机验收。

### 通知状态

用户明确授权通知 CC。已尝试现有会话 attach 和 CLI ListAgents/SendMessage；后台控制管道不可达，ListAgents 未列出目标会话，消息没有送达。未停止、重启或恢复目标会话来强行投递。最终交接文件应包含提交哈希、测试结果、本报告和未完成项；保留失败状态，不将落盘交接材料表述为 CC 已收到。

## 验证边界与工具记录

- 使用 Flutter 3.47.6；所有 flutter analyze/test 经 `dartvm.exe tool/heavy.dart -- ...` 申请机器级单槽位。
- 滚动手势单独测试已退出 0（2 项）。首轮 6 文件行为测试退出 1（25 通过、10 失败），不能计为通过；其后完整重跑用于确认修订。
- 测试宿主中的语义句柄、平台服务装配与 SQLite 初始化分别修正；输入/语义测试明确使用 NoSplash，未测试 GPU shader 的渲染效果。Glass shader 预热也报告资源缺失并回退，因此本轮无玻璃视觉验收结论。
- 第一次全量 analyze 为 41 项；第二次仅新测试的 2 处同名导入冲突，已修正后再跑。
- `tool/bug.dart check --no-scan` 退出 1：BUG-2954 与 BUG-2955 各有两条文件，四条都已存在于基线 HEAD。没有为通过审查而重编号其他工作的历史记录。新增 BUG-2980/2981/2982 的取号扫描覆盖本地及已缓存远端，跳过 fetch。
- 中间一次测试卡在 settings fixture 后被定向终止；该轮不能视为完成或通过。后来将真实数据库初始化移到 tester.runAsync 并加 60 秒用例超时继续诊断。

## 最终验证（分批退出结果）

- 核心行为组：34 项通过，exit 0（`style-core-tests.log`）。涵盖共享控件、系统色通知、章节身份、导航语义、搜索输入、阅读器会话与迷你播放条。
- 设置局部断点组：4 项通过，exit 0（`style-settings-tests.log`）。真实平台服务装配和数据库初始化后，Material/Glass 的回车与点击都打开详情；诊断 print 已移除，断言保留。
- 滚动手势组：2 项通过，exit 0（`style-scroll-test.log`）。
- 扩展组首次：47 通过、3 失败，exit 1（`style-extended-tests.log`）。主题一致性 4 项和歌词初始页 2 项已通过；两个旧测试文件因 shader/保留旧路由失败，修复测试宿主后单独复跑，结果继续追加。
- 重复全量 analyze 在系统显著变慢时被终止，不能算通过；后续最终输出另记。

BUG 对照：001→2980，002→2981，003→2984，004→2985，005→2986，006→2987，008→2988，010→2982，011→2989，012→2990，013→2991，014→2992。均有独立文件；其余风险保留审查ID，不标记已修。


### 最终退出结果补记

- 最终完整 `flutter analyze --no-pub`：**exit 0，No issues found**，239 秒分析（`style-analyze-result.log`）。
- 两个修订测试文件复跑：**24 项通过，exit 0**（`style-extended-recheck.log`）。先实际关闭旧标签弹层再开宽屏，保留几何/路由断言；NoSplash 只隔离 GPU 水波纹。
- 去重统计：核心 34 + 设置 4 + 滚动 2 + 扩展中未重跑的 26 + 最终复跑 24 = **90 项定向测试通过**。没有运行全仓测试或五平台/真实设备验收。
- `git diff --cached --check` 通过。bug 索引检查的基线重复编号仍未解决；没有把它列为通过。
- 最终建议顺序：合入这 12 类功能修复 → 复测最终集成版本的大字体/窗口缩放/触摸及键盘 → 修复查词主题热切换、连续重排竞态 → 收口渐隐等视觉细节。

## 第四轮：集成版本复现与 M3 Expressive 对照

### Scope

- 固定审查基线：`4f11ba96759`。该合并提交已将上一轮修复 `45fc6d88b17` 纳入 CC 分支；本轮独立工作区快进到此处后固定审查，没有改 CC 活动工作区。
- 复核 `535f251b960..4f11ba96759` 的存储配色、浮动工具栏、游戏标签、有声书面板、OCR 设置及模型迁移；三个子代理分别承担无障碍/路由、设置/排序、阅读器/查词。主代理核对官方规范、运行复现并汇总。
- 新增显式执行的复现文件和报告，没有修改业务代码。本节的失败测试用于证明未修问题，不计入上一轮的 90 项通过，也不代表修复已完成。

### Findings

#### HBK-AUDIT-020 — Android 发现页搜索框触控高度不足

- severity：P2；status：真实组件 widget 语义测试已复现；属于无障碍要求不符合。
- 路径：`fushi/lib/src/utils/components/fushi_material_components.dart:1284,1360`、`fushi/lib/src/pages/implementations/discovery_header.dart:176`。
- 根因：regular 搜索固定 40 高，手机发现页直接采用该布局，没有扩大搜索输入框的可点击区域。
- 证据：390×844 Android 布局中，实际语义节点 bounds 为 `(20,374)-(370,414)`，即 **350×40**；`androidTapTargetGuideline` 要求至少 48×48，失败。只把日志明确命中的搜索框列为已证实，未把其他按钮的视觉尺寸推断成命中尺寸。
- 影响：手机触摸目标偏小。官方允许精确鼠标场景使用更小目标，不能用此例一概判定桌面所有 40 高控件违规。[Android 无障碍规范](https://developer.android.com/guide/topics/ui/accessibility/apps)
- 建议：触控布局提供至少 48 高的实际命中/语义区域；如保留 40 高外观，让布局为扩大的目标保留空间，避免相邻目标重叠。修后重跑 `fushi/test/widgets/discovery_m3_touch_targets_repro.dart`。

#### HBK-AUDIT-021 — 查词制卡按钮交互态覆盖语义底色

- severity：P2；status：CSS 层叠静态证据，未完成真实浏览器视觉复现。
- 路径：`fushi/assets/popup/popup.css:2723–2725,2739–2760,2914–2934`。
- 根因：未制卡按钮默认 primary/onPrimary；后置通用 hover、focus-visible、active 规则与默认底色选择器 specificity 同为 `(0,3,1)`，将 background-color 覆盖为 currentColor 的透明混色。前面的 header 状态规则只加 background-image，不能保住底色。
- 影响：交互时原 primary 底色丢失，但图标仍为 onPrimary，破坏配对关系，存在可读性风险；尚未实测最终像素对比率，不宣称所有主题都低于某个比值。
- 建议：通用规则排除带语义底色的 header 按钮，或为其显式保留 base color、仅叠加状态层；覆盖未制卡/duplicate/latest 与三个交互态。依据：[Material 颜色角色及配对](https://m3.material.io/styles/color/the-color-system)。

#### HBK-AUDIT-022 — OCR 强调卡文字未使用配对前景

- severity：P2；status：真实 ThemeNotifier 配置和 RenderParagraph 已复现；属于颜色角色使用不符合。
- 路径：`fushi/lib/src/media/manga/manga_ocr_settings_section.dart:1473,1505,1514,1532`。
- 根因：FushiCard 使用 secondaryContainer，标题/说明显式继承外层 textTheme 颜色，覆盖卡内 DefaultTextStyle 的 onSecondaryContainer。
- 证据：真实可保存配置 seed=`0xFF6750A4`、surfaceColor=`0xFFFFFFFF`、brightness=dark；设置页和阅读器侧栏两例均实际得到 alpha≈0.8706 的黑字，而配对前景为浅色 RGB≈(0.9529,0.8549,1.0)。测试先断言该容器为深色，且 surface 前景为黑色；未用任意手造 ColorScheme 制造反例。
- 影响：这种自定义主题下强调卡文字难以辨认；没有将其扩大为“默认深色主题也必然不合格”。本轮 `a1eef94face` 将已有侧栏卡样式扩大到独立设置页。
- 建议：标题、说明和状态文字从卡片的配对前景派生，保留各自排版角色；不要直接沿用页面 onSurface。依据：[Material 颜色角色及配对](https://m3.material.io/styles/color/the-color-system)。验证：`fushi/test/media/manga/manga_ocr_model_card_color_repro.dart`。

#### HBK-AUDIT-023 — 浮动 chrome 的透明度仍共用 spatial 弹簧

- severity：P3；status：源码规范偏差/改进建议，不是已复现崩溃。
- 路径：`fushi/lib/src/utils/components/fushi_floating_chrome.dart:663,926,1049`。
- 根因：位移/缩放及透明度共用 spatial 曲线；透明度用 clamp 限幅，避免越界，却仍沿用空间运动的时间轨迹。
- 建议：空间变化保留 spatial，透明度单独采用 effects，并共同响应减弱动态效果。官方将空间属性与颜色/透明度等 effects 区分；不把“所有动画必须有回弹”当成要求。[Material motion](https://m3.material.io/styles/motion)、[官方 MotionScheme](https://developer.android.com/reference/kotlin/androidx/compose/material3/MotionScheme)
- 验证边界：本轮常规/减弱动画的嵌套 chrome 有限几何与稳定 body 用例均通过；此前 opacity 超范围问题已有 clamp 修复，本条不重复报该崩溃。

### 已有发现的证据升级与更正

- **HBK-AUDIT-007，P2**：当前紧凑工具栏高度是 **56**，更正早期交接中的 48。真实 FushiPageScaffold 双行标题在 text scale 1.0、1.3 通过，2.0 出现 **底部 RenderFlex 溢出 27 px**。建议按缩放后的文本自适应高度，并同步修正浮动 chrome 占位；不要通过禁用文字缩放掩盖问题。
- **HBK-AUDIT-015，P2**：生产 JS 原函数在最小 DOM/style/RAF mock 中复现三项失败：暗→浅不还原、浅→暗不调色、浅色下重新调用现有调度器仍不还原。两个初始主题对照通过。升级为函数级运行复现，仍未做真实 WebView 热切换验收。建议保存原值并实现可逆调色，接入实际主题更新链路。
- **HBK-AUDIT-016，P2**：真实 MihonManager + 内存 Drift，通过 gate 阻塞第一次写入；A/B→B/A 未完成时再次请求 A/B，漫画/视频两例最终 manager 顺序均为 B/A，丢失最后意图。失败发生于 manager 断言，后续持久化断言未执行，不将其写成独立落库实测。建议统一协调拖拽/菜单/下载量排序，串行应用最后意图并使用最新存储或完整写入；仅增加串行锁而仍按旧 row 跳写不足以修复。
- **HBK-AUDIT-017，P2**：真实 MediaLibraryShell 中放入受控 Focus/PopScope 子页；切走后隐藏页仍多收到一次键盘事件，隐藏多选的 PopScope 仍消耗一次 back，两个用例均失败。已复现 shell 生命周期契约，尚未逐个真机验收完整书库/视频页；原页面路径及历史基线归属保持不变。建议可见性层统一控制焦点资格和返回注册。

### M3E 未报错项及验收边界

- 共享 expressive springs 参数与官方 Android token 一致：spatial fast/default/slow 为 damping/stiffness `0.6/800、0.8/380、0.8/200`；effects 为 `1/3800、1/1600、1/800`。因此不把共享弹簧数值列为不合规。[官方 motion tokens](https://raw.githubusercontent.com/material-components/material-components-android/master/lib/java/com/google/android/material/motion/res/values/tokens.xml)
- FushiIconButtonControl 的 Material 外观可以是 40，但 padded 命中布局为 48；本轮没有把外观 40 误报为触控缺陷。自定义圆角、数据图配色、桌面密度不自动等于违反 M3E。
- 存储环图与图例/列表使用同一排名映射，本轮未确认新的颜色含义错位。OCR 旧/未知模型键回退与各消费链一致，未确认新增迁移遗漏。有声书面板未找到新的确定性回归。
- 排版按角色与可读性判断，不要求所有文字都改 display；文字对比应按实际前景合成、背景及字号测量，未做全应用对比率统计。[Material typography](https://m3.material.io/styles/typography/applying-type)
- 本轮没有全应用逐页截图、真机触摸验收或五平台验证；因此结论是“存在明确不符合项”，不能出具全面 M3E 合格结论。

### 验证与复现命令

- Flutter 3.47.6，全部 Flutter 执行经 `dartvm.exe tool/heavy.dart` 机器级单槽位。第一组 10 例 **4 通过、6 失败**；颜色组 2 例 **0 通过、2 失败**。Node 5 例 **2 通过、3 失败**。共 17 例：6 个对照/边界通过，11 个未修问题断言失败，无测试编译失败。
- Dart 文件以 `_repro.dart` 结尾，Node 文件在 `tool/review_repros/`，作为显式执行的待修复现，不接入默认测试发现；修复后应迁为正常回归测试。
- 在 `fushi/` 执行 wrapper + `flutter test --no-pub --concurrency=1 test/widgets/discovery_m3_touch_targets_repro.dart test/widgets/fushi_floating_chrome_accessibility_review_repro.dart test/media/manga/mihon_manager_reorder_concurrency_repro.dart --reporter expanded`。
- 颜色组同样通过 wrapper 显式执行 `test/media/manga/manga_ocr_model_card_color_repro.dart`；仓库根执行 `node --test tool/review_repros/popup_m3e_theme_transition.repro.mjs`。
- 原始日志存放本地 `.codex-test/review-2026-10-06-round4/`，已复现项同步到本地忽略文件 `docs/REGRESSION_BUGS.md`。本轮没有重新跑完整 analyze；上一轮结果只适用于当时的修复提交。

### 给 CC 的处理顺序及通知状态

先修复 020/022 的触控与颜色、007 的文字溢出，再处理 016/017 的交互状态、015/021 的查词颜色；023 动效分离和019渐隐收尾。保持修改函数级范围，不以旧文件整体覆盖新工作。

已确认 CC 合入上轮提交；本轮报告、复现与日志另行交接。现有实时通知通道此前无法连接目标会话，不能将持久交接文件更新表述为已收到或已读。

### Next Scope

在 CC 修复后的明确 HEAD 重跑上述契约，再做 Android 字体 2.0/触控和桌面键盘验收；真实 WebView 覆盖明暗双向热切换及制卡按钮三个交互态。有声书增加真实 controller、关闭跟随、章节边界和窄高窗口的运行验证。
