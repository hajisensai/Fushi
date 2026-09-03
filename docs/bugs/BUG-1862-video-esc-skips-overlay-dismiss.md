## BUG-1862 · 视频页 Esc/返回键在侧栏等前台浮层打开时直接退出页面，未逐级关闭
- **报告**：2026-08-25（用户：截图为视频页右侧「视频设置」抽屉打开在字幕 tab，诉求「esc 应该先关闭侧栏等前台弹窗再退出」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi_page.dart:4456`（旧 `_handleBackOrExit`：只关词典浮层，其余一律直接 pop 路由）+ `fushi/lib/src/pages/implementations/video_fushi/layout.part.dart:469`（侧栏 overlay 挂在 media_kit controls 的**兄弟**位置，不在其快捷键表作用域内）。

  **两条互相独立的缺陷叠在一起：**

  ① **层级表被抄成两份，其中一份只有一层。** 逐级退出（编辑态 → 字幕跳转列表 → 剧集列表 → 侧栏 → 沉浸锁 → 退全屏 → 退页）只写在 `escape:` 快捷键回调里；`_handleBackOrExit`（`PopScope` / Android 系统返回键 / 手柄 B 的落点）只关词典浮层，之后直接 `nav.pop()`。方法头注释写着「[PopScope] 与 Escape 快捷键共用，保证两条退出路径行为一致」——**这句话是假的**。

  ② **快捷键表够不着自家 overlay。** 视频页的整表快捷键经 media_kit 的 `MaterialDesktopVideoControlsThemeData.keyboardShortcuts` 安装，那层 `CallbackShortcuts` 只包住 media_kit **自己的 controls 子树**（`third_party/media_kit_video/lib/media_kit_video_controls/src/controls/material_desktop.dart:651`）。而设置 / 速度 / 章节侧栏、side rail、控制按钮 popover、布局编辑层都是 `_buildVideoControls` 那个 `Stack` 里与 controls **平级的兄弟节点**；侧栏一打开，`PanelFocusScope` 就把键盘焦点领进侧栏子树。

  **合起来就是用户看到的现象**：焦点在侧栏 → Esc 的冒泡路径不经过 media_kit 那张表 → 一路走到全局 `_handleGlobalBack`（`shortcuts/global_navigation.dart:222`）→ `nav.maybePop()` → 视频页 `PopScope(canPop: false)` → `_handleBackOrExit()` → 没有词典浮层 → **pop 掉整个视频页，侧栏还开着**。Android 系统返回键、手柄 B 走同一条 `PopScope` 路径，无论焦点在哪都复现同样症状。

- **[x] ① 已修复** — 分两步做根因修复，不加特例分支：
  1. **层级顺序收敛成单点真相源**：新增纯函数 `topVideoForegroundLayer`（`fushi/lib/src/media/video/video_foreground_layers.dart`）+ 枚举 `VideoForegroundLayer`（声明顺序即视觉层序）；页面 `_dismissTopForegroundLayer()` 只做「读状态 → 查表 → 执行关闭动作 → 返回是否关掉了一层」。层里共七层：词典浮层 → 控制布局编辑态 → 控制按钮 popover（音量 / 倍速轻浮层，点击打开那次会被 pin 住常驻）→ push-aside 字幕跳转列表 → 剧集轨 → 设置 / 速度 / 章节侧栏 → 沉浸锁。`_handleBackOrExit` 与 `escape:` 回调都先问它，注释里承诺的「两条路径一致」这才成真，Android 返回键 / 手柄 B 一并修好。
  2. **补上快捷键表够不着的那半**：`_wrapVideoControlsBackKey`（`layout.part.dart`）包在 controls builder 最外层——它是 side panel / side rail / 控制按钮 popover / 布局编辑层这几个 **Stack 兄弟**的共同祖先，且窗口与全屏复用同一 builder，两种场景一并覆盖。**覆盖面到此为止**：push-aside 字幕跳转列表（TODO-314）与剧集轨（TODO-638）由 `_videoWithSubtitlePanel` 包在 `Video` **外面**（`Row[Expanded(video), 面板列]`），是 controls builder 的兄弟而非后代，本层够不着它们（见下「未覆盖的缺口」）。只在**真的关掉了一层**时消费按键，否则返回 `KeyEventResult.ignored` 原样放行，不改写退全屏 / 退页语义、不吞其它按键；不夺焦、不进 Tab 遍历；文本框持焦时关闭物理键回退（与 `_handleGlobalBack` 同款判据，避免 IME 打字误触，TODO-847）。

  提交：见本分支 `worktree-video-esc-dismiss-overlays`。

- **[x] ② 已加自动化测试** —
  - `fushi/test/media/video/video_foreground_layers_test.dart`（7 条）：层序规则本身。含「所有前台层全开反复按返回，按视觉层序一层层剥到底、不重复不跳过」「两两比对：更靠前的枚举值就是更前台的层」与「pin 住的控制按钮 popover 开着时先关它、绝不越过它去退页」。
  - `fushi/test/media/video/video_escape_dismiss_guard_test.dart`（7 条）：接线守卫。锁住「`_handleBackOrExit` 先问层级表再 pop」「escape 回调不许再抄一份 if 链」「层级表读了 popover 就必须真关它」「controls builder 外层包着兜底层」「兜底层只在真关掉一层时消费按键」。源码读取统一 CRLF 归一化，避免换行风格一变整套守卫静默空转。
  - 变异实测 6 轮全部被抓到（含一轮**先没抓到**：兜底层「无条件返回 handled」——那会把 Esc 整个吞掉、视频页再也退不出去；据此把断言从「出现过 ignored」加强成「消费与否必须由层级表返回值门控 + 不许出现裸 `return KeyEventResult.handled;`」）。
  - 四条既有守卫（`video_player_keyboard_static_test.dart` / `video_immersive_lock_guard_test.dart` / `video_subtitle_jump_list_guard_test.dart` / `dictionary_child_popup_close_guard_test.dart`）原本锚在「escape 回调体里必须有某个 if 分支」这种实现位置上，层级表搬家后失配。已改成锚定新的单点层级表，断言的行为一条没减（编辑态 / 沉浸锁 / 字幕列表比侧栏更前台 / back 仍逐层退回而非清整栈）。

- **备注**：
  - **验证**：`flutter analyze` 全量（含 test 目录）零问题；`flutter test test/media/video/ test/focus/ test/shortcuts/ test/pages/` 共 **6444 条全绿**（9 skipped）。
  - **未覆盖的缺口（真机）**：本轮只有静态与纯函数层验证，没有在真机 / 离屏跑「开侧栏 → 按 Esc → 侧栏关、页面还在」的端到端复现。窗口模式那条链路（全局 back → `PopScope` → 层级表）逻辑上闭合；全屏模式下焦点在 side panel 时由新加的 controls 兜底层接住，也未真机复测。
  - **未覆盖的缺口（全屏 + push-aside 面板，已知、本次未修）**：全屏路由没有 `PopScope`，而 push-aside 字幕跳转列表 / 剧集轨由 `_videoWithSubtitlePanel` 包在 `Video` 外面、不在 `_wrapVideoControlsBackKey` 的祖先链上。于是**全屏下焦点被 `PanelFocusScope` 领进这两个面板后按 Esc，会走全局 back 把全屏路由 pop 掉（退出全屏），面板仍开着**。这条在 BUG-1862 之前就存在、不是本次引入；要修得把兜底层再上提到 `_videoWithSubtitlePanel` 之外，属独立改动。
  - **有意的用户可见变更（一）：屏幕上的返回箭头也逐级退一层。** `_handleBackOrExit` 还被 `_activateVideoControlItem` 的 `VideoControlItem.back`（控制条 / side rail 上用户可摆放的返回箭头）调用，收敛之后它也走同一份层级表。决策是**接受**：键盘 Esc / Android 系统返回 / 手柄 B / 屏幕返回按钮四条通道共用一份「返回上一级」语义，收敛的意义就在这里，不为按钮再开第二套。具体差异——push-aside 字幕跳转列表打开时控制条与 rail 仍可见可用（BUG-371），此时**点返回箭头：改前退出视频页、改后先关字幕列表**。加载中 / 加载失败页的返回按钮不受影响（该状态下六层可见性全是初值）。
  - **有意的用户可见变更（二）：词典浮层排到了最前。** 层级表把 `dictionaryPopup` 放在第一位，于是「查词浮层 + 沉浸锁」同时开着按 Esc，改前是先解锁、浮层还在，改后先关浮层；全屏下同理，改前先退全屏、浮层还在，改后先关浮层。方向与「最前台的先关」一致。
  - **全屏那一级为什么留在 `escape:` 回调里**：全屏是推到根 navigator 的**独立路由**，全屏期间栈顶是它、本页 `PopScope` 根本轮不到（框架先 pop 全屏路由）。把 `isFullscreen → _exitVideoFullscreen` 并进 `_handleBackOrExit` 只会写出一条永不执行的分支。（早先版本给的理由是「返回箭头语义是退页」——那条与上面「返回箭头也逐级退一层」的决策自相矛盾，已删。）
