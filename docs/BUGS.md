# Bug 跟踪

> 约定（Claude/Codex 必须遵守）：用户报一个 bug → **先沿真实代码路径验真伪**（复现或定位根因）。
> - **是真 bug** → 追加一条到本文件（分配 `BUG-NNN`，记报告日期、根因 `file:line`），然后：
>   - **① 修复**这个 bug（根因修，不补丁），完成后勾 `[x] ①`，记提交哈希。
>   - **② 增加自动化测试**（在最强可落地层：真 widget 行为 / CSS 生成器 / 源码扫描守卫；纯视觉像素只能设备截图兜底并注明），完成后勾 `[x] ②`，记测试文件。
> - **不是真 bug / 无法复现** → 也记一条，标「未复现」并说明，不勾 ① ②。
> - reader/WebView/导入/播放/布局类修复：代码正确 + 单测无回归后，仍需**设备肉眼复测原始失败路径**（CLAUDE.md 验证纪律）；未做的在「备注」标注待补。
>
> 分层测试选型见 [docs/specs/2026-06-03-test-flow-refactor-*.md] 与各守卫测试范式
> （源码扫描：`test/pages/reader_paginate_lyrics_guard_static_test.dart` 的 `_functionSource`；
> CSS 生成器：`test/reader/reader_content_styles_test.dart`；widget 行为：`test/settings/`）。

---

## BUG-012 · md3 静态守卫扫已删除的 `_buildRailLeading()`（stale 测试，非产品 bug）
- **报告**：2026-06-03（我，T4 探针全量回归 `flutter test` 时发现的 4 个预存失败之一，用户让查）。
- **真实性**：⚠️ **非产品 bug，是 stale 测试守卫**。`test/settings/md3_design_system_static_test.dart`「page chrome surfaces use shared MD3 spacing tokens」用 `_functionSource(homeSource, 'Widget _buildRailLeading()', 'class _SyncExitWarningDialog')` 扫 `home_page.dart` 的 rail-leading 函数，但 `8fd0fc1fe`（删宽屏 rail logo）已把 `_buildRailLeading()` 整个删除（`grep` 确认 home_page.dart 已无此函数，`_SyncExitWarningDialog` 尚在 `:421`）→ 起始标记找不到 → `indexOf` 返回 `-1` → `expect(..., isNonNegative)` 失败。产品行为（删 rail logo）是**有意的**，不是 bug。
- **[ ] ① 不适用** — 无产品 bug 可修；守卫需移除/改指那条 `_buildRailLeading` 断言。
- **[ ] ② 不适用**。
- **备注**：`md3_design_system_static_test` 是并发 agent 正在扩的 MD3 守卫（未提交 `docs/specs/2026-06-03-md3-adaptive-nav-shell-plan.md`）。**留给该 agent 随 rail-logo 删除一并更新守卫，我不动以避免冲突**。

