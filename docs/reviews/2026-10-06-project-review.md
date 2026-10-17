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
- `tool/bug.dart check --no-scan` 退出 1：BUG-3001 与 BUG-2999 各有两条文件，四条都已存在于基线 HEAD。没有为通过审查而重编号其他工作的历史记录。新增 BUG-2980/2981/2982 的取号扫描覆盖本地及已缓存远端，跳过 fetch。
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

## 第五轮：后续 M3E 改版、修复回归与通知通道验证

### Scope

- 第一批固定基线 `a43a8d67e0c`，审查 `4f11ba96759..a43a8d67e0c` 中的选集面板、Flutter/原生悬浮球、扩展调色板、查词调色及既有修复。三个子代理分工，主代理统一运行 Flutter、复核证据。
- 第二批仅将独立审查工作区快进到 `3b757300599`，补查 `07a3781cca4`、`1134311591a`、`3b757300599` 的隐藏页、主题调色和按钮状态色修复。没有编辑 CC 工作区的未提交文件。
- 本轮只交付报告和显式复现，不修改业务代码；重复/旧问题明确标注归属，不将所有发现归咎于最新提交。

### Findings

#### HBK-AUDIT-024 — 选集卡片的大字状态与标题相互覆盖

- severity：P2；status：真实 VideoEpisodePanel widget 已复现；新增于 `bb1aaee2010`。
- 路径：`fushi/lib/src/media/video/video_episode_rail.dart:94,227,370,419`。
- 根因与影响：卡片固定 16:9 高度，上方“正在播放”及下方两行标题各自放大，彼此没有布局约束。320 宽、文字 2.0 时两个实际 Text 矩形重叠，妨碍阅读，不只是 RenderFlex 是否报错的问题。
- 建议：依据文字尺度为文本保留空间，或把状态放到不与标题竞争的布局区；保留系统文字缩放。验证：`test/media/video/video_episode_panel_accessibility_repro.dart` 第二例。

#### HBK-AUDIT-025 — 换季浏览后重开选集面板丢失当前集焦点

- severity：P2；status：真实面板及生产 Gate/PanelFocusScope 组合已复现；新增焦点路径的生命周期遗漏。
- 路径：`fushi/lib/src/media/video/video_episode_panel.dart:108,146,411`、`video_episode_rail.dart:110–125`。
- 根因与影响：打开面板的焦点认领只放在旧 rail 的 didUpdate false→true；浏览另一季后关闭再开，面板重置到当前季并新建 rail，initState 只 reveal 不领焦。键盘/手柄导航没有从当前集开始。
- 证据：保留原 rail 的第一次打开能领焦；切 s2→关闭→打开后回到 s1，当前集节点存在但 hasFocus=false。建议在新实例可见时也安排焦点认领，避免抢走用户已经主动移动的焦点。验证同一复现文件第一例。

#### HBK-AUDIT-026 — 悬浮球多列动作只有 40×40 触控区域

