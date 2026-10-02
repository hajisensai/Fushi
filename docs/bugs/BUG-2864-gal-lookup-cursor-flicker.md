## BUG-2864 · galgame 内嵌查词卡上光标在系统指针与游戏自定义指针之间来回闪
- **报告**：2026-10-02（用户：录屏，CLANNAD Steam 版 / SiglusEngine；「有自定义鼠标指针样式的游戏，在查词框上会在系统指针和游戏指针样式来回闪」）
- **真实性**：✅ 真 bug。根因是两件事叠加：
  1. 自定义指针的引擎每帧只按几何决定光标：SiglusEngine_Steam.exe 1.1.134.0 `+0x281680` 起的函数
     `GetCursorPos → ScreenToClient → GetClientRect`，点落在客户区矩形内就按 tick 选动画帧，
     `GetCursor() != 目标` 时 `SetCursor`——不看客户区上方是否盖着别的窗口。
  2. runner 把查词卡的 owner 设成游戏 HWND（`fushi/windows/runner/global_lookup_window.cpp` 的
     `SetWindowLongPtrW(hwnd_, GWLP_HWNDPARENT, game)`，z 序与 SGRE 护盾契约依赖它）。跨线程 owner
     关系让系统隐式挂接两个线程的输入队列，卡片与游戏共用同一份「当前光标」：卡片在
     `WM_SETCURSOR` / WebView2 `CursorChanged` 里设系统指针，游戏下一帧又设回自定义指针。
  - 装置对照（假游戏照搬上述每帧逻辑 + 另一进程置顶不激活浮窗，鼠标停在浮窗上 3 秒采样
    `GetCursorInfo`）：浮窗**无 owner** 0 次切换；**owner=游戏** 72 次切换（箭头 ↔ 两帧自定义指针），
    与用户录屏同形。所以单有 1 不会闪，是 2 把游戏的违规 `SetCursor` 放进了卡片的队列。
- **[x] ① 已修复** — 注入 DLL 引擎无关地 detour `user32!SetCursor`（`native/galgame_hook/hook/overlay_cursor_guard.{h,inc}`）：
  鼠标此刻归属的根窗口（有捕获取捕获窗，否则 `WindowFromPoint`）是**别的线程**的 `Fushi*` 类窗口时扣下这次调用、返回当前光标；
  其余原样放行。owner 关系保留不动。同一装置注入新 DLL 后：owner 浮窗上 1 次切换（首个采样是浮窗收到首次移动前的旧光标）后稳定为箭头；
  鼠标回到游戏区域，游戏动画指针照常切帧（14 次，与未注入一致）。
  真游戏未复测：当次本机 Steam 未运行，CLANNAD 的 steam_api 初始化起不来。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/overlay_cursor_guard_test.cpp`（CTest `fushi_overlay_cursor_guard_test`，
  真 Win32 窗口跨线程：别的线程的 Fushi 窗扣下、第三方窗 / 同线程窗 / 本线程捕获 / 已销毁窗放行，类名前缀判定）。
- **备注**：只认 `Fushi` 前缀类名，第三方覆盖窗口（Magpie 等）的光标归属不受影响；点击穿透的分层窗口会被 `WindowFromPoint` 跳过。
