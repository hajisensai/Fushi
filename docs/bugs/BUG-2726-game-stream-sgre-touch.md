## BUG-2726 · 串流触屏在 SGRE 上一律「输入未送达」
- **报告**：2026-09-27（用户：「不能触屏，而且老是不送达」）
- **真实性**：✅ 真 bug。`fushi/windows/runner/game_stream_input.cpp` 的 `SendPointer` 在目标有 SGRE DirectInput 通道（`HasSgreNativeConfirmCapability()`）时直接返回 `unsupported_native_pointer`，所有触控/指针事件都被拒；方向键、B、L/R 同样返回 `unsupported_native_gamepad_button`。只有手柄 A（原生左键通道）能用。SGRE 不读鼠标窗口消息，但它每帧采样 DirectInput 鼠标按键、按系统光标位置命中（适配器自己的查词点击也读 `GetCursorPos`）。
- **[x] ① 已修复（触屏）** — `74142b1a652`：SGRE 目标上点按 = 在目标 DPI 上下文里把客户区坐标换成屏幕坐标并 `SetCursorPos`，再走与 A 键同一条原生左键通道（同样要求前台）；悬停移动只在游戏占前台时移光标，否则静默丢弃；抬起不要求前台。真机（Android 平板 → 本机 SGRE，DPI 不感知的 4K 全屏）：点标题画面跳过开场、进主菜单，点 CONFIG 精确打开设置界面。
- **[x] ② 已加自动化测试** — `fushi/windows/runner/tests/game_stream_input_release_test.cpp`（后台悬停不动宿主光标、后台点按返回 `window_not_foreground` 且不发布原生输入、不发窗口消息、无按住时抬起为空操作、右键/滚轮仍拒），由 `tool/run_game_stream_input_test.ps1` 构建运行。
- **备注**：未修的部分——方向键 / B / L / R 在 SGRE 上仍返回 `unsupported_native_gamepad_button`：`sgre_lookup.h` 显示 SGRE 键盘也走 DirectInput 采样，`PostMessage` 送不到。要么给原生通道加右键位（B=返回）与键盘位（需 hook 侧改 `ApplySgreGameStreamRemoteButtons` 并同步 IPC 掩码），要么在前台时改用 `SendInput`；两条都需按 galgame SOP 单独做真机取证。

### 续：手柄方向键 / B / L / R / 菜单（2026-09-27）

- **SGRE 实际读的输入**（静态取证，用户本机 STEINS;GATE RE:BOOT Steam x64 的 `sgre_steam.exe`，只记 RVA 不存载荷）：
  - 每帧输入更新 `0x4f4760`：先 `GetDeviceState(0x100, [rsp+0x50])`（`0x4f47f4`，键盘槽 `0xA96E10`），随后遍历键位绑定向量 `[0xA96EE8, 0xA96EF0)`，记录步长 12 字节 `{u32 dik, u32 action, u32 alt}`，`state[dik] & 0x80` 即 OR 进动作位（`0x4f4810..0x4f4854`）；再 `GetDeviceState(0x14)` 读鼠标（`0x4f48db`，槽 `0xA96E18`）。
  - 键盘设备 `CreateDevice(GUID_SysKeyboard)` → `SetDataFormat(c_dfDIKeyboard)` → `SetCooperativeLevel(6 = 前台|非独占)`（`0x4f3785..0x4f37f8`）。另有一个独立键态读取 `0x4f2d30` 同样 `GetDeviceState(0x100)`。
  - 动作位是引擎自己的命名手柄词汇（`.data` 表：`a=0x1 b=0x2 select=0x4 start=0x8 right=0x10 left=0x20 up=0x40 down=0x80 r/r1=0x100 l/l1=0x200 x=0x400 y=0x800 … back=0x100000`）；默认键盘绑定由 `0x4f2c00` 从静态表重填：方向键→上下左右、Z/Space/小键盘 Enter→a、X→b、C→l1、D→r1、Esc→back；VK 表（`GetKeyState`）另有 Enter→a、右键→b、Ctrl→r1。
  - 本机 dinput8 实测：键盘与鼠标设备共用同一 vtable，slot 9（GetDeviceState）是同一实现（A/W 两套 vtable 也指向同一函数）——已装在鼠标上的护盾 detour 本就会收到键盘采样。