## BUG-011 · 手柄屏幕键盘「右」键落到右下对角键而非同行邻居
- **报告**：2026-06-03（我，全量回归预存失败之一）。
- **真实性**：✅ **真回归**。`HibikiGamepadKeyboard` 焦点在 `q`，按 D-pad 右键焦点落到**下一行的 `a`** 而非同行的 `w`（`test/widgets/hibiki_gamepad_keyboard_test.dart:60` 期望 `['w']` 实得 `['a']`）。根因：`f165cd475`（用户自己的提交「directional nav no longer skips the immediately-next row」）把**「沿按压方向距离 `along`」设成 `HibikiFocusController` 几何导航的绝对主键**（为修向下导航跳行），副作用是横向「右」移时——下一行里只要稍偏右的键（`a`：`along` 极小、`beam`=0 无垂直重叠）会击败同行邻居（`w`：`along`≈1 键宽、`beam`=1 有重叠）。根因点 `hibiki_focus_controller.dart:371-375`。
- **[x] ① 已修复** — `c8017ad8c`。修法不靠调权重（线性 `along+K·cross` 无单一 K 可同时满足键盘 `K>0.68` 与外观 `K<0.224`，恢复 `beam`-first 又反转 `f165cd475`），而是**加一个几何「clears」主层**：候选须在按压轴上**整体越过源**（近边在源远边之后）才进第一层；`a` 在横向与 `q` 重叠 → RIGHT 不 clear → 降到第二层，`w` clear。层内保留 `f165cd475` 的 `along→beam→cross` 序，故外观 DOWN 仍到左对齐紧邻行、网格 DOWN 仍选同列。消除冲突而非折中。
- **[x] ② 已加自动化测试** — `test/widgets/hibiki_gamepad_keyboard_test.dart`（`q`→右→`w`，随修复变绿）即守卫；并以**全套 30+ gamepad/focus 测试**为回归门槛实跑全绿（`+250`），含 `test/shortcuts/gamepad_focus_nav_test.dart`（`f165cd475` 的外观 DOWN）、`test/focus/focus_geometry_test.dart`、`theme_swatch_gamepad`、`settings_value_row_gamepad` 等。
- **备注**：影响手柄/方向键操作屏幕键盘可用性（右键曾走对角）。focus 核心改动，已用全 gamepad/focus 测试矩阵把关；真机手柄复测可后补。

## BUG-010 · 错误日志通知器在无绑定时抛异常，反噬「损坏 JSON 优雅降级」
- **报告**：2026-06-03（我，全量回归预存失败之一，且用户提示「2 个 JSON 容错可能同根因」——确为同根因）。
- **真实性**：✅ **真 bug（健壮性契约）**。`frequency_field`/`preferences_repository` 解析损坏 JSON 时进 catch 块调 `ErrorLogService.log` → `FrameSafeNotifier.notifyListenersFrameSafe`(`frame_safe_notifier.dart:21`) 读 `SchedulerBinding.instance`，**无绑定**（纯 `test()` / 后台 isolate / 绑定初始化前极早期）时抛 "Binding has not yet been initialized" → 把「优雅降级返回空」**反噬成抛异常**。根因：`397d027cd`（make log services reactive via ChangeNotifier）让 error sink 的通知路径假定绑定存在。生产里绑定总在故非用户可见，但 **error sink 永不该 throw** 是真实健壮性契约（否则今后任何会记错误日志的代码做 unit test 都得加 binding）。
- **[x] ① 已修复** — `ae46e9d21`（`notifyListenersFrameSafe` 改用 `_schedulerOrNull()` 安全取绑定：无绑定时一定不在帧渲染管线中 → 直接同步 `notifyListeners()`；消除「无绑定」这个特例，error sink 不再 throw）。
- **[x] ② 已加自动化测试** — `test/creator/frequency_field_test.dart`（malformed extra JSON 返回空）+ `test/models/preferences_repository_test.dart`（corrupted JSON 优雅）——这两个**本就存在**的测试随修复变绿，即回归守卫（谁让 error sink 再抛即红）。
- **备注**：同 `FrameSafeNotifier` 的 `DebugLogService` 也受益。非 reader/WebView，无需设备复测。

