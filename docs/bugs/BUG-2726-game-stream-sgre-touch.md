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
