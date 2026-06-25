## BUG-425 · 视频页合成 hover 在 MouseTracker 遍历期重入致 Concurrent modification 崩溃
- **报告**：2026-06-25（用户：Windows 桌面真机）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/pages/implementations/video_hibiki/controls_visibility.part.dart`（旧 `_pokeControlsVisible` 同步 `GestureBinding.instance.handlePointerEvent`）
- **[x] ① 已修复** — 提交 `<待 integration 填>`
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_mouse_tracker_concurrent_mod_guard_test.dart`
- **备注**：

### 现象
Windows 桌面真机崩溃：
`FlutterError: Concurrent modification during iteration: _Map len:2`，栈：
`MouseTracker.updateAllDevices (rendering/mouse_tracker.dart:368) → BuildOwner.lockState →
RendererBinding._scheduleMouseTrackerUpdate → SchedulerBinding.handleDrawFrame → drawFrame`。

### 根因（真实代码路径）
1. 视频页 `_pokeControlsVisible`（`controls_visibility.part.dart`）经
   `GestureBinding.instance.handlePointerEvent(PointerHoverEvent(device: _syntheticHoverDevice))`
   派发**合成 hover**唤醒 media_kit 控制条（驱动其自身的隐藏 Timer 重置）。
2. 该 helper 的部分调用方是 **MouseRegion 自己的 onEnter/onHover 回调**：
   - `_railHoverKeepAlive.onEnter/onHover`（`layout.part.dart:423-432`）
   - `_lockButtonHoverKeepAlive.onEnter/onHover`（`layout.part.dart:447-455`）
   - `_handleSubtitleHover`（字幕盒 hover，`controls_visibility.part.dart`）
3. 这些回调运行在 Flutter `MouseTracker.updateAllDevices` 遍历内部
   `_mouseStates`（`Map<int,_MouseState>`）的 `_deviceUpdatePhase` 内
   （`mouse_tracker.dart:367` 的 `for (final _MouseState in _mouseStates.values)`）。
4. 此时同步 `handlePointerEvent` → `RendererBinding` → `MouseTracker.updateWithEvent`
   （`mouse_tracker.dart:300`）→ 对合成设备执行 `_mouseStates[device] = _MouseState(...)`
   （`mouse_tracker.dart:327`）→ **在迭代 `_mouseStates` 期间增删该 Map** →
   `Concurrent modification during iteration: _Map len:2`（`len:2` = 真实鼠标 + 合成设备）。
   debug 构建本会先撞 `_deviceUpdatePhase` 的 `assert(!_debugDuringDeviceUpdate)` 重入断言；
   release 该断言被剥离，裸露为 Map 并发修改异常（用户即 release 真机）。

media_kit fork 早已学到这条教训：`third_party/media_kit_video/.../material_desktop.dart:475-486`
把控制条初始可见性发布延迟到 post-frame，注释明确「synchronous notifier write could re-enter
a host listener's setState mid-build」——但 hibiki 侧合成 hover 的派发漏了这层保护。

### 根因修复（非掩盖）
不加延迟/重试/吞异常，而是**消除重入本身**：合成 hover 的**派发**恒经
`scheduleMicrotask` 推迟到当前调用栈（含 MouseTracker 迭代）解开后再执行，绝不在
MouseRegion 回调 / MouseTracker 迭代窗口内同步派发。
- `_pokeControlsVisible`：仍在命中区几何有效时**同步**翻 `_pokeParity`、算抖动位置、
  构造 `PointerHoverEvent` 存入新字段 `_pendingPokeHover`（保 TODO-148/BUG-215 的位置去重
  续命语义），但只 `scheduleMicrotask(_dispatchPokeHover)`，不再同步 `handlePointerEvent`。
- 新增 `_dispatchPokeHover()`（微任务体）：取出 `_pendingPokeHover`、重校验 `mounted`、再
  `GestureBinding.instance.handlePointerEvent`——此时已脱离任何 MouseRegion 回调 /
  MouseTracker 迭代栈，写 `_mouseStates` 不再与遍历冲突。
- 新增去重旗 `_pokeDispatchScheduled`：同一微任务窗口内多次 poke 折叠成一次派发，
  `_pendingPokeHover` 每次刷新为最新抖动位置（连按时仍派发最新位置、不堆积冗余合成事件）。

时序影响：微任务在当前同步栈解开后、下一事件/帧前执行，控制条唤醒在用户尺度上仍即时；
键盘/seek/按钮等**非 MouseRegion 回调**调用方此前虽是同步派发也不在迭代窗口内，改延迟后
行为等价（只是晚一个微任务），不回归 BUG-176/BUG-215。

涉及文件：
- `hibiki/lib/src/pages/implementations/video_hibiki/controls_visibility.part.dart`
  （`_pokeControlsVisible` 改延迟派发 + 新 `_dispatchPokeHover`）
- `hibiki/lib/src/pages/implementations/video_hibiki_page.dart`
  （新字段 `_pokeDispatchScheduled` / `_pendingPokeHover`）

### 自动化测试（最强可落地层）
`hibiki/test/pages/video_mouse_tracker_concurrent_mod_guard_test.dart`：
- **行为层**：纯框架部件 `_ReentrantHoverHarness`——内层 MouseRegion 的 onEnter 在
  「MouseTracker 处理设备更新」时派发**第二个设备**的合成 hover；`deferDispatch:true`
  （微任务延迟，= 本修复结构）下 `tester.takeException()` 为 null（不重入、安全）。
- **源码层**（media_kit 视频部件跑不了 headless）：锁死 `_pokeControlsVisible` 体内不再有
  `GestureBinding.instance.handlePointerEvent`、改 `scheduleMicrotask(_dispatchPokeHover)`
  + `_pendingPokeHover = PointerHoverEvent(`；`_dispatchPokeHover` 在 mounted 校验后派发
  `_pendingPokeHover`；存在 `_pokeDispatchScheduled` 去重旗 + `_pendingPokeHover` 字段。

### 真机验证步骤（待 integration / 用户）
Windows 桌面播放视频，鼠标在右/左浮动学习按钮 rail、左侧锁按钮、字幕盒上反复移入移出
（触发 `_railHoverKeepAlive` / `_lockButtonHoverKeepAlive` / `_handleSubtitleHover` 的 poke），
并连按上下句/±秒 seek，确认不再崩 `Concurrent modification during iteration`，且控制条仍随
hover/键盘正常续命显隐。