## BUG-009 · 桌面端「外观→iOS(Cupertino)」设置页崩坏：三栏拥挤 + 右下角 RenderFlex 溢出 + 无返回出口
- **报告**：2026-06-03（用户，附两张截图：切 iOS 前为正常 Material 全屏二栏；切 iOS 后变成「最左 Material 药丸 3 图标侧栏 + 中间 Cupertino insetGrouped 目标列表 + 右侧详情底部黄黑条纹溢出」，无返回箭头）
- **真实性**：✅ 真 bug（代码追踪 + Win11 真机截图双确证）。两个独立根因：
  - **R1 详情溢出**（右下黄黑条纹）：`CupertinoSettingsRenderer.buildDetailContent`(`hibiki/lib/src/settings/cupertino_settings_renderer.dart:110`)返回**裸 `Column`（不可滚动）**，被 `SettingsHomePage._buildWideLayout`(`settings_home_page.dart:159-165`)塞进 `MaterialSupportingPaneLayout.primary`（`Expanded`，有限高度）→ 内容超高 RenderFlex 溢出。对照 `MaterialSettingsRenderer.buildDetailContent`(`material_settings_renderer.dart:114`)用 `ListView.builder` 自带滚动故不溢出。
  - **R2 结构割裂**（三栏拥挤 + 无返回 + 布局突变）：`home_page.dart:327` 的设置标签全屏分支带 `_currentTab==2 && !isCupertinoPlatform(context)` 门控，cupertino 桌面被排除 → 退化成「3 图标 rail + 嵌入设置」三栏；且 `SettingsHomePage._buildEmbeddedMaterialShell`(`settings_home_page.dart:101-103`)对 cupertino 提前返回裸 content（无页头/返回箭头）。桌面外壳本应「复用 Material 架构、叶子控件按设计系统切皮肤」(CLAUDE.md)，此处 cupertino 桌面是半成品特例路径。同款 overflow/退化在 macOS、iPad 横屏同样存在（同一份 `_buildDesktopLayout`），无人报。
- **[x] ① 已修复** — `918139165`（R1：`CupertinoSettingsRenderer.buildDetailContent` 裸 `Column` → 可滚动 `ListView.builder`，对齐 Material 渲染器，shrinkWrap 时禁自滚由外层 sliver/SingleChildScrollView 滚、底部留安全区；`buildDetailPage` sliver 内调用传 `shrinkWrap:true`；reader 设置弹窗 `shrinkWrap:!cupertino→true`。R2：去掉 `home_page.dart` 设置全屏分支的 `!isCupertinoPlatform` 门控，cupertino 桌面也隐藏 3 图标 rail 走全屏二栏；`settings_home_page._buildEmbeddedShell` 去掉 cupertino 提前返回、给桌面全屏设置补 `HibikiPageHeader`+返回箭头，并短路保留 cupertino 手机原生无页头。消除特例分支，非补丁）
- **[x] ② 已加自动化测试** — `test/settings/settings_renderer_test.dart`（`BUG-009`：cupertino 详情在固定矮高度 pane 里渲染不抛 RenderFlex 溢出、提供可滚动视口；`BUG-009 R2`：`platform=windows + designSystem=cupertino` 下 pump 真实 `SettingsHomePage(embedded,onBack)`，断言渲染返回箭头出口且不溢出）
- **备注**：布局类。代码+单测已绿（settings_renderer_test 14/14；opus 审查 🟢 无致命问题，确认全 5 个 `buildDetailContent` 调用点覆盖、material 弹窗零变化、macOS/iPad/iOS手机/Android 各组合推演只有目标场景改变）。仍需 **Win11 真机肉眼复测**原始失败页（外观切 iOS）确认黄黑条纹消失、二栏、返回箭头可点回来源 tab、视觉协调——待补。R3 配色（Cupertino 列表系统灰 vs app 主题 surface 色不一致）属主观微调，本轮不做，真机看效果再定。
- **预存失败（非本轮）**：`test/settings/md3_design_system_static_test.dart` 的「page chrome surfaces use shared MD3 spacing tokens」用例引用 `home_page.dart` 已被删除的 `_buildRailLeading()`（「删宽屏 rail logo」改动遗留，与 BUG-009 无关），本轮未触碰，待对应改动方同步守卫。

