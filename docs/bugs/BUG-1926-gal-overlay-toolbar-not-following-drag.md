## BUG-1926 · 穿透态 galgame 浮窗：拖正文时顶栏不跟随

- **报告**：2026-08-29（用户：「鼠标按住字 gal 弹窗的文字时它跟着动了，但是顶栏没有一块跟着动」）
- **真实性**：✅ 真 bug。只在**穿透模式开着**时出现（非穿透态顶栏画在正文窗内部，随窗移动是天然的）。
- **根因**：`fushi/windows/runner/floating_lyric_window.cpp:1023`（修前）—— `WM_MOUSEMOVE` 的
  `if (dragging_)` 分支自己裸调 `SetWindowPos(hwnd_, ..., SWP_NOSIZE | SWP_NOACTIVATE)` 之后
  **直接 `return 0`**。

  穿透态下浮窗是**两个平级的顶层窗口**：正文窗 `FloatingLyricWindow` + 独立顶栏窗
  `HookToolbarWindow`（`hook_toolbar_window.h:12-40` 写明了理由：穿透是整窗属性，单窗做不到
  「正文穿透、顶栏可点」，BUG-951）。顶栏位置由正文窗**单向下推**，唯一入口是
  `SyncPassThroughToolbar()`（`floating_lyric_window.cpp:899`），而它当时只有三个调用点，
  真正管用的那个挂在 `Render()` 末尾。

  拖正文时 `Render()` 一次都不发生：
  - 正文窗是 layered 窗，`SetWindowPos(SWP_NOSIZE)` 只移动已提交的位图，**不产生
    `WM_PAINT` / `WM_SIZE`**；
  - `HandleMessage` 里**没有 `WM_MOVE` / `WM_WINDOWPOSCHANGED` 分支**；
  - `hovered_` 拖动前已是 true，`WM_MOUSEMOVE` 顶部那次 `RequestRender()` 不触发；
  - `dragging_` 分支提前 `return 0`，后面的 hover/tooltip 渲染路径走不到；
  - 抬手 `WM_LBUTTONUP` 只做 `CancelPointerGesture()` + `NotifyBoundsChanged()`，都不 Render。

  于是顶栏原地不动，直到下一句台词触发 Render 才「瞬移」过去。

  **同根因的第二个症状**：`hook_toolbar_window.cpp:771` 拖顶栏时用的
  `layout_.owner_origin` 只在 `Sync()` 里更新 —— 拖过正文之后再去拖顶栏，正文会按上一次的
  位移量瞬移一下（`hook_toolbar_window.h:107-110` 的注释早就警告过这个 teleport）。

  **第三处同类漏洞**：`WM_EXITSIZEMOVE` 调的 `ClampCurrentPositionToWindowMonitor()` 内部也是
  裸 `SetWindowPos`，之后既不 Render 也不 Sync。

- **[x] ① 已修复** — 1d2053fdf4。把「移动正文窗」收成**唯一原语**：拖动分支改调已有的
  `MoveBodyTo()`（它本来就带 TODO-832 的工作区钳制 + BUG-951 的顶栏同步，且与拖动分支那 25 行
  逐行等价 —— 典型的「同一逻辑抄两遍、其中一份漏了收尾」）；`ClampCurrentPositionToWindowMonitor()`
  内也补上同步，使「凡是挪了正文窗的地方都同步顶栏」成为不变式。没有新增任何 `if (pass_through_)`
  门（BUG-1480 之后禁止的模式），滚动条 thumb 拖动在更早的分支就 `return 0`，不受影响。
- **[x] ② 已加自动化测试** — `fushi/test/tools/gal_overlay_passthrough_dual_window_guard_test.dart`
  新增 group「BUG-1926 · 移动正文窗只有一条原语，顶栏不可能掉队」3 条：`MoveBodyTo` 里必须同时有
  钳制与同步；拖动分支必须走 `MoveBodyTo(` 且**不得**出现 `SetWindowPos(`；`Clamp` 里必须有同步。
  判据前先 `maskComments()`（修复注释本身大段写了 `SetWindowPos` / `MoveBodyTo`，不剥注释守卫恒绿）。
  变异实测：把拖动分支换回裸 `SetWindowPos`、把 `Clamp` 里的同步删掉，对应两条各自变红。
- **备注**：源码扫描钉的是**接线**，不是运行时行为。真机拖动观感仍需 Windows 实机复看（未做）。