- **[x] ③ 已修复（手柄其余键）** — `39024dba284`：
  - IPC（仍 v25、布局不变）新增引擎中立动作位 `kGameStreamInputButtonDpad*/Cancel/Shoulder*/Menu`（`0x100..0x8000`）；旧 DLL 会掩掉并报未观测 → host `native_input_not_observed` 失败关闭。
  - `sgre_anchors.h`：键盘设备槽、键位绑定向量各由两处独立代码点签名互证（纯签名，**不**进按哈希的已知构建行）；可选，不影响 `complete()`。对真实 exe 解析得 `0xA96E10` / `0xA96EE8`，既有锚点结果不变。
  - `sgre_lookup.h` / `.inc`：远端动作 → 引擎动作位（上下左右、cancel→b、L→l1、R→r1、menu→back）→ 从**活的**绑定向量查单动作 DIK（用户改键跟随；没有单动作绑定则失败关闭），把高位 OR 进游戏即将采样的 256 字节键盘状态，observed 从缓冲回读；键盘结果按请求 seq 并入鼠标采样发布的 ACK；查词卡在场时拒绝。
  - host：原生通道泛化为按住掩码（同一事务）；ACK 缺位时在 250ms 内等后续帧（键盘先于鼠标采样），失败回滚到先前掩码。审查建议一并处理：持有原生左键时指针 up 走提前释放，不经 `ValidateTarget` 可见性检查（按住期间最小化不再残留）。
- **[x] ④ 已加自动化测试** — `native/galgame_hook/tests/sgre_adapter_test.cpp`（`TestRemoteKeyboardAnchors` 合成镜像解析/互证/槽位碰撞拒绝；`TestGameStreamRemoteKeys` 八个动作到默认 DIK、改键跟随、多动作记录不用、拒绝时不清真实按键、非法布局空操作）；`fushi/windows/runner/tests/game_stream_input_release_test.cpp` 的 `CheckNativeGamepadButtons`（每个手柄键都有原生位且后台按下拒绝而非 unsupported、不回落窗口消息、组合掩码、未观测 NACK 并回滚、最小化目标上指针 up 释放原生左键、隐藏目标 Release 清空）。
- **未验证**：`implemented_unverified`——没有在真机 SGRE 上按下远端方向键/B/L/R 看游戏响应；`menu→back` 的游戏内语义未确认；按住超过 750ms 租约仍会被释放（与确认键同一既有限制）。

### 审查跟进（PR #1693）

- **绑定条目第三字段 alt 的语义**（`0x4f4823..0x4f4854`）：每帧开头把两个动作字清零（`0xA96DFC` 与 `0xA96E20`，`0x4f47ab/0x4f47b1`）；命中的条目把 `action` OR 进 `0xA96DFC`，把 `alt` OR 进 `0xA96E20`（VK 表同样把 +4/+8 分别 OR 进两个字，`0x4f4888..0x4f4894`）。所以 alt 会生效，而且是**另一套动作位**：`.data` 命名表第二列就是同一个动作在第二套里的值（up 0x40/0x1，down 0x80/0x2，left 0x20/0x4，right 0x10/0x8，b 0x2/0x2000，l1 0x200/0x100，r1 0x100/0x200，back 0x100000/0）。默认绑定的 alt 全部等于对应动作在命名表里的第二列。因此查找改为：`action` 必须等于目标动作，并且 `alt` 为 0 或等于该动作在第二套里的值；否则跳过，免得多按出别的动作。
- **VK 表**：输入更新里另有一张 VK 表，逐条用 `user32!GetKeyState` 采样（IAT `0x5BD848`；默认 Enter→a（按住 Alt 时不算）、右键→b、Ctrl→r1）。代码注释已改准确。远端通道不走这条路：GetKeyState 跟随的是线程输入队列，只有真实输入或全局 SendInput 能更新它。
- **ACK 一次定论**：原先 host 在 UI 线程上最多忙等 250ms 去等后续帧，现已移除。hook 侧改为：请求带手柄位、键盘槽存在、而本 seq 还没有键盘观测时，鼠标采样先不发布 ACK，最多延后一个鼠标采样（`DeferSgreGameStreamAckForKeyboard`）。host 恢复为拿到第一份 ACK 就定论；旧 DLL 会掩掉新位，所以立即返回 `native_input_not_observed`。
- **锚点加强**：键盘 CreateDevice 签名要求 `lea rdx` 指向 GUID_SysKeyboard；绑定向量两处签名都要求 end 操作数等于 begin+8。不符的一律算作「缺失」（本来就不是这处调用）。补了负向用例：GUID 不符、GUID 指到镜像外、键盘槽只配了 `GetDeviceState(0x14)`、end≠begin+8。真实 exe 仍解析出 `0xA96E10` / `0xA96EE8`。
- **CI**：`game_stream_input_release_test.cpp` 接进 runner CMake，目标是 `fushi_windows_game_stream_input_gate`（EXCLUDE_FROM_ALL，不进本地默认构建，因为它会读系统光标、创建真实窗口）。`build-multiplatform.yml` 的 windows job 在 `flutter build windows` 之后显式构建并运行它。
