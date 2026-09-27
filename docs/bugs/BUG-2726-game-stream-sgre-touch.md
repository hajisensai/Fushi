## BUG-2726 · 串流触屏在 SGRE 上一律「输入未送达」
- **报告**：2026-09-27（用户：「不能触屏，而且老是不送达」）
- **真实性**：✅ 真 bug。`fushi/windows/runner/game_stream_input.cpp` 的 `SendPointer` 在目标有 SGRE DirectInput 通道（`HasSgreNativeConfirmCapability()`）时直接返回 `unsupported_native_pointer`，所有触控/指针事件都被拒；方向键、B、L/R 同样返回 `unsupported_native_gamepad_button`。只有手柄 A（原生左键通道）能用。SGRE 不读鼠标窗口消息，但它每帧采样 DirectInput 鼠标按键、按系统光标位置命中（适配器自己的查词点击也读 `GetCursorPos`）。
- **[x] ① 已修复（触屏）** — `74142b1a652`：SGRE 目标上点按 = 在目标 DPI 上下文里把客户区坐标换成屏幕坐标并 `SetCursorPos`，再走与 A 键同一条原生左键通道（同样要求前台）；悬停移动只在游戏占前台时移光标，否则静默丢弃；抬起不要求前台。真机（Android 平板 → 本机 SGRE，DPI 不感知的 4K 全屏）：点标题画面跳过开场、进主菜单，点 CONFIG 精确打开设置界面。
- **[x] ② 已加自动化测试** — `fushi/windows/runner/tests/game_stream_input_release_test.cpp`（后台悬停不动宿主光标、后台点按返回 `window_not_foreground` 且不发布原生输入、不发窗口消息、无按住时抬起为空操作、右键/滚轮仍拒），由 `tool/run_game_stream_input_test.ps1` 构建运行。
- **备注**：未修的部分——方向键 / B / L / R 在 SGRE 上仍返回 `unsupported_native_gamepad_button`：`sgre_lookup.h` 显示 SGRE 键盘也走 DirectInput 采样，`PostMessage` 送不到。要么给原生通道加右键位（B=返回）与键盘位（需 hook 侧改 `ApplySgreGameStreamRemoteButtons` 并同步 IPC 掩码），要么在前台时改用 `SendInput`；两条都需按 galgame SOP 单独做真机取证。