## BUG-008 · 外观设置「设计系统/深色模式」分段选项位置错乱、右侧选项被切掉
- **报告**：2026-06-03（用户，附截图：自动/MD3/iO[S] 与 深色模式 三段控件右端被裁，最后一项漏到屏幕外）
- **真实性**：✅ 真 bug。`buildDesignSystemSelector`(`settings_actions.dart:208`)、`buildBrightnessSelector`(`settings_actions.dart:378`)、以及阅读器快捷设置的 view-mode 行(`reader_quick_settings_sheet.dart:389`)构造 `AdaptiveSettingsSegmentedRow` 时**未传 `controlBelow`，落到默认 `false`** → 走 inline `_buildRowLayout`(`settings_shared.dart:283`)：`Row[ Expanded(label, flex1) , Flexible(loose, strip, flex1) ]`，RenderFlex 按 flex 把行宽 ≈50/50 切分 → 分段条只拿到约半幅（远小于其本征宽）→ 横向 `SingleChildScrollView` 滚动到 0、尾段（iOS/月亮）被裁到视口外。仓库中所有“有意”的分段行都显式写了 `controlBelow: true`，唯独这三处漏写——**inline 作为默认值本身就是这个陷阱**。
- **[x] ① 已修复** — `02411bb16`（把 `AdaptiveSettingsSegmentedRow` 与 `SettingsSegmentedItem` 的 `controlBelow` 默认值翻成 `true`：分段条改为占据 label 下方整行全宽，消除 inline flex 半幅裁切的特例；显式传值的 callsite 不受影响，仅这三处受惠）
- **[x] ② 已加自动化测试** — `test/widgets/settings_segmented_overflow_test.dart`（新增 BUG-008 用例：同一宽 strip 在同一 pane 下，inline 路径 `maxScrollExtent>0`=被迫滚动裁切，默认 below 路径 strip 在 label 之下、`maxScrollExtent==0` 全段可见；原 inline 窄 pane 不溢出用例改为显式 `controlBelow:false` 保留覆盖）
- **备注**：布局类，代码+单测已绿；Win11 真机肉眼复测原始失败页（外观设置）待补。

## BUG-007 · 有声书「遇到图片暂停播放几秒」开了无效（假功能）
- **报告**：2026-06-03（用户）。用户：开了「遇到图片暂停的播放几秒」选项没用。附带说书架「查看插图」(`view_illustrations`)能补看插图、稍微有用（独立功能，不在本 bug 范围）。
- **真实性**：✅ 真 bug（静态全链路追定，待插桩确认断点）。Dart 侧整条链完整：UI 段控(`reader_quick_settings_sheet.dart:1071-1113`)→`setImagePauseSec`/持久化(`audiobook_repository.dart:147-156`)→加载回填(`reader_hibiki_page.dart:767/849`,`audiobook_controller.dart:272`)→每切章注入(`_injectAudiobookBridge`,`:1968/:2576`)→JS 检测→`callHandler('onImageDetected')`→handler(`reader_hibiki_page.dart:1793-1796`)→`triggerImagePause`(`audiobook_controller.dart:214-227`)。**根因在检测数据源选错**：图片检测用 `IntersectionObserver`（root=视口、阈值 0.3，`audiobook_bridge.dart:162-189`），而阅读器是 CSS 多栏 + `body{overflow:hidden}` + `scrollLeft/scrollTop` **离散翻页**（`reader_content_styles.dart:296-324`、`reader_pagination_scripts.dart:611-617`）。有声书播放=高亮 reveal 驱动的离散跳页，整页插图常被一帧直接跳过、从不被渲染成「当前页」→ IO 永远达不到 0.3 阈值 → 永不回调 → 暂停永不发生。附带：即便偶尔落在图片页，若此刻没在播 `triggerImagePause` 首行 `if(sec<=0||!_player.playing)return;` 直接返回。全仓库仅此一处用 IntersectionObserver，无其它处验证它在这套布局下能用。
- **[x] ① 已修复** — `f0f36588c`（图片检测从 IntersectionObserver 视口可见性改为 `__hoshiHighlight` cue 推进时用 `compareDocumentPosition` 判定上一句锚点 `__hoshiPrevHighlight` 到当前句之间是否存在 img/svg；删旧 IO `_imagePauseFn`。离散翻页跳过整页插图也能确定性抓到，两种阅读模式通用）
- **[x] ② 已加自动化测试** — `test/media/audiobook/image_pause_detection_test.dart`（源码扫描守卫：检测须用 cue 推进锚点间 DOM 判定、旧 IO 须移除）+ `integration_test/image_pause_detection_test.dart`（真 WebView 设备验证，`365fd1c05`，已登记 ci）
- **备注**：代码 4 环已确认根因，故直接修（未走插桩）。**设备验证已过**（emulator-5554：真 InAppWebView 注入真实 bridge，`__hoshiHighlight` 从 s1 跨 svg 推进到 s2，`onImageDetected` 真触发，All tests passed）。260 audiobook 单测无回归。整页插图+真实有声书音频播放的端到端复测仍可后补（合成验证用相邻锚点+svg 等价了「reveal 跨过无 cue 的整页插图」）。
- **跟进 · gap 补齐（2026-06-03 同日，另一 agent 插桩复现后续补）**：主修复 `f0f36588c` 只覆盖**选择器型 cue** 路径。另 agent 插桩复现确认根因（F1 视口 IO「落在图片页」能触发 ratio 1.0；F2 reveal 离散翻页把整页插图一帧跳过、IO 永不触发，证据 `.codex-test/itest-logs/image_pause_probe3.log`）后补两缺口 + 一边缘：①**sasayaki cue 路径**接入同套锚点间检测（`957adb586`/`505c8c56f`：新 `__hoshiSasayakiAnchorEl` 从 `cueRangesMap`/`cueWrappers` 解析锚点 → 复用共享 `__hoshiImagePauseAdvance`）；②**命中插图先 reveal 再暂停**（`17364783a`：`__hoshiRevealTarget` 滚到插图而非插图后正文，否则停了看不到图）+ 控制器恢复时 `snapReaderToAudio()` 拉回当前 cue 续播（`68cb055ed`）；③边缘：用户在暂停窗口内手动 play 取消计时器 + snap（`496b19f17`）。共享 helper `__hoshiImageBetween`/`__hoshiRevealTarget`/`__hoshiImagePauseAdvance` 两路径复用。**铁律**：`onImageDetected` 跨图就发（与 reveal 无关，设备测试契约），仅「滚到插图」门控 reveal；禁重引入 IntersectionObserver。**设备验证**（`integration_test/image_pause_detection_test.dart`，emulator-5554）selector + sasayaki 跨图都触发 `onImageDetected` 且 reveal 目标 = 插图，All passed；262 hibiki + 6 hibiki_audio 单测绿。计划 `docs/specs/2026-06-03-bug007-image-pause-gaps-plan.md`（`94aebdbb2`）。**残留**：真实有声书音频播放端到端（真实分页下 reveal 列对齐 / 恢复 snap 不漂移）待真机（需 audiobook+插图夹具）；若漂移把图片 reveal 改页对齐 `scrollToRange`。