- severity：P2；status：真实位置点击已复现；历史问题在新 M3E 样式中仍保留。
- 路径：`fushi/lib/src/reader/reader_floating_ball.dart:594–595,856–861`。
- 证据：短视口的多列布局没有额外文字命中区；动作框实际为 `(256,11.2)-(296,51.2)`。中心点击触发一次，距中心上方 22dp 点击未触发；第一次点击只调用测试动作、不关闭菜单，因此不是“菜单已关闭”的假失败。
- 建议：触控模式扩大到至少 48×48 的实际目标，同时为相邻按钮留足空间。依据：[Android 触控目标规范](https://developer.android.com/guide/topics/ui/accessibility/apps)。验证：`test/widgets/floating_ball_accessibility_review_repro.dart`。

#### HBK-AUDIT-027 — 触摸展开悬浮球后 Esc 关闭失效

- severity：P2；status：真实按键事件已复现；本轮新增快捷键功能未覆盖混合输入。
- 路径：`fushi/lib/src/reader/reader_floating_ball.dart:385,525`。
- 根因与影响：触摸展开刻意保留正文焦点，但 Esc/B 只注册在球的焦点子树内。触摸展开后发出 Esc，菜单仍在；传统焦点模式下同样操作能关闭并归还正文焦点。
- 建议：使关闭快捷键作用域覆盖展开状态对应的实际焦点路径，或在键盘介入时转移到菜单焦点；不能只依赖展开瞬间的 highlightMode。验证同一悬浮球复现文件两项对照。

#### HBK-AUDIT-028 — 悬浮球未响应系统减弱动态效果

- severity：P2；status：组件几何及宿主接线已复现；历史遗漏。
- 路径：`fushi/lib/src/reader/reader_floating_ball.dart:291,335`、`fushi/lib/src/floating_ball/app_floating_ball_host.dart:1201`。
- 根因：组件只看 animate，宿主只根据 einkMode 传值，没有把 MediaQuery.disableAnimations 纳入；系统开启减弱动态效果时仍执行展开位移动画。
- 证据：disableAnimations=true 后展开，球左边从 368.2 继续移动至 344。测试的即时到位要求来自本仓“减弱动态效果时归零”的契约，不宣称官方 M3E 规定所有实现必须在 1ms 内静止。
- 建议：通过统一动效策略合并系统减弱动态效果与墨水屏偏好，展开/收起/拖拽收尾一致使用。验证同一悬浮球复现文件末项。

#### HBK-AUDIT-029 — 可逆调色记录持续保留旧词条 DOM

- severity：P2；status：生产 JS 函数加 DOM 边界 mock 已复现；`5200dfc98c7` 新生命周期问题，后续 `1134311591a` 仍存在。
- 路径：`fushi/assets/popup/popup.js:5611,5623,5640`（全局 Set）、`renderPopup` 换词路径约 `:6772`；`dictionary_popup_webview.dart:1592–1599` 的静态设置缓存。
- 根因与影响：每次调色把元素加入强引用 Set；只在 restore 时清空。固定深色、主题/静态设置未改变时连续换词，旧 DOM 已移除但 Set 仍保留，可能持续增长。
- 证据：连续替换 100 个词条后，Set 留有 99 个 isConnected=false 的词条。这是引用保留复现，不是实际 WebView 堆内存或性能测量。最新 KnownRoots 也只在 retone 时清理，未解决同主题换词生命周期。
- 建议：在词条替换/清空时释放旧根及其已调色元素，或改为按当前活跃根管理可恢复记录；保留明暗切换可逆性。验证：`tool/review_repros/popup_m3e_theme_round5.repro.mjs`。

#### HBK-AUDIT-030 — 扩展派生另一明暗时使用了错误系统主题种子

- severity：P2；status：Dart 数据链静态确认 + 真实 JS 消费函数复现，未做跨进程端到端；新增于 `ba69d70e8af`。
- 路径：`fushi/lib/src/models/theme_notifier.dart:68,1464,1476`、`app_model.dart:3841`、`tools/browser-extension/theme.js:156–157`。
- 根因：桌面 system-theme 的实际 ColorScheme 来自 OS accent，但新增 activeSeedColor 返回 _seedColor；system-theme 在该 getter 落到默认种子。扩展只收到浅色镜像、用户切为深色时，使用错误元数据派生缺失镜像。
- 证据：JS 用按该代码路径构造的首次浅色消息，已有浅色镜像对照正确；系统 seed `#e91e63` 的深色 primary 应为 `#ffb2be`，实际为默认色系 `#60d4ff`。payload 是根据生产 Dart 逻辑构造，不是从实机 IPC 捕获。
- 建议：同步实际有效系统方案；完整 Android 动态 palette 不保证能用单 seed 重建，可直接发送两种明暗的角色。验证同一 JS 复现文件末项。

#### HBK-AUDIT-031 — 排序写入中途失败缺少原子性

- severity：P2；status：真实内存 Drift 受控写失败已复现；原排序路径历史缺口，016 并发修复没有引入它。
- 路径：`fushi/lib/src/media/manga/mihon/mihon_manager.dart:1286–1303`。
- 根因与影响：一轮排序逐行写入但没有事务；第二次写失败时，第一行已提交且没有 reload。ABC→CAB 故障后实际存储为 A0/C0/B1，保留重复 sortOrder。
- 建议：将一次完整排序提交放进事务并同步成功/失败状态；不要仅捕获异常后忽略部分更新。对照已确认：失败后新请求能重新启动 worker 并成功，不报告“worker 永久卡死”。验证：`test/media/manga/mihon_reorder_failure_recovery_repro.dart`。

#### HBK-AUDIT-032 — 标题修复测试仍按错误的 1.3 倍容量预期断言

- severity：P2（验证阻塞）；status：现有测试两处失败，属于测试期望错误，不能据此重报生产溢出。
- 路径：`fushi/test/widgets/floating_title_capsule_clip_test.dart:134,193`。
- 根因：56 高胶囊的文本预算 54；22/12 字号在 1.3 倍下需要 `(22×1.2+12×1.25)×1.3=53.82`，仍放得下。测试却断言副标题消失、subtitleFits=false。
- 建议：按实际阈值分别覆盖可容纳及不可容纳条件，修测试注释中的旧高度推断；不要为过测试把产品改成更早丢弃副标题。

### 已有修复复核

- **007**：1.0/2.0、AppBar 安全区与裁切验证通过。2.0 下副标题转 tooltip，标题缩放封顶，是新的实现契约；旧常显副标题复现不能直接用来判修复失败。以上 032 是验证代码问题。
- **015**：observer 双向明暗、初始浅→暗、显式 retone 与 observer 幂等、离开 M3E 恢复均通过。旧问题已在函数层验证修复；029 是另一个生命周期问题，不能合并成“主题热切换未修”。
- **016**：上轮原样漫画/视频并发复现均通过；最新意图覆盖、Future 完成时序测试通过。031 属失败原子性缺口。
- **019**：按两侧剩余内容启用渐隐，五个生产调用没有 reverse:true，未把未使用的反向滚动假设报为实际回归；未做逐像素视觉验收。
- **021**：通用状态规则排除 header 的选择器、三种状态、三种语义底色与镜像已复核，新增 7 项 CSS 契约测试通过；没有真实浏览器像素对比结论。
- **017**：返回处理和基础焦点测试通过，祖先隐藏且自身仍为当前分区的焦点组合另行追加结果，不能先整体关闭。

### 验证结果与证据边界

- `a43a8d67e0c` 的 7 文件 Flutter 组：**74 通过、2 失败**；失败均为 032 的测试期望，无编译失败。新 3 文件显式复现组：**2 通过、6 失败**。
- 扩展原有 4 文件 Node 组：**49/49 通过**；包括 HCT fixture 对照和明暗派生。新 JS 复现：**4 通过、2 失败**。变更扩展资源的源码与打包镜像逐项 hash 一致。
- `3b757300599` 的 section visibility/视频返回组：**7/7 通过**；popup 可逆调色/按钮状态组：**11/11 通过**。新 JS 复现再次为 **4 通过、2 失败**，不重复累计。
- 函数 mock、源码断言、真实 widget、真实数据库分别按上述边界解释；未做全仓 analyze、全仓测试、实机 WebView/原生球/五平台视觉验收。
- 新文件使用 `_repro.dart` 及 `tool/review_repros/*.repro.mjs` 显式执行，未接默认测试发现；修复后迁成常规回归测试。本地原始日志归档至 `.codex-test/review-2026-10-06-round5/`，复现 open 项同步 `docs/REGRESSION_BUGS.md`。

### CC 通知通道实测

2026-10-06，普通执行后端实测 `AdministratorToken=False`，向目标会话 `91f6fb50-9475-423c-9a23-ab4f1ea67667` 登记的 named pipe 连接返回 Windows AccessDenied；只开文件完整访问没有改变该进程令牌。

用户切换到管理员 CLI 后，同样检测为 `AdministratorToken=True`、`CC_MESSAGE_PIPE_CONNECT_OK`，正式 `claude agents --json` 能列出目标会话。经官方 ListAgents/SendMessage 工具发出一次进度消息，返回 `success:true`，msg_id=`f896b6f6-5db6-4a16-869d-78b063a26241`，状态是进入目标收件箱、尚未读取。未修改管道 ACL，未中断或重启 CC；这是本机当前组合的实测，不推导为所有 Codex/CC 通信都必须管理员。

用户随后告知 CC 额度用尽，继续独立审查和提交，暂停调用 CC；最终结果通过审查分支及持久交接保留。

### Next Scope

先验证 017 祖先可见性焦点残留，再复核后续 `2d25bea555b` 动态工具栏动作折叠及 `bc65b9dc94c` 默认浮动正文的调用方。待 CC 恢复后，按 024/025/029/030 → 026/027/028/031 → 测试修订顺序处理，最终在集成 HEAD 重跑。

### HBK-AUDIT-017 修复残留实测补记

- severity：P2；status：最新 `3b757300599` 组件级复现，保持 open。
- 路径：`section_visibility.dart:56–58`、`home_page.dart:3296–3298`、`media_library_shell.dart:242`。
- 根因：发布给子树的 visible 已与祖先取与，但 ExcludeFocus 只看本层 visible。HomePage 的外层范围使用 excludeFocus:false，隐藏顶层 tab 后，内部当前库分区的 visible 仍是 true，因此其焦点没有被裁剪。
- 证据：与生产一致的外层隐藏/excludeFocus:false + 内层当前分区组合，实际 effectiveVisibility=false，却 hasFocus=true 且收到一个真实 keyDown；可见祖先对照通过。新增 `test/widgets/section_visibility_ancestor_focus_repro.dart` 为 **1 通过、1 失败**。该测试使用真实 SectionVisibilityScope 和 Offstage，未跑完整 HomePage 真机操作。
- 建议：焦点资格与返回资格使用同一份有效祖先可见性；同时把切 tab 后的焦点请求安排到可见性更新后，避免为同步请求绕过隐藏裁剪。现有 7 项返回/基础焦点测试不能证明这个组合已修复。

### 最新提交补查（固定到 `df4ae5b32a0`）

追加审查 `2d25bea555b`、`bc65b9dc94c`、`df4ae5b32a0`；未纳入 CC 随后的未提交 OCR/统计页改动。

#### HBK-AUDIT-020 修复残留 — 扩展命中区下边缘仍不可点

- severity：P2；status：真实 DiscoveryHeaderControls 边缘点击已复现，保持 open。
- 路径：`fushi/lib/src/utils/components/fushi_material_components.dart:1493–1495`。
- 根因：新 RenderBox 将下方边距里的点击 clamp 到恰好 `child.size.height`，而子 RenderBox 的命中边界不包含右边和下边。语义区域扩大了，但下方物理命中仍失败。
- 证据：现有语义/顶部边距/桌面密度 3 项全部通过；新增上下边缘对照中，顶部通过，下方失败。可见输入框 `(20,374)-(370,414)`，点 `(195,416)` 在扩展区域内却不能聚焦。
- 建议：转发到子节点严格内部的有效命中坐标，并处理零尺寸边界；覆盖上下左右扩展区域、角点及文字定位，而不只验证 Semantics bounds。显式复现：`test/widgets/discovery_touch_margin_edges_repro.dart`。

#### HBK-AUDIT-033 — 默认浮动页头覆盖更新日志首条内容

- severity：P2；status：真实 ChangelogPage 已复现；`bc65b9dc94c` 默认值改变引入。
- 路径：`fushi/lib/src/utils/components/fushi_material_components.dart:4211`、`fushi/lib/src/pages/implementations/changelog_page.dart:111–119`。
- 根因与影响：Scaffold 默认从上下布局切到浮动覆盖，只通过 MediaQuery 发布顶部 inset；已有页面显式 ListView.padding 只补底部，不消费顶部 inset，首屏内容直接出现在页头下面。
- 证据：真实 ChangelogPage 使用现有 initialReleases 测试注入口、390 宽、未滚动；页头矩形 `(20,20)-(270,76)`，第一条版本文字 `(88,34)-(220,62)` 完全落在页头范围内。不是由测试自建列表推断实际页面。
- 建议：逐一迁移依赖旧默认值的调用方，在滚动内容 padding 中消费真实顶部 inset；固定布局明确选择适用策略。`LeaderboardIntroView` 和 `LeaderboardWorkPage` 同样显式只补底部，为源码确认的待实测范围，不把它们计入已复现页面。
- 验证：`test/pages/changelog_floating_header_inset_repro.dart`。这批现有与新增测试共 **4 通过、2 失败**，分别对应 020 残留与 033。

#### HBK-AUDIT-034 — 自适应工具栏缩窄首帧仍以旧宽度布局

- severity：P2；status：真实 FushiFloatingTopBar widget 已复现；新增于 `2d25bea555b`。
- 路径：`fushi/lib/src/utils/components/fushi_floating_toolbar.dart:824–834`；实际 EPUB 调用 `fushi/lib/src/pages/implementations/reader_fushi/chrome.part.dart:3072–3099`。
- 根因：AnimatedSize 是 Row 的非 flex 子节点；split 虽已立即把多余动作放到 More，AnimatedSize 收缩动画首帧却仍沿用旧动作栏宽度，压缩不了当前行。
- 证据：760 宽、返回+10 动作初始布局无异常；改为 320 后 More 确实出现，但首帧 RenderFlex 向右溢出 **276 px**。验证：`test/widgets/floating_topbar_shrink_overflow_repro.dart`，1 项失败，不是等动画结束后才检查。
- 建议：父级收窄时先以当前可用宽度约束动作区域，再在约束内做过渡；或将必须立即收缩的布局与可平滑展开的动画分开。保留动作优先级与 hysteresis，补连续拖动窗口宽度的过程验收。
- 其余动作拆分、优先级、禁用状态与生产有限宽度路径未确认新的确定性问题；没有将未使用的无界宽度情况报错。

### 第五轮最终交接说明

本轮新增 HBK-AUDIT-024–034 共 11 条记录（其中032是测试期望问题，026/028/031注明历史归属），并确认017/020仍有修复残留。所有失败均已在各节说明验证层级和基线；没有生产代码修复、没有把失败复现当成通过测试。

用户随后确认 CC 额度恢复并重新授权通知；提交后可经已验证的管理员 CLI 通道交接。新发现优先次序补为033/034及020残留 → 017残留和024/025 → 029/030 → 其余项。后续验证应使用 CC 实际修复 HEAD，本报告不涵盖 `df4ae5b32a0` 之后的改动。


# Fushi 样式改版：第六轮全面补缺审查

本轮新增 **9 类已复现问题（HBK-AUDIT-035–043）和1项待故障注入的代码风险（044）**，补出了 HBK033 的遗漏页面，并修复了既有测试中的过时定位。生产代码由 CC 继续处理；本轮只提交报告、复现和测试维护。

## Scope

- 固定运行基线：`c16964b79a1b4f12f0d4e843dd3a789a8e93936c`，包含 CC 至 `5dc51724f1ff64fe34e35e2c652da499f0f2afda` 和前轮审查内容。
- 三个子代理分两轮并行：数据与启动、媒体工作流、布局与无障碍；随后补查设置保存、制卡/分享及同步/迁移界面。根代理复核代码、组织测试、校正复现、记录与通知。
- 枚举了全部 **41 处 FushiPageScaffold 调用**，逐类核对顶部避让策略。调用清单在 `round6-evidence/review-round6-page-scaffold-callers.txt`。
- 历史大范围 diff 有 1552 个文件，包含大量非样式变更；它只作为检索索引，**不代表逐行审完 1552 个文件**。CC 当时未提交的生产修改未混入测试快照。
- 审查过程中 CC 继续提交。只读追踪到 `280ac4768cb75bcf1a1f5eddec31ae32d44f901d`：已有更新中心、在线服务、迁移、引导、收藏夹、标签等避让修复，以及 HBK026–031/034 的相关修复。它们不自动继承本轮运行结论。新增035–043的根因在这一后续提交范围仍未改变；theme_notifier 的后续差异只处理扩展种子元数据。

## 覆盖矩阵

| 方面 | 本轮检查与证据 | 尚不能据此证明的部分 |
| --- | --- | --- |
| 偏好、升级兼容、Profile | 真实 ThemeNotifier + 内存 Drift；preferences/profile 定向测试；旧 OCR/Aidoku key 与缓存签名、工具栏迁移标记接线 | 全历史数据库迁移梯级、真实用户备份恢复、写盘中断 |
| 启动、错误与恢复 | watchdog、错误/超时显窗、预热门控；WebView 多终点销毁与死亡恢复测试 | 各平台冷启动、原生 renderer 真崩溃、后台被系统杀进程 |
| 设置保存 | 语言、快捷键、字体、自定义主题、Profile、schema 回调到持久化与启动加载源码链路 | 操作后杀进程重启、磁盘/DB 写失败、跨进程竞争 |
| 页面布局 | 41 个 Scaffold 调用分类；真实更新中心、在线服务及更新日志几何测量 | 所有页面、全部数据状态和设备形态截图验收 |
| M3E 与无障碍 | 真实语义触控区、实际文字/底色对比度、墨水屏/系统减弱动画；RTL 长法文、200% 文本、键盘选择 | TalkBack/VoiceOver 朗读顺序、真实 IME、17 种语言逐页视觉 |
| 下载与多选 | 真实任务 stream 刷新菜单；批量能力、取消确认、折叠集合、可见域、窄屏大字行为测试 | 实际 torrent/远程后端、网络中断与磁盘满 |
| 媒体导入 | 书/音频/漫画/视频/SRT/IPTV 的 busy、取消、mounted、失败通路；真实漫画/视频对话框受控 pending 复现 | 系统文件选择器、大文件复制、真实导入期间拔盘 |
| 阅读器与音频 | 非空真实控制器布局、跟随关闭持久化、同 spine 子章节 cue 选择、音频 dispose；正文/歌词恢复接线 | 原生解码、连续跨文件播放、音频焦点与系统后台恢复 |
| 字典与 native | 真实整合包拆解/重打包；缓存容量、失效、资源释放；C++ 异常边界源码 | native 编译、真实词典完整导入、各平台映射失败与 FUSE |
| 浏览器扩展与查词弹窗 | 14 个 Node 文件共125项；嵌套弹窗、过期回复、可见视口、菜单、IME快捷键、加载态、连接错误等；四份共享资产和打包镜像一致 | Chromium/移动浏览器实际注入、站点 CSP、真实 App IPC、浏览器渲染性能 |
| 制卡、收藏与导出分享 | busy、防重、逐项执行、停止、错误反馈、WebView token/dispose、待发队列事务 CAS 的源码接线 | 真 Anki、重复提交的网络故障注入、原生分享面板、实际媒体导出 |
| 同步、云盘、迁移 | 登录忙态/取消/错误、扫码防重、备份取消 token、迁移错误遮罩源码 | 真 OAuth 回跳、失效凭据、网络断连、关库恢复与进程重启 |
| 跨平台与性能 | Material/Apple/eink 分派与平台门控；scheme cache、LRU、释放/防重源码及部分测试 | Windows/macOS/iOS 各自包验收，帧时间、P95、内存曲线、耗电、长期使用 |

“源码已看”“组件/函数测试通过”“真实设备验收”是三个不同层级。本轮没有把前两个写成第三个。

## Findings

### HBK-AUDIT-035 — 换配色丢失旧配置解析出的明暗/纯黑语义

- severity：P2；status：已复现，新回归；相关提交 `4c32e76e6e4`。
- 路径：`fushi/lib/src/models/theme_notifier.dart:1204`、`:1284`、`:1881`。
- 根因：纯黑和明暗兼容兜底还依赖旧主题 ID，而 `setAppThemeKey` 只换 ID，没有固化当前有效的独立设置。
- 证据：旧 `black-theme + brightness_mode=dark`、无 `pure_black_dark` 时切 teal，纯黑从 true 变 false；旧 custom dark 且无显式 brightness 时切 blue，dark 变 system。显式保存过明暗/纯黑的对照通过。
- 建议：换色前解析有效值，只对缺少独立键的旧配置补写；与主题键一起原子持久化。补刷新、重启、Profile 切换验证。
- 复现：`fushi/test/models/theme_legacy_selection_contract_repro.dart`，1通过、2失败。

### HBK-AUDIT-036 — 下载状态刷新把旧菜单的“删除”变成“补对齐”

- severity：P2；status：已复现，新回归；相关提交 `468ceed6a93`。
- 路径：`fushi/lib/src/media/downloads/download_task_card.dart:231`；`video_download_jobs_panel.dart:701`、`:1451`。
- 根因：浮层用数组 index 表示动作，选中回调却访问刷新后的 `widget.menuActions`。
- 证据：真实音频任务 active 时打开菜单，任务变 completed 后旧“删除”被点击，`onPairAudiobook` 实际调用1次。未执行真实删除或下载。
- 建议：菜单结果绑定稳定动作对象/ID，执行前重新验证该动作能力和 busy 状态；不能让旧 index 映射到新动作。
- 复现：`fushi/test/media/downloads/download_task_menu_refresh_repro.dart`，1失败。

### HBK-AUDIT-037 — 漫画/视频导入忙碌时仍可被返回关闭

- severity：P2；status：真实对话框+生产 mixin 已复现；历史遗漏，不归为纯样式新回归。
- 路径：`manga_import_dialog.dart:151`、`:169`；`video_import_dialog.dart:704`；`import_flow_mixin.dart:101`。
- 根因：共享 `buildImportPopGuard` 未接入这两种对话框；漫画取消按钮也未随 importing 禁用。
- 证据：在真实 State 的 `runImport` 中保持受控 pending，触发 Navigator.maybePop，释放 gate 并等退出转场完成后，两种对话框都消失；action 本身没有 pop。没有真实文件复制。
- 影响：UI 关闭不代表导入取消。漫画 staging 的释放、后续进度通知与实际文件写入冲突属于源码风险，本轮未故障注入证明数据损坏。
- 建议：统一接入 busy 返回与取消策略；若支持取消，应有真实取消协议。SRT重导/IPTV 同型源码分支也应核对。
- 复现：`fushi/test/media/import/import_dialog_busy_dismissal_repro.dart`，最终2失败。首跑曾在转场未完时取值，属于无效假绿，已修正并排除统计。

### HBK-AUDIT-038 — 共享选择芯片的 Android 触控区只有32高

- severity：P2；status：已复现；历史问题在本次全域补查发现。
- 路径：`fushi/lib/src/utils/components/fushi_material_components.dart:2004`。
- 根因：Material 分支固定 `VisualDensity.compact + MaterialTapTargetSize.shrinkWrap`，没有区分触控与精确指针。
- 证据：Android 平台主题下真实 ChoiceChip 语义点击区 `122.5 × 32`，不是仅凭视觉尺寸判断。RTL长标签/200%文字、Tab/Enter、选中语义与系统减弱动画对照通过。
- 建议：保持视觉密度，同时给触控提供至少48的有效命中与语义范围；还要点边缘验证，不只扩大 Semantics。
- 复现：`fushi/test/widgets/round6_chip_accessibility_repro.dart`，2通过、1失败。

### HBK-AUDIT-039 — 实际有声书控制器分支在窄宽和中等高度溢出

- severity：P2；status：已复现，新布局回归；相关提交 `f023ebde0c76`、`29382e9f116b`。
- 路径：`fushi/lib/src/reader/reader_audiobook_panel.dart:40`、`:195`、`:464`、`:504`、`:523`。
- 根因：新版固定播放控件和倍速行超过可用宽度，旧440高阈值仍把更高的 hero 钉住。既有 panel 测试全传 controller:null，绕过实际传输控件。
- 证据：真实非空 controller，320×800 下两个 Row 分别右溢29/28px；400×460 下底部溢108px。400×420 的整块滚动分支通过，600×900 的真实跟随关闭和持久化回调通过。未加载原生音源。
- 建议：按实际内容约束切换紧凑/换行布局，固定 hero 策略也考虑内容高度与文字缩放，保留章节可用区域。
- 复现：`fushi/test/reader/reader_audiobook_controller_layout_repro.dart`，2通过、2失败。

### HBK-AUDIT-040 — 点击同一XHTML中的子章节后音频倒退到文件首句

- severity：P2；status：已复现，新回归；相关提交 `f023ebde0c76`。
- 路径：`fushi/lib/src/reader/reader_audiobook_panel.dart:805`、`:878`。
- 根因：正文导航带 fragment，但随后的 `sectionFirstCue(entry.index)` 只按 spine 找首句，忽略 `anchorCharOffset`；时间映射也没有子章节维度。
- 证据：两个子章节共用spine，第二项偏移100，真实 cue 缓存中应选10秒 cue，却请求0秒 cue；不同spine对照通过。只拦截最后原生 seek，没有实际播放。
- 建议：统一按 `(sectionIndex, anchorCharOffset)` 求条目起点，供显示和点击共用；锚点未知时避免强制重置音频。
- 复现：`fushi/test/reader/reader_audiobook_anchor_seek_repro.dart`，1通过、1失败。

### HBK-AUDIT-041 — 自定义主题下选中菜单文字对比度约2.12:1

- severity：P2；status：已复现；10月6日选中容器样式与旧前景不匹配。
- 路径：`fushi/lib/src/utils/components/fushi_material_components.dart:4963`、`:4999`。
- 根因：选中背景为 secondaryContainer，文字仍使用 onSurface。下载任务优先级菜单实际使用 selected 状态。
- 证据：通过生产 ThemeNotifier 的合法白surface+dark自定义主题，真实 Ink 背景 `#523F5F`，实际 RenderParagraph 前景为87%黑；先做 alpha 合成再计算，对比度 **2.119388:1**，低于该14px文字所需4.5:1。不是只检查 token 名称。
- 建议：文字、图标、选中指示和状态层按容器角色配对；同时检查显式 destructive color 的规则，避免机械替换所有颜色。
- 复现：`fushi/test/widgets/round6_menu_accessibility_repro.dart` 的颜色用例失败。首次未合成alpha的2.235数值已被最终结果替代。

### HBK-AUDIT-042 — 墨水屏菜单仍执行300ms装饰动效

- severity：P2；status：已复现；10月4日自定义菜单路径的产品契约遗漏。
- 路径：`fushi/lib/src/utils/components/glass/fushi_glass_overlays.dart:1545`。
- 根因：route 的 reduceMotion 只检查系统 MediaQuery，未使用含 eink 门控的 `fushiMotionEnabled`。
- 证据：真实 overflow menu 路由中 `isEinkTheme=true`、`fushiMotionEnabled=false`，transitionDuration仍300ms；系统disableAnimations对照为0且通过。
- 建议：统一动效资格入口，并验证开关菜单与退出的两个方向。
- 复现：同上菜单脚本。四例最终2通过、2失败；**菜单触控语义通过**，撤销仅凭minHeight44推断触控不足的候选。
- 分类：墨水屏关动效是产品要求，不说成M3E强制所有菜单无动画。

### HBK-AUDIT-043 — 整合包中的嵌套Yomitan词典被重打包为空

- severity：P2；status：生产拆包路径已复现；此前未覆盖的合入功能回归，非纯样式问题。
- 相关提交 `91749fb328c`，2026-10-05 12:39，已在最初审查基线中。
- 路径：`fushi/lib/src/models/dictionary_import_manager.dart:459`、`:842`。
- 根因：给每个词典根打包时把所有其他根加入 skipPaths。子词典的排除集合包含祖先根，`path.isWithin` 因而排除了子词典自己的全部文件。
- 证据：实际 `importFromFile → _importArchivedDictionaries → packDirectoryToZip` 生成两包，父包有index/bank，子包文件集合为空。只替换末端native单本导入为产物检查，没有声称完成native导入。
- 建议：只排除当前根下的其他子词典及独立归档，不能用祖先目录排除自身；补同层/嵌套/混合ZIP/MDX组合。
- 复现：`fushi/test/models/dictionary_nested_root_bundle_repro.dart`，1失败。

### HBK-AUDIT-044 — 待发卡片首次读库失败缺少错误终态

- severity：P2；status：代码路径风险，尚未故障注入，不计入9类已复现问题。
- 路径：`fushi/lib/src/anki/pending_mining/pending_mines_page.dart:150`、`:156`、`:294`；相关提交 `40e8ae22ecbe`。
- 根因：新增 `_loaded` 骨架门控只有 `await store.all()` 成功后才置true，reload没有catch或错误状态。首次读取抛异常时仍显示骨架，页面没有错误说明/重试入口。
- 建议：显式区分 loading/data/error，失败后结束骨架并可重试；刷新失败时可保留已有数据。以可控store异常、随后恢复的widget测试确认，避免用真实用户数据库制造错误。

## HBK033 与已知修复复核

- 在运行基线，更新中心筛选文字 y14..34 与标题 y20..76 重叠；在线服务首标题 y20..116 与页头 y20..76 重叠。真实页面各1例失败，统一记033，不新建重复编号。
- 静态同型遗漏：pending mines、收藏批量制卡、收藏夹有数据筛选、标签有数据、字幕工作台、迁移两页、新手向导。明确不用overlay的WebView/扫描/Apple路径不机械判错。
- CC 在审查期间已提交更新中心 `ed51dd3a02b`、在线服务 `280ac4768cb`、迁移 `8724034416c`、向导 `cd3b3b53f58`、收藏夹 `2eae02709a4`、标签 `f559f4e3dfd`、字幕 `5f69fba0350` 等修复。这里的失败是固定基线证据，不能据此说这些新提交仍失败。
- 本轮实际验证通过：HBK022 OCR两种展示的角色色修复 **2例**；HBK033更新日志首条避让 **1例**。
- 前轮017/020/024/025等没有本轮新的关闭证据；026–031/034的后续提交需在集成HEAD复测，不能把“看到修复提交”写成“已经验收”。

## 测试结果与维护

- 33个既有Flutter文件首批：501通过、13失败。逐一分型发现10处下载全选文本重名、1处懒构建任务卡未滚动、1处音频导入同名入口、1处chip结构强转失效。
- 仅修测试定位，保留原行为断言，新增未选中墨水屏图标对照。三个文件复跑 **49项全部通过**。与其余30文件去重后，既有测试 **515项通过**。
- 9份新显式复现，共 **22个有效用例：8通过、14失败**；失败对应9类问题及033补充，不代表14个独立bug。
- OCR/更新日志既有复现共 **3项通过**，不重复计入上述515项。
- 扩展14文件：**125项通过**；其中有源码守卫、纯函数和VM/DOM模拟，不等于125条浏览器端到端。
- `sync-mirrors.mjs --check` 通过；popup.js/css/html/selection.js四份共享源与vendor字节一致。
- 全量 `flutter analyze --no-pub` 已通过。首轮发现6项测试lint，已处理；最后测试维护完成后的最终树再次分析，**0 issue、exit 0**，日志 `review-round6-final-tree-analyze.log`。
- 显式失败文件命名为 `_repro.dart`，不会自动加入默认 `*_test.dart` 收集。修复后应转为正常回归测试。
- 所有Flutter命令经 `tool/heavy.dart` 调度，保留退出码和执行数；没有本地跑全量测试套件。

证据目录：仓库 `.codex-test/review-2026-10-06-round6/`；本报告旁 `round6-evidence/`。包括首轮/第二轮复现、既有测试、修订后重跑、分析、扩展、镜像和调用清单。重复运行不重复相加。

## 规范依据与判断边界

触控至少48×48、当前14px文字至少4.5:1，依据 [Android官方无障碍指南](https://developer.android.com/guide/topics/ui/accessibility/apps)。精确鼠标/触控板可更小，不能把桌面紧凑控件一概报错。M3的容器及其对应前景角色用于解释041根因；是否影响可读性仍以实际颜色测量为准。

芯片胶囊形状、配色偏好、标题降级为tooltip等属于设计选择或产品契约，不能仅因个人偏好说“不符合M3E”。RTL测试只是强制方向与长译文压力样本，没有覆盖所有语言的所有页面。

## Next Scope：还缺哪些真正的验收

1. **先处理035/036/039/040/043**：设置语义、错误动作、播放布局/定位、字典空包；037/038/041/042并行修。修完在最终集成HEAD运行本轮显式复现，再将绿色用例归入正式套件。
2. **真机与跨平台**：已连接Android HiBreak，现有 `app.fushi.reader` 是 `2.9.1-debug.16902`，安装时间2026-10-03，早于本轮代码。未覆盖安装、未清数据；不能用旧包当当前样式验收。下一步以独立测试包验收真实触摸边缘、返回/预测返回、IME、TalkBack、方向和字体缩放；Windows/macOS/iOS分别验原生窗口与WebView。
3. **端到端与故障**：实际系统picker→导入→取消/失败→重启、下载后端、连续音频跨章、OAuth回跳、Anki、备份关库恢复、扩展App IPC及真实浏览器站点。
4. **性能与打包**：长列表/大词典/长会话的帧时间、内存增长、冷启动与墨水屏刷新；release安装包、升级保数据、签名/权限与平台构建。当前缓存/释放源码检查和单测不能替代测量。
5. **全套CI与持续变更**：完整测试交PR CI；CC在本轮冻结点后继续提交的代码需单独验收。没有宣称整个仓库或所有平台“已无遗漏”。

附加历史源码风险待定向故障注入：词典旧 `persistDictionary` Future未await；同步测试连接/Anki重排预览在保存偏好await后才置busy；迁移导入获取目录发生在try/finally外；同名收藏导出缺少in-flight门且共用临时文件名。它们不计入9类已复现结论，重现结果需另行记录。待发发送链的序列化/事务只证明已检查相应状态转换，不能推导为防止所有重入。


# Fushi 样式审查 Round 7 — 2026-10-06

## Scope

冻结 CC 提交 `396f3907e5c21df105af2293e0dac1a0eeafc32f`，审查 worktree 合并点 `fe338b6a21dad70fedfffc5c75536a0b7a186b59`。本轮只增加报告、复现和测试维护，不修改生产代码，也不改 CC 的未提交文件。

三名子代理分别检查歌词新播放卡、有声书面板动效及路由生命周期、Windows 游戏覆盖层主题时序及待发卡片错误态；主代理复核证据并验证前轮修复。新增功能重点为 `396f3907e5c`、`251cfe8f754`、`64c7c05a67b`。故障注入使用内存数据库、模拟平台通道和组件，不触碰用户数据，不启动游戏或实际播放音频。

## Findings

### HBK-AUDIT-045 — 动画中快速切回章节页产生重复 GlobalKey

- severity：P2；status：真实组件已复现，新动效回归。
- 路径：`fushi/lib/src/reader/reader_audiobook_panel.dart:138`、`:139`、`:272`、`:977`、`:990`。
- 根因：AnimatedSwitcher 同时保留退出中的章节子树和重新进入的章节子树，两者复用 `_currentChapterKey` 和滚动控制器。
- 证据：章节→设置→章节，切换间隔20ms，Flutter 报 `Duplicate GlobalKey detected in widget tree`。系统减弱动画及墨水屏零时长对照通过。
- 影响：快速反切期间树状态不合法；目前证明的是 widget/debug 层错误，未据此宣称 release 原生崩溃。
- 建议：让同时存活的过渡子树各自拥有列表状态，或使用不会重复挂载章节内容的切换结构；保留稳定的页签状态，不靠延迟或吞断言规避。
- 验证：`fushi/test/reader/round7_audiobook_motion_repro.dart` 第一例失败。

### HBK-AUDIT-046 — 长章节标题和大字导致当前章自动定位失效

- severity：P2；status：真实组件已复现，新定位功能回归。
- 路径：`fushi/lib/src/reader/reader_audiobook_panel.dart:194`、`:218`、`:971`。
- 根因：目标尚未构建时按最小行高估算位置，只重试一次；真正多行高度更大，而 `_scrolledEntry` 已提前标记完成。
- 证据：100章、当前第80章、多行长标题、文字200%，等待动画和额外3秒后仍找不到目标。滚动位置3320，最大位置10676，目标行未构建。ticker 保持用户手动滚动的对照通过。
- 建议：按实际索引/行布局定位，并在目标确实可见后标记完成；避免无界重试，也不能改成每秒强制拉回当前位置。
- 验证：同上文件的远处长标题用例失败。旧 HBK039 的布局和 HBK040 的同 spine 锚点问题沿用原编号。

### HBK-AUDIT-047 — 原生覆盖层创建期间切换主题丢失最新配色

- severity：P2；status：生产控制器时序已复现，新主题接线回归。
- 路径：`fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:1384`、`:1385`、`:1483`。
- 根因：show 先捕获旧配色；异步创建期间 `_visible=false`，applyTheme 更新缓存后提前返回。show 成功后未补发最新配色，重复 applyTheme 又被缓存去重挡住。
- 证据：受控 MethodChannel gate 挂起真实 controller 的 show，此时切主题，释放 gate 后工具栏仍收到旧值4293717748，预期4280688152；同主题再调用也未纠正。
- 建议：区分期望配色与最近成功发送配色，show 完成后核对版本并同步最新状态。不要每次 build 无条件重发。
- 验证：`fushi/test/lookup/gal_hook_theme_show_race_repro.dart`，1失败。原生 ARGB 接收、6个角色字段、重绘入口及独立实例状态已静态核对；没有实际 D2D 窗口、DPI 或触屏验收证据。

### HBK-AUDIT-048 — 歌词播放卡在窄宽和200%文字下溢出

- severity：P2；status：真实完整覆盖层已复现；新头行窄宽回归与沿用的固定高度大字缺陷一并记录。
- 路径：`fushi/lib/src/media/audiobook/lyrics_player/lyrics_player_md3.dart:46`、`:49`、`:1838`、`:1926`、`:1932`。
- 根因：新增44高的封面/章名/操作行在窄宽竞争空间；底卡固定210高、顶栏固定56高，未随文字所需高度调整。前后版本对比表明，底卡高度160→210的增量恰等于新增头行44+间距6，原有大字余量未改变，不能把200%文字底溢全部归因于本次新增功能。
- 证据：接入章名、睡眠按钮及±10秒的真实 ReaderLyricsPlayerOverlay，280×640右溢2.9px；390×844、文字200%时顶栏底溢24px、底卡底溢8px。390×844默认字、320×640默认字、844×390横屏布局对照通过。
- 建议：根据可用空间与实际内容调整排列/滚动及歌词矩形，允许文字所需高度；不能只缩放整个交互组来消除溢出。
- 验证：`fushi/test/media/audiobook/lyrics_m3e_player_card_round7_repro.dart` 的两种布局失败。占位歌词区域不等于真实 WebView 排版验收。

### HBK-AUDIT-049 — 歌词±10秒按钮随整组缩放，触控区域不足

- severity：P2；status：显式 Android 主题下的 widget 真实边缘点击已复现，不是 Android 真机验收。
- 路径：`fushi/lib/src/media/audiobook/lyrics_player/lyrics_player_md3.dart:1974`、`:1976`。
- 根因：FittedBox 缩小包含所有播放按钮的 TransportGroup，把名义48尺寸一起缩小。
- 证据：320宽时±10秒按钮实际变换后的宽高均约44.67。最终复测明确 Android 平台，中心点击分别产生[-10]/[10]，中心纵向偏移23dp时两者均无回调，其他动作列表也为空。这是实际点击未命中，不是只凭视觉 bounds 推断。
- 建议：触控目标保留至少48×48；通过重新排列/减少同排动作解决窄宽，视觉图形可紧凑，命中区域不能被父级整体缩小。
- 验证：同上复现文件最后一例。精确鼠标输入的密度例外不用于 Android 触控。

### HBK-AUDIT-044 证据升级 — 首次读库失败永久保留骨架屏

- severity：P2；status：由 Round6 静态风险升级为故障注入已复现；不是新增编号。
- 路径：`fushi/lib/src/anki/pending_mining/pending_mines_page.dart:150`、`:155`、`:298`。
- 根因：reload 只在 store.all 成功后置 `_loaded=true`，失败没有 catch、错误终态或重试入口。
- 证据：真实 AppModel/Page 接入新建内存 Drift 数据库，初始化成功后仅拦截 pending_mine_queue 的 SELECT。正常空队列无骨架；一次受控查询失败产生未处理 StateError，最终骨架仍1个、重试入口不存在。日志中的 `escaped=null` 只代表 takeException 没再次取到异常，测试 zone 已先报告它，不代表业务捕获成功。
- 建议：显式 loading/data/error 状态，失败结束加载并提供重试；刷新失败可保留已有数据。
- 验证：`fushi/test/anki/pending_mines_load_error_repro.dart`，正常对照1通过、失败注入1失败。没有真实数据库或 Anki 副作用。

## 已验证修复及证据边界

- HBK017：隐藏祖先对焦点/键盘的隔离复测通过。删除已被生产移除的 `excludeFocus:false` 旧参数后，原行为断言保留；正式7例及祖先2例共9通过。
- HBK026/027/028：悬浮球真实边缘点击、触控打开后 Escape、系统减弱动画通过。
- HBK031：Mihon 第二次写入失败的事务原子性及失败后恢复通过。
- HBK034：悬浮工具栏760→320首帧缩窄不再溢出。
- HBK033：更新中心、在线服务、更新日志首条避让复测通过；这不代表所有历史列出的页面都已逐个运行。
- HBK029：100次相同主题替换的 detached node 清理通过；HBK015 明暗可逆仍通过。
- HBK030：旧 repro 人工写入错误默认种子，不能用于检验已修复的生产者；已替换为实际 ThemeNotifier→AppModel 元数据→扩展 JS 消费者验证。粉色、灰色、无系统强调色三个样本，各测缺失浅色/深色双向派生，共3例通过。未捕获真实 IPC，也没有覆盖 Android 原生完整动态色板分支。
- 新增正常路径：±10秒与睡眠菜单锚点真实点击通过；有声书侧板进场中关闭、三次完整打开关闭及晚回调通过。不能把这些 widget 结果当作持续播放、原生音频/窗口端到端证据。

## 测试结果与维护

- 本轮新显式复现5文件17例，10通过、7失败，对应上述5类新问题及044证据升级；不把7个失败计作7个独立bug。歌词强化边缘点击后重跑7例，仍4通过、3失败，不重复累加。
- 既有修复验证初跑43通过、两项旧签名导致的加载失败及一项 scrim 守卫失败；签名维护后9项焦点测试通过，scrim 守卫最终14项通过。去除重复运行后，本组12文件53项通过。
- scrim 的旧白名单没包含 `settings_home_page.dart` / `settings_kit.dart` 两个已审宿主。静态核对窄屏设置绕过 embedded shell、宽屏外壳不画第二份 scrim、详情壳只承载一份共享渐隐，未发现重复绘制证据。只精确补充两条许可和原因，保留其他全库扫描；此失败不记为生产问题，静态核对也不等于所有滚动场景运行通过。
- HBK030 实际 Dart→JS 验证3项通过。Node 最终5文件55项通过；初跑56项中有1项旧错误元数据夹具失败，删除该旧夹具并由更强的跨语言用例替代，不是降低行为断言。
- 相邻功能12文件首跑101通过、1失败：`reader_panels_redesign_test.dart` 仍要求第一次慢拖直接关闭，而 `772f479e4686` 已将生产行为改为满高→半屏→关闭。维护测试为“小拖回弹→慢拖半屏高度及底边→再次拖动关闭”，本文件10项重跑全通过，去重后相邻组共102项通过。未以删除断言绕过失败。
- 相邻测试首个调度请求等候10分钟后 exit75，未实际执行；共享名额释放后重试，不能把排队超时当测试失败。未终止 CC 的进程。修复复核53项与相邻102项合计155项，通过的真实 Dart→JS 3项、Node55项另列，不混同端到端覆盖。
- 最终树 `flutter analyze --no-pub` exit1，只有2项既有冗余 import：生产 `gal_hook_text_overlay_controller.dart:39` 与既有 `changelog_floating_header_inset_test.dart:8`。本轮新增/维护代码无诊断；没有把分析写成全绿，也没有为清警告修改生产源码。
- 显式失败文件为 `_repro.dart`，不会自动进入默认 `*_test.dart` 收集。所有 Flutter 测试/分析经 heavy，未运行全量测试；生产源码没有修改。

证据：仓库 `.codex-test/review-2026-10-06-round7/`；用户报告旁 `round7-evidence/`。`review-round7-commands.txt` 与 `review-round7-existing-test-files.txt` 保存命令参数和范围；原始错误夹具结果、排队退出、最终复测和分析日志均保留，后续结果不覆盖原始记录。

## 规范依据与判断边界

Android 触控48×48依据 [Android 官方无障碍指南](https://developer.android.com/guide/topics/ui/accessibility/apps)。本轮没有把形状、配色偏好或单纯使用非某个组件判作 M3E 违规。重复 key、加载错误态与主题竞态是行为缺陷；大字适配和触控命中属于可用性/无障碍要求。系统减弱动画与墨水屏控制均有对照，墨水屏关动效是项目产品契约。

## Next Scope

1. 优先修045重复 key、047创建时序和044错误态，再修046定位与048/049布局/触控。最终集成 HEAD 重跑显式复现，绿色后纳入正式套件。
2. Round6 的035–043及视频024/025、搜索020等仍需最新集成点复核；此处没有因看到提交而关闭它们。冻结点之后的 CC 修改另行检查。
3. 真机验证真实字体缩放、触摸边缘、TalkBack、IME、返回/预测返回；已连接 HiBreak 的现有10月3日旧包早于本轮改动，未覆盖安装或清数据，不能当当前版本验收。
4. Windows 原生游戏覆盖层要测 show/hide 与换主题交错、多显示器 DPI、触屏不抢焦点、D2D重建；本轮只有控制器模拟时序和静态原生边界核对。
5. 实际导入/取消/重启、连续跨章音频、系统 picker、Anki、浏览器 App IPC，以及帧时间、内存、冷启动、release升级保数据仍需要独立集成环境和实测。完整套件交 CI，本地不运行全量测试。

补充未复现候选：歌词睡眠按钮把剩余分钟复制进 LyricsPlayerData，歌词覆盖层依赖 controller 通知重建；暂停且无进度变化时，按钮提示中的剩余分钟可能陈旧。`lyrics.part.dart:440`、`:476` 与 `_SleepButton` `lyrics_player_md3.dart:1736` 是当前源码依据，尚无完整 Reader 页面时钟复现，不计入已确认问题，也不占新编号。

# Round 8 — 2026-10-06，全面复核并修复（进行中）

## Scope

- 冻结 CC 提交 `e147b5bf03db1c080434787411a7bf8630c712d4`，审查分支集成点 `d2378998701405c426df8745dba92ce32e3b570f`。包含 material_ui 迁移、Windows 新标题栏与原生悬浮球、游戏工具栏文字和主题接线。
- 用户本轮已明确授权 Codex 继续全面审查、直接修复确认的问题，并在修完后通知 CC。本节开始包含生产修复，区别于前七轮报告/复现交付。
- 七个范围分别保留证据：设计组件迁移、旧问题闭环、数据/失败/恢复、Android 交互、Windows 原生窗口、WebView/音频/IPC、性能与发布升级。未实际执行的部分不标为验收通过。

## Findings

### HBK-AUDIT-050 — Windows 原生悬浮球扩大的命中区域仍会穿透

- severity：P2；status：生产绘制/命中函数已复现并修复，离屏原生验证通过；真实 OS 输入与多显示器运行尚未验收。
- 路径：`fushi/windows/runner/floating_ball_window.cpp` 的 `ButtonAt` / `RenderMenu`，`fushi/windows/runner/floating_ball_geometry.h`。
- 根因：按钮视觉直径40 DIP，`ButtonAt` 已把命中直径扩大到48 DIP，但分层窗口相应外围像素仍为 alpha=0。Windows 在进入应用命中函数之前就把透明像素的鼠标消息交给下层窗口，扩大 Dart/C++ 几何范围本身不能补足真实窗口输入区域。
- 影响：±23 DIP 的边缘位置几何上属于按钮，却无法经操作系统投递给按钮；普通和墨水屏两种配色均受影响。48 DIP 是此组件既有产品契约，不把它泛化成所有 Windows 鼠标控件的强制规范。
- 修复：共享 `ButtonHitRadius`，仅在按钮实际可点击的48 DIP圆形区域绘制 alpha=1/255 的命中底层，保持40 DIP视觉圆盘。沿用动画显现门槛，其他空白区域保持透明；没有改变窗口不激活策略。
- 验证：真实 `RenderMenu` 输出的 DIB 与真实 `ButtonAt` 联合检查，DPI倍率1/1.5/2 × 普通/墨水屏共6组。修前6组外围 alpha=0；修后6组中心 alpha255、四向23 DIP alpha1且命中，四向25 DIP及窗口角落 alpha0且不命中。既有原生几何测试通过。
- 正式回归：`fushi/windows/runner/tests/floating_ball_hit_region_test.cpp` 接入 runner 的 `fushi_windows_floating_ball_hit_region_gate`。增加 opacity<0.05 的进场、收起及空菜单透明检查，并核对真实绘制提交的 `ULW_ALPHA` / `AC_SRC_ALPHA` / 32位 DIB 契约。Clang 与 MSVC 19.44 的编译/执行退出码均0；MSVC 使用 `/W4 /WX /wd4100 /EHsc /utf-8 /D_HAS_EXCEPTIONS=0`。6组、24次离屏绘制全部通过；完整 Flutter runner 构建尚未执行。
- 证据：`.codex-test/review-2026-10-06-round8/native/` 的 `ball-alpha-{compile,repro}.log`、`ball-alpha-fix-{compile,repro}.log`、退出码 JSON 与 `commands.txt`。测试未创建真实 HWND、未向桌面发送输入。
- 规范依据：[Microsoft 分层窗口命中行为](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features)。外围透明问题由实际像素证据与平台契约共同确认，不以静态尺寸断言替代。

## Next Scope

1. 原生修复已接正式 runner 构建门禁；提交后通知 CC，实际窗口/DPI输入仍需运行时复核。
2. 在当前集成树运行旧问题复现、迁移兼容、数据失败与协议测试；按实际失败分配后续修复，保留原始红灯证据。
3. 独立数据根下运行当前 Windows/Android 构建，继续运行时、可访问性、性能与升级检查；可用资源与实际平台限制逐项记录。
