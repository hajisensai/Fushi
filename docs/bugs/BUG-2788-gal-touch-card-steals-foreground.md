## BUG-2788 · Windows 触屏点过查词卡后点卡外会推进 galgame（卡片被触摸激活成前台）
- **报告**：2026-09-29（用户：W1ght 转述别人的 Surface；CLANNAD：「点击查词后点击其他地方会推进剧情，但是鼠标点击不会」）
- **真实性**：✅ 真 bug，本机复现（CLANNAD Steam `SiglusEngine_Steam.exe` x86 SHA-256 `116A1B6A…DEA2D`，宿主为用户在用的 debug.16118，已含 BUG-2768/2769/2770；
  触摸用 `InjectTouchInput` 真实注入）。复现序列：触摸点字弹卡 → **触摸卡片内部**（点词 / 滚动）→ 触摸卡外人物画面 → 台词推进。
  只点字再点卡外（不碰卡片）不复现，这是 #1761 真机验证漏掉的组合。
  - 根因：触摸按下 composition 查词卡时，卡片被激活成**前台窗口**，两条独立路径：
    ① 窗口收到 `WM_POINTERACTIVATE` 与 `HIWORD(lParam)=WM_POINTERDOWN` 的 `WM_MOUSEACTIVATE`，
    `fushi/windows/runner/global_lookup_window.cpp` 原先落 `DefWindowProc` → `MA_ACTIVATE`；
    ② 指针经 `SendPointerInput` 进 WebView2（BUG-2770）后 Chromium 对子窗 `Chrome_WidgetWin_0` `SetFocus`，
    实测 `HCBT_SETFOCUS(Chrome_WidgetWin_0)` → `HCBT_ACTIVATE(FushiGlobalLookupWindow)`。
    `WS_EX_NOACTIVATE` 两条都挡不住。游戏一失去前台，宿主 `WH_MOUSE_LL` 的「点卡外吞点击」判据
    `ShouldConsumeGameClientClick`（`fushi/windows/runner/low_level_mouse_hook.cpp:810`，要求前台是游戏）失效，
    卡外点击 `consumed=0` 直接进游戏。
  - 为什么鼠标不推进：基线里**鼠标点卡片内部同样会让卡片变前台**、随后的卡外点击同样 `consumed=0`，
    只是物理鼠标按压跨越多帧，被注入侧 Siglus 护盾（GetKeyState 过滤 / WM 汇点）兜住；触摸是提升出的背靠背
    down/up，兜不住。所以这不是「宿主吞不到触摸」——本机实测 `WH_MOUSE_LL` 能看到并吞掉触摸提升的点击
    （flags `LLMHF_INJECTED`，dwExtraInfo `0xFF5157xx`）。
- **[x] ① 已修复** — 卡片在任何输入方式下都不再被自身内容激活：
  `GlobalLookupWindow::HandleMessage` 对 `WM_POINTERACTIVATE` / `WM_MOUSEACTIVATE` 回 `PA_NOACTIVATE` / `MA_NOACTIVATE`（路径 ①）；
  平台线程装 `WH_CBT`（`ActivationGuardProc`），焦点 / 激活要进入一个**不是前台**的 `WS_EX_NOACTIVATE` 查词卡（或其子窗）时否决（路径 ②）。
  卡片唯一一处主动拿前台（自绘右键菜单 `SetForegroundWindow`）用 `self_activation_allowed_` 显式放行。
  两个判据是 `fushi/windows/runner/window_activation_policy.h` 的纯函数 `OverlayNoActivateReply` / `ShouldVetoOverlayActivation`。
  只挡一条不够：只回 NOACTIVATE 时实测仍由 Chromium `SetFocus` 激活；只挂 CBT 时激活先经 `WM_MOUSEACTIVATE` 发生、CBT 看不到 `HCBT_ACTIVATE`。
  提交：见 PR。
- **[x] ② 已加自动化测试** — `fushi/windows/runner/tests/window_activation_policy_test.cpp`（`fushi_windows_activation_policy_gate`，
  每次 Windows runner 构建都编译并执行）：指针激活两条消息回不激活；未前台的查词卡被否决、右键菜单放行、已是前台的卡内焦点移动放行、
  无 `WS_EX_NOACTIVATE` 窗口与主窗不受影响。`fushi/test/lookup/global_lookup_mouse_hook_thread_guard_test.dart`
  从「本文件不得出现 SetWindowsHookEx」收窄为「只允许这一个线程级 WH_CBT」（BUG-1048 要防的是窗口线程装 WH_MOUSE_LL）。
- **真机验证**（2026-09-29，同一 CLANNAD 会话，宿主 = 16118 安装目录只替换 `fushi.exe` 为本分支 runner，`attached=activeNative`）：
  - 修复前（16118 原版）：触摸点「お」弹卡 → 触摸卡内 → 前台变 `FushiGlobalLookupWindow` → 触摸卡外，台词「ほらほら、おいてかれるわよ」推进到下一句。
    鼠标同序列：点卡内后前台同样变成卡片，卡外点击 `global click … consumed=0`，台词未推进（护盾兜住）。
  - 修复后：同一触摸序列前台全程是游戏（`lookup activation vetoed code=9`），卡外触摸 `consumed=1` 关卡、台词不变；
    卡内触摸点词嵌套查词正常、卡上横滑关卡正常（BUG-2770）；鼠标同序列 `consumed=1`、台词逐像素不变。
- **备注**：
  - 这是查词卡窗口本身的修复，所有引擎的游戏内查词卡 / 应用外全局查词共用，不按引擎特判。
  - 用户原机是 Surface（别人的机器），未在原机复测；本机触摸数字化器 + `InjectTouchInput` 复现并验证。
  - 卡片从此在鼠标 / 触摸下都拿不到键盘焦点，这正是创建处注释写明的设计保证（「WS_EX_NOACTIVATE keeps the foreground app's
    keyboard focus intact (design §5 guarantee 3)」）；`assets/popup/` 卡片页面没有任何可编辑输入（`definition.js` 还会剥掉
    input/textarea），两个实例（游戏内查词卡、应用外全局查词）都不依赖焦点，复制走全局热键。