## BUG-006 · 改 String 型 segmented 设置（书写方向/视图模式/振假名/跨页）渲染器崩溃
- **报告**：2026-06-03（由 settings schema 焦点驱动覆盖测试发现，非用户报告）
- **真实性**：✅ 真 bug。`material_/cupertino_settings_renderer.dart` 把 `SettingsSegmentedItem<String>` 经 `as <Object>` 转型，闭包读 `onChanged` 因函数参数逆变抛 `_TypeError`。两渲染器同病；现有测试只渲染不真改 segmented 所以潜伏。
- **[x] ① 已修复** — `07784a786`（两渲染器改 `(segmented as dynamic).onChanged` 绕开读取期检查）
- **[x] ② 已加自动化测试** — `test/settings/settings_renderer_test.dart`（material + cupertino segmented 改值不抛 _TypeError 回归用例）

## BUG-005 · 阅读器 live 设置 hook 异步异常逃逸 zone
- **报告**：2026-06-03（emulator app.main 跑设置覆盖 ~29s 未捕获异步错误，Workflow 根因排查）
- **真实性**：✅ 真 bug。`onSettingsChangedLive`/`onLayoutReloadLive` fire-and-forget 丢 Future；await 后 `_controller!.evaluateJavascript` 在 WebView 半销毁时抛 `PlatformException` 无 try/catch → 逃 zone，绕过所有 handler。改 reader 布局设置时若 reader teardown 竞态即触发。
- **[x] ① 已修复** — `a5b046c40` + `972147a8d`（两 hook unawaited+catchError 归 ErrorLogService；4 个 eval 点包 try/catch no-op）
- **[x] ② 已加自动化测试** — `test/reader/reader_live_settings_guard_test.dart`（源码扫描守卫 5 个 ErrorLogService tag + unawaited 在位）
- **备注**：半销毁竞态难确定性复现（reader 含真实 InAppWebView 无法 widget 挂载）；**设备复测待补**（改 reader 设置无逃异常）。

