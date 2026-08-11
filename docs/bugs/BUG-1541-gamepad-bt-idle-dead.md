## BUG-1541 · 蓝牙手柄待机断连后按键永久失效，必须重启 app

- **报告**：2026-08-11（用户：看板 TODO-2799）
- **真实性**：✅ 真 bug（静态定位，未做真机复现；见「验证状态」）。根因在 vendored 原生插件
  `packages/gamepads_windows/windows/gamepad.cpp`：
  - `gamepad.cpp:248-274`（修前）`Gamepads::on_gamepad_disconnected` 跑在 **GameInput 的设备回调线程**上，
    却直接调 `join_and_destroy` → `gamepad.cpp:163-177` 的 `std::thread::join()`。被 join 的轮询线程此刻
    正卡在 `gamepad.cpp:285` 的 `g_gameInput->GetCurrentReading(GameInputKindGamepad, device, &reading)` 里。
    **回调线程被我们按住 → 手柄唤醒时那次「连接」回调再也派发不出来 → 永不重建轮询线程 → 手柄彻底没反应，
    只能重启 app。** 这条正是用户症状（"待机一会儿再按就没反应"）的唯一必经路径。
  - `gamepad.cpp:249-253`（修前）断开回调在 `device->GetDeviceInfo()` 返回 `nullptr` 时**直接 return**。
    而设备已被系统摘掉（蓝牙待机正是这个场景）时 `GetDeviceInfo` 就可能失败 —— 条目和它的轮询线程于是
    永久留在 `gamepads` 册子里，对着一个死设备对象空转。
  - `gamepad.cpp:219-246`（修前）`on_gamepad_connected` **不去重**：一旦上面那次「断开」被漏掉，重连会加出
    第二条同 deviceId 的条目，旧线程继续烧一个核。
  - `gamepad.cpp:276-307`（修前）`read_gamepad` 既不看设备状态，退出时也不补「松开」帧。手柄在按住某键时
    掉线，`fushi/lib/src/shortcuts/gamepad_service.dart` 的 `GamepadFrameState` 就把该键永久锁在按下态
    （自动连发不停 / 摇杆钉在边上），**即使重连成功也还是坏的**。

  Dart 侧（`fushi/lib/src/shortcuts/gamepad_service.dart:1123-1180` `_PluginGamepadPoller`）把所有设备的事件
  折叠进同一个 `GamepadFrameState`，不按 device id 建订阅，**对设备 id 变化本身是鲁棒的**；`gamepads`
  包的 `normalizedEvents` 也只是一个进程级 broadcast 流。所以这个 bug 整个在原生层，Dart 侧无需改。

- **[x] ① 已修复** — `packages/gamepads_windows/windows/gamepad.{h,cpp}`，四处一起改，全部在根因层，
  **没有用「定时全量重启轮询」这类掩盖式补丁**（守卫测试专门挡这条）：
  1. **join 移出 GameInput 回调线程**：新增退役队列 + 专属收割线程（`retire()` / `reap_loop()` /
     `drain_retired()`，条件变量驱动）。断开回调只做非阻塞的 `retire()` 移交；`join()` + `Release()` +
     `delete` 由我们自己的收割线程做。BUG-116 的「线程 OWNED、永不 detach、owner 负责 join」不变式原样保留
     （`stop()` 仍然 join 收割线程，收割线程仍然 join 每个轮询线程）。收割线程在 `RegisterDeviceCallback`
     **之前**就位，否则第一次断开回调就没人接手。
  2. **断开绝不放过摘除**：`GetDeviceInfo()` 失败时退化成按连接时 AddRef 过的 `IGameInputDevice*` 指针匹配，
     不再 early return。
  3. **连接时自愈**：按 deviceId 或设备指针清掉同一物理手柄的陈旧条目并 `retire()`，漏掉的断开回调不再留下
     僵尸线程。同时把线程创建挪进 `gamepads_mutex` 内，堵掉「断开回调在 push_back 之前看不到该条目」的窗口。
  4. **补发「松开」**：`read_gamepad` 每轮检查 `device->GetDeviceStatus() & GameInputDeviceConnected`；掉线时
     立刻 `neutralize_inputs()`（拿当前状态与中立状态求差，发一遍 release/回中事件）然后降频空转，不再对着
     正在被 GameInput 拆掉的设备调 `GetCurrentReading`（那正是把轮询线程按在 GameInput 内部锁上的入口）；
     线程收工前再补一次。设备原地复活时轮询无缝续上。

  提交：`0e58d09e66`

