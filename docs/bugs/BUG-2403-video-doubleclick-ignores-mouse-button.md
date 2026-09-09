## BUG-2403 · 视频页双击判定不看鼠标按钮号，右键双击画面切全屏
- **报告**：2026-09-10（用户：「右键双击会把全屏关掉，为啥」）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi_page.dart:7819`（`_handleVideoPointerUp`）。
  该方法手写 400ms（`_videoDoubleClickInterval`）+ 48px（`_videoDoubleClickSlop`）的双击窗口，
  **全程没有读过按钮号**：任何按钮的两次 `PointerUpEvent` 都能命中，桌面随即
  `unawaited(_toggleVideoFullscreen(controlsContext))`。于是「右键双击画面」= 切全屏，
  在全屏里就表现为「右键把全屏关掉」；中键、侧键同理，双击左/右区的
  `_handleDoubleTapSeek` 也一样被非主键触发。
  挂载点 `video_fushi/layout.part.dart:349` 的注释一直写着「左键双击全屏仍走外层
  Listener.onPointerUp」——那个「左键」判据从来没写进实现，只活在注释里。
  同因先例：`utils/components/fushi_reorderable_grid.dart:480`（Flutter 手势识别器的
  `allowedButtonsFilter` 基类默认恒真、任意按钮都接）。
  **与右键菜单无关**：菜单走的是另一条路（`ContextMenuTrigger` → `_handleSecondaryTap`，
  还带 BUG-1453 的 ~70ms 手柄 synthetic 去重延迟），菜单弹没弹不影响本 bug。
- **[x] ① 已修复** — `_handleVideoPointerUp` 顶部加按钮门。判据必须在**按下侧**记账：
  `PointerUpEvent.buttons` 在抬起那一刻恒为 0（按钮已释放），抬起事件自己拿不到
  「刚才按的是哪个键」。故同一个 `Listener` 上加 `onPointerDown: _recordVideoPointerButton`
  （+ `onPointerCancel: _forgetVideoPointerButton` 销账），把非主键指针记进
  `_nonPrimaryVideoPointers`，抬起侧一次性取走并早返回。按钮折叠复用全仓唯一的
  `domMouseButtonFromPointerButtons`（左键与触摸在那里恒折不出按钮号 → 恒不入账，
  双击全屏 / 双击 seek / 移动端双击暂停行为逐字不变）。
  焦点归还与唤回锁按钮排在门之前（那两件事与按了哪个键无关，既有行为不动）；
  非主键不碰 `_lastVideoPointerUpAt`，「左—右—左」仍算两次左键双击。
  提交：见本文件所在分支。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_double_click_button_gate_guard_test.dart`（5 条）。
  两层：① 真单测钉住修复赖以成立的前提（`PointerUpEvent.buttons` 恒 0；
  `domMouseButtonFromPointerButtons` 对左键/触摸恒 null、右键=2、中键=1、侧键=3/4）；
  ② 源码守卫钉三条不变式——记账与判定挂同一个 `Listener`、按钮门排在
  `_handleDoubleTapSeek` / `_toggleVideoFullscreen` 之前、按钮折叠只走那个唯一函数。
  **变异实测**（三次，各自只打红对应那一条）：删早返回 → 「按钮门排在双击执行体之前」红；
  摘掉 `onPointerDown` 记账 → 「记账与双击判定挂在同一个 Listener 上」红；
  换成手写 `kSecondaryMouseButton` 比较 → 「按钮折叠只走全仓唯一的那个函数」红。
  第一版守卫写成「门之后某处含 return」，实测是**空壳**（方法体里本来就有 episode 横轨 /
  侧栏 / chrome 三条早返回，`contains('return')` 恒真，删掉真门照样全绿），已收紧成
  「那笔账自己被用作 return 条件」。
- **备注**：真实双击时序 / media_kit 控制条跑不了 headless（与 `video_double_tap_seek_guard_test`
  同范式），故行为不变式用源码守卫钉。真机复测未做。
