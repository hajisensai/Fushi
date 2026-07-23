## BUG-1049 · 捕获目标没有自动选中 Hibiki 启动的游戏（窗口迟到即永久停在 window_not_found）
- **报告**：2026-07-24（用户截图指向捕获工作台的「捕获目标」条：「这个没有自动选中 hibiki 启动的游戏」）
- **真实性**：✅ 真 bug —— 两处，都在「Hibiki 明明知道自己刚启动的游戏 pid，却没把它当成已选中的目标」这条线上：
  1. `hibiki/lib/src/mining/gal_hook_session_controller.dart:627`（修复前）：launch 后按 `gamePid` 找顶层窗口只是**一次性**轮询 `windowPollAttempts(20) × windowPollInterval(500ms)` = 10 秒，失败即 `phase=degraded / fallbackReason=window_not_found` 且**永不重试**。带启动器、壳解包（Enigma/Siglus）、首次着色器编译的游戏常常慢过 10 秒，首帧一错过就只能靠用户自己去点「捕获目标」条手动选窗口。
  2. `hibiki/lib/src/pages/implementations/texthooker_page.dart:319`（修复前）：窗口选择器把系统全部顶层窗口平铺成一个无序 `SimpleDialog`，既不按会话 `gamePid` 排序、也没有任何预选/标注——等于让用户替 app 认它自己拉起的进程。
- **[x] ① 已修复** —
  - 会话侧：`_startWindowRebindWatch` / `_tryRebindWindow`（会话级 `Timer.periodic`，默认 2s，构造参数 `windowRebindInterval` 可注入）。绑定成功、会话换代（stop/重启/attach）、pid 变更即自停；`_stopSources` 统一回收。补绑只更新状态并把因 `window_not_found` 降级的会话恢复回真实 phase（有文本信号 → `running`，否则 `waitingSignals`），**不走 `bindWindow`**——那条路径会 `startAttachedCapture` 重启整条会话（launch 会话退化成 attach，正在跑的 engine hook 与已收台词一起丢）。
  - 选择器侧：按 `gamePid` 把 Hibiki 启动的游戏排到第一条、加「当前游戏」标注（新 i18n key `external_window_current_game`）、并用 `ListTile(autofocus:)` 预置焦点（焦点驱动纪律：打开即落在正确窗口上，Enter 直接确认）。另外，选回**已绑定**的那个窗口现在是 no-op，不再触发上述会话重启。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/mining/gal_hook_session_controller_test.dart`：「窗口迟到时会话继续重绑，不停在 window_not_found」「会话停止后不再继续重绑窗口」两条行为测试（假 window loader 先返回空、后返回游戏窗口）。
  - `hibiki/test/pages/texthooker_window_picker_guard_test.dart`：选择器源码守卫（按 `gamePid` 置顶、`autofocus`、选回已绑定窗口 no-op）。`_pickExternalWindow` 首行是 `Platform.isWindows` 门 + 静态 `WindowCaptureChannel` + 单例会话，widget 测试不可移植，故锁结构。
- **备注**：**待 Windows 真机复测**——从游戏库/工作台启动带启动器或壳的游戏，确认窗口迟到时仍会自动绑上；并确认点开「捕获目标」条时当前游戏已在首位且带焦点。