- **[x] ② 已加自动化测试** — `fushi/test/shortcuts/gamepad_bt_reconnect_guard_test.dart`（源码扫描守卫，8 条）。
  这是**最强可落地层**：vendored 的 Windows 原生 C++ 在 headless Dart 测试里跑不到（没有 GameInput.h、没有真
  手柄、没法制造真蓝牙断连），所以守住重连自愈链路的代码契约 —— 断开回调内不得出现任何 `join`、`retire` 必须
  非阻塞、收割线程由条件变量驱动且早于回调注册就位、`stop` 仍 join 收割线程、断开时按设备指针兜底匹配、连接时
  按 id/指针去重、轮询循环感知 `GetDeviceStatus`、掉线与收工两处都补松开，外加「不得引入定时器兜底 /
  不得 detach」的负向断言。
  **已变异实测**（5 个变异全部被抓）：
  - A 断开回调改回直接 `join_and_destroy` → 红
  - B 删掉线程收工前的 `neutralize_inputs` → 红
  - C 连接去重条件改成 `false` → 红
  - D 断开时 `GetDeviceInfo` 失败又变回 `return` → 红
  - E 轮询循环的 `GetDeviceStatus` 判断改成 `false` → 红

  同时复跑 BUG-116 的 `fushi/test/shortcuts/gamepads_windows_crash_guard_test.dart`（7 条）确认崩溃修复的契约
  没被这次改动破坏，全绿。

- **验证状态**：`implemented_unverified`（原生部分）。
  - 已验证：`flutter analyze`（含 test 目录）零 issue；`flutter test test/shortcuts/gamepad_bt_reconnect_guard_test.dart
    test/shortcuts/gamepads_windows_crash_guard_test.dart --no-pub` 15/15 绿；`flutter build windows` 通过
    （本机 `/W4 /WX`，新增 C++ 零警告）。
  - **未验证**：真蓝牙手柄的「待机 → 唤醒 → 按键恢复」端到端。本机没有可复现该待机断连时序的手柄硬件测试路径，
    也无法在 headless 测试里制造 GameInput 的设备到达/移除事件。
  - 真机验证步骤（拿到手柄后照做）：
    1. Windows 上跑 Hibiki，连蓝牙手柄，确认按键有反应；控制台应打出 `Gamepad connected: <id>`。
    2. 放置手柄直到它自动待机/断连（或直接关机），控制台应打出 `Gamepad disconnected: <id>` 与
       `Gamepad thread exit <id>`；此时 app 不应卡顿、CPU 不应有一个核被 8ms 轮询占满。
    3. 按手柄任意键唤醒/重新开机。控制台应**再次**打出 `Gamepad connected: <id>`，且**不重启 app** 的情况下
       按键立即恢复（焦点移动、A 确认）。这一步就是修前失败的那一步。
    4. 断连前按住 A 不放再让它断连，重连后确认没有「A 被永久按住」的连发/焦点乱跳（对应修复 4）。
    5. 反复 3~5 次断连/重连，确认 `listGamepads` 不会越滚越多（对应修复 3），退出 app 不崩、不卡在退出
       （对应收割线程的 teardown 路径 + BUG-116 不变式）。

- **备注**：
  - 只改 vendored 的 `packages/gamepads_windows`（pub 上游 `gamepads_windows 0.3.0+1` 同样有这些缺陷），
    Dart 运行时代码一行未动，`gamepads` / `gamepads_platform_interface` 均为未改的 pub 版本。
  - GameInput 还有个 `GameInputDeviceUserIdle` 状态位；本次没有订阅它 —— 我们的 statusFilter 仍只是
    `GameInputDeviceConnected`，靠 `GetDeviceStatus()` 在轮询循环里就近判断，不额外增加回调面。