## BUG-004 · 设置页向下滑动会自动跳回上面，得再滑一下
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。纯触屏快速滚长设置列表，行回收 → `ensureFocus` 被动修复 re-home + `_maybeRevealOnRepair` reveal（居中）与手指方向相反把视口拽回。
- **[x] ① 已修复** — `f6ef60d27`（`_maybeRevealOnRepair` 门控到 `FocusHighlightMode.traditional`；touch 无光标 → 不 reveal）
- **[x] ② 已加自动化测试** — `test/settings/settings_scroll_no_rollback_test.dart`（真实渲染器，本会话补）+ `test/focus/focus_repair_touch_no_scroll_test.dart`（合成核心路径，已有）
- **备注**：本会话写设置专用测试时一度误把 `jumpTo(maxScrollExtent)` 后弹道 clamp 当成 reveal 拽回（懒加载列表 extent 不稳）；诊断确认 Hibiki reveal 门控正常、bug 已修，测试改成先 settle 再验。

## BUG-003 · 阅读器竖排模式下部分文本显示在刘海/notch 区域
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。竖排翻页轴是 scrollTop，column-gap（页间周期）须含 chrome insets，否则 pitch 比视口矮，上一页尾部漏进顶部刘海条。
- **[x] ① 已修复** — `ee9b2e1f6`（竖排 `column-gap` 含 `--chrome-top/bottom-inset`，pitch==pageHeight）
- **[x] ② 已加自动化测试** — `test/reader/reader_content_styles_test.dart:273-281`「vertical paginated column-gap includes both chrome insets」（CSS 生成器测试，已有，正是此 bug 的回归）
- **备注**：竖排排版的真实像素结果只能设备截图验；本测试守的是「生成的 CSS 契约正确」。

## BUG-002 · 阅读器切章时底栏（bottom chrome）闪烁
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。底栏可见性原耦合在「每切章翻转」的 `_readerContentReady`，切章瞬间硬卸载再挂回 → 闪烁。另有 spread（漫画双页）路径漏置位缺口。
- **[x] ① 已修复** — `84f1a22af`（门控改 set-once `_hasEverLoaded`）+ `7a8577347`（补 spreadReady 置 `_hasEverLoaded=true`，否则 spread 冷开底栏等 8s）
- **[x] ② 已加自动化测试** — `test/pages/reader_bottom_chrome_gate_static_test.dart`（源码扫描守卫：门控用 `_hasEverLoaded` 不用 `_readerContentReady`、spreadReady 置位、set-once 无复位）
- **备注**：切章无闪/spread 底栏即时出现的真实帧只能设备复测；**设备复测待补**。

## BUG-001 · 给书本打标签后封面展示异常
- **报告**：2026-06-03（用户）
- **真实性**：✅ 真 bug。标签覆盖层 `_adaptiveTagColumn` 用 `Positioned(top,left)`（无 bottom/height）落进封面卡片 `Stack(fit: StackFit.expand)` → 子树拿到 unbounded `maxHeight==infinity` → `(maxHeight*0.55/22).floor()` 抛 `UnsupportedError: Infinity or NaN toInt`；覆盖层只在带 tag 时存在，故只在打 tag 后崩。
- **[x] ① 已修复** — `22b5bafc8`（抽纯函数 `adaptiveTagSlots` 加 `isFinite` 守卫，无界时渲染全部标签）
- **[x] ② 已加自动化测试** — `test/pages/adaptive_tag_column_layout_test.dart`（widget 真约束传播：`Positioned`-in-`StackFit.expand` 不抛 + 封面 sibling 满尺寸；纯函数 infinity/NaN/clamp 单测）
