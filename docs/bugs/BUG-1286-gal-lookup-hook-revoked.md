## BUG-1286 · galgame 查词浮窗点击失效：低级鼠标钩子被系统吊销后不再重装
- **报告**：2026-07-31（用户：玩 gal 时点查词没反应，浮窗卡住台词，甚至关不掉只能任务管理器结束；查词点不动了，但还在跟着 gal 的台词变）
- **真实性**：✅ 真 bug，根因 `hibiki/windows/runner/low_level_mouse_hook.cpp:111`（旧实现的 `HookThreadMain` 消息循环）
- **[x] ① 已修复** — `hibiki/windows/runner/low_level_mouse_hook.cpp`

  查词卡是 `WS_EX_NOACTIVATE` 的 topmost 窗，它的点击**唯一**来源是 `WH_MOUSE_LL` 回调
  投递的 `kLowLevelMouseClickMessage`（消费端 `hibiki/windows/runner/global_lookup_window.cpp:1955`）。
  而 `WH_MOUSE_LL` 是 Windows 会**主动吊销**的资源：回调超过 `LowLevelHooksTimeout`
  （`HKCU\Control Panel\Desktop`，默认 300ms）没返回，系统直接把它从钩子链上摘掉，既不
  通知也不让 `HHOOK` 失效。旧实现只在 Arm 时装一次，此后 `hook != nullptr` 恒为真，被摘
  之后永远不会重装——于是浮窗**看得见、点不动**，而台词照常刷新（那条走 IPC→ExecuteScript，
  与钩子无关）。这正是用户描述的「查词点不动了，但还在跟着 gal 的台词变」，且不可自愈，
  只能重启。玩 galgame 时进程内同时有词典 FFI、WebView2 COM、语音捕获与转码在抢核，
  `THREAD_PRIORITY_TIME_CRITICAL` 也不能保证回调在 300ms 内被调度。

  修法不是加重试或延时，而是**把 armed 的真值收敛到 `g_target`**：钩子线程常驻一只
  1s 的核对定时器，每拍把实际钩子状态收敛到 `g_target`。这一条同时消掉三类静默失败，
  不再各需一套特例分支：
  - `SetWindowsHookEx` 返回 nullptr（旧实现不检查）→ 下一拍补装；
  - `PostThreadMessage(kThreadArm)` 投递失败（旧实现不检查返回值）→ 下一拍补装；
  - 系统摘钩 → 判定后先 `UnhookWindowsHookEx` 再重装。

  吊销判据用**光标位移 + 回调未跑**的合取，零误报：光标位置变了说明系统必然投递过
  `WM_MOUSEMOVE`，而回调一次没跑，那它只可能已不在链上。只看「N 秒没事件」会把「用户
  没动鼠标」误判成吊销，空闲时反复重装全局钩子本身就是一次次全系统输入抖动。存活证据
  `g_callback_tick` 记在 `HookProc` 最前面（早于 `code < 0` 过滤分支），因为**移动事件**
  才是每秒都有的那类；记在过滤之后就只剩点击/滚轮能刷新，判据当场失效。

- **[x] ② 已加自动化测试** — `hibiki/test/mining/gal_lookup_hook_liveness_guard_test.dart`

  钩子逻辑在 C++ runner 里，Dart 侧无法驱动，故取最强可落地层：源码扫描守卫。扫描前
  **剥掉注释**，防「把断言要找的字面量写进注释」的假绿。三条断言：存活证据的记录位置
  早于过滤分支（位置关系，不是 contains）、核对分支以 `g_target` 为 armed 真值且覆盖
  补装/重装两条路径、吊销判据同时包含光标位移比较与「回调一次没跑」。

  变异实测已做：把 `g_callback_tick.store` 挪到过滤分支之后、同时在注释里留下守卫要找
  的字面量 → 守卫如期变红（`is not a value less than <808>`），证明它既捕获真实退化，
  也不被注释蒙混。

- **备注**：native 改动，Dart 侧 `flutter analyze` / `flutter test` 覆盖不到编译；本轮
  未做 Windows 真机构建验证，合入后需在 Windows 出包路径上复验（相邻功能：BUG-1166 的
  滚轮吞掉逻辑与 BUG-1077 的 Disarm 宽限期均未改动语义）。
