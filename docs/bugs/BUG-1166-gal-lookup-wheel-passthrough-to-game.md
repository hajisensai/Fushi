## BUG-1166 · galgame 查词卡滚轮穿透到游戏
- **报告**：2026-07-27（用户：「gal窗口，点击查词的时候，用滚轮滚动查词界面会导致 gal 动」）
- **真实性**：✅ 真 bug —— 根因 `hibiki/windows/runner/low_level_mouse_hook.cpp:34`（修复前的 `HookProc`：只认 button-down，滚轮一律 `CallNextHookEx` 放行）。

  瞬态查词卡按设计是**非激活窗**：`hibiki/windows/runner/global_lookup_window.cpp:904` 的 `(activatable_ ? 0 : WS_EX_NOACTIVATE)`，加上 `ShowAt` 全程 `SW_SHOWNOACTIVATE` / `SWP_NOACTIVATE`（`global_lookup_window.cpp:426-428`）——查词卡出现时前台键盘焦点原地不动（design §5 保证 3）。

  而 Windows 的 `WM_MOUSEWHEEL` 是投给**键盘焦点窗口**的。焦点始终留在 galgame 上，滚轮就照样喂给游戏（多数 VN 引擎：上滚开履历、下滚推进文本）。Win10 的「悬停滚动非活动窗口」只是个可关的用户选项，指望不上；而我们这条链上**没有任何一处消费滚轮**，所以卡片滚不滚都改变不了游戏在动这件事。

  这不是推断出来的孤例：同一现象在剪贴板面板上已有真机记录 —— `hibiki/windows/runner/global_lookup_window.h:147-150`「面板窗可被激活：不带 `WS_EX_NOACTIVATE` 创建，点击面板时焦点落在面板上（**游戏失焦，滚轮不再穿到底下的游戏**）」。面板靠抢焦点绕开了，瞬态查词卡不能——很多 VN 一失焦就暂停/变暗，且会破坏 design §5 保证 3。
- **[x] ① 已修复** — 在**已有**的 `WH_MOUSE_LL` 专用线程钩子（BUG-1048 建立）上补一条滚轮通道，不动焦点模型：
  - `low_level_mouse_hook.cpp` `HookProc`：滚轮落点真的压在卡片上 → `PostMessage(kLowLevelMouseWheelMessage)` 把「坐标 + 有符号 delta + MK_* 修饰键 + 水平标志」投给窗口线程，然后**返回 1 吞掉**（事件不进任何线程的输入队列，前台游戏收不到）。卡片外 / 无目标 / 非滚轮一律 `CallNextHookEx` 放行——不做全局滚轮黑洞。
  - 命中判定用 `WindowFromPoint`（认窗口区域）而**不是**点击那条路的 `GetWindowRect`：级联查词的 HWND 是整叠卡片的包围盒，TODO-1345 的「保留地板」窗更横跨大半个工作区，真正可见的只有 `ApplyRoundedRegion` 用 `SetWindowRgn` 裁出来的那几块卡片（BUG-749）。按 rect 判会在卡片一打开时就吞掉大半个屏幕的滚轮，等于把「穿透到游戏」换成「整屏滚轮失灵」。卡片之间的透明缝隙判为「不在」，滚轮照常归游戏——那儿用户看到的本来就是游戏。
  - 修饰键用 `GetAsyncKeyState`（物理按键，跨线程有效）而不是 `GetKeyState`（钩子线程自己那份从不更新的输入状态，永远返回「没按下」），Ctrl 缩放（BUG-1033）/ Shift 横滚不丢。
  - `GlobalLookupWindow::HandleGlobalWheel`：还原成与真 `WM_MOUSEWHEEL` 同构的 `wparam`/`lparam`（屏幕坐标），按模式走 WebView2 各自既有的输入路——composition 实例经 `ForwardCompositionMouse`/`SendMouseInput`，windowed 实例投给光标压着的 WebView2 **子 HWND**（投回顶层窗只会走 `DefWindowProc`，顶层窗不往下传，卡片一样滚不动）。
  - 快路不回退：移动事件仍在读任何状态、做任何系统调用之前就被纯比较挡掉（BUG-1048/1077），`GetAsyncKeyState` 只在滚轮事件上跑。
  - 剪贴板面板实例不受影响：它 `arm_dismiss_hooks_=false`，从不 arm 这个钩子。
- **[x] ①b 复审推翻了一条原始假设：修饰键过不了「合成 WM_MOUSEWHEEL」那道边界** —— 这是本轮真正的根因补完。

  上面 ① 里「窗口线程直接 `MAKEWPARAM(keys, delta)` 就是一条真滚轮消息，Ctrl 缩放 / Alt 换词条都不会丢修饰键」**是错的**：
  - windowed 模式下我们 `PostMessage` 的是一条**合成**消息，而 Chromium 取 `ctrlKey/altKey` 走 `KeyStateFlagsFromNative()` → **`GetKeyState()`，根本不读 wparam 的 `MK_` 位**；
  - `GetKeyState` 只在线程从队列取到**硬件输入消息**时才更新其键状态表，`PostMessage` 是非输入消息，且查词卡是 `WS_EX_NOACTIVATE`、WebView2 的线程不在前台输入队列里 → `e.ctrlKey` 恒 false，**PR#462（BUG-1139）刚修好的 Ctrl+滚轮缩放会静默退化成普通滚动**；
  - Alt 更是**结构性**丢失：`WM_MOUSEWHEEL` 没有 `MK_ALT`，`COREWEBVIEW2_MOUSE_EVENT_VIRTUAL_KEYS` 也没有 ALT，而 Alt+滚轮跳词条（`popup.js` 的 `popupEntryWheelAction`，绑定见 `shortcut_defaults.dart`）在 app 外浮窗**本来就生效**（绑定注入不受 `globalLookup` 门控）。

  修复：把修饰键当**数据**送进 web 层，不指望 Chromium 的键状态。
  - `low_level_mouse_hook.cpp` 顺带取物理 Alt（`GetAsyncKeyState(VK_MENU)`），`ctrl`/`alt` 作为**独立载荷字段**（bit 33/34）随 `PackMouseHookWheel` 带走 —— `MK_` 位只留给裸滚轮那条原生快路，不再承担修饰键真值。
  - `GlobalLookupWindow::HandleGlobalWheel` 新增**分流点**：`wheel.ctrl || wheel.alt` → `ForwardGlobalWheelToHost`，排在两条合成路（`PostMessage` / `ForwardCompositionMouse`）**之前**。
  - `ForwardGlobalWheelToHost` 复用 `ForwardGlobalClickToHost` 同一条边界约定（屏幕物理 px → 窗口内 CSS px，同一套 dpr 换算），`ExecuteScript` 调 `window.__globalLookupHost.handleGlobalWheel(x, y, deltaY, ctrl, alt, shift)`；Win32 delta 与 DOM `deltaY` **方向相反**，在此一次性转成 DOM 约定（上滚为负），JS 侧分辨不出自己收的是合成事件。
  - `global_lookup_host.js` 新增 `handleGlobalWheel`：`frameIdAtPoint` 找到命中的那张卡，往它的 document 派发一条 `bubbles/cancelable` 的 `WheelEvent`，**三个修饰键 flag 全部来自入参**。缝隙/无 realm 不派发。
  - **C++ 只做传输，不做策略**：Ctrl→缩放、Alt→换词条的判定仍然分别留在 `_globalLookupZoomWheelJs` 与 `popup.js` 的 `popupEntryWheelAction` 里——绑定真值 `__hoshiEntryWheelBindings` 用户可改键位，绝不把这份语义复制进 C++。于是 Ctrl 依旧沿 `callHandler('popupZoomFontStep')` → `jsMessage` → Dart `maybeHandleOverlayZoomFontStep` 落地，**PR#462 的链路整条复用、一行不改**。
  - **裸滚轮 / 仅 Shift 不绕道**，仍走原生子窗 `PostMessage`：那条路本来就是对的，绕道反而丢掉浏览器自己的平滑滚动与 Shift→`deltaX` 横滚转换。
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_wheel_passthrough_guard_test.dart`（7 项源码守卫：① 认两个方向的滚轮且 `return 1` 吞掉；② 命中必须按窗口区域（`WindowFromPoint`）判、滚轮这条路上不许出现 rect 判定、卡片外/无目标必须放行、至少 4 条放行路；③ 移动事件的纯比较快路在所有系统调用之前；④ 只 `PostMessage` 不 `SendMessage`；⑤ delta 打包/解包两侧都符号扩展；**⑤bis（本轮新增 7 项，替掉旧那条“只断言调了 GetAsyncKeyState”的假信心守卫）**：钩子取物理 Alt 且 ctrl/alt 是独立载荷字段（打包/解包同位）、分流分支存在且**排在两条合成消息之前**、裸滚轮仍走原生 `PostMessage`、C++ 三个修饰键显式传参、host JS 的 flag **来自入参**而非环境键状态且只投命中帧、**方向端到端不翻**（Win32 上滚 → DOM 负 `deltaY` → +1 档 → `zoomFontSizeAfterSteps` 真的变大）、Ctrl 链路末端 `popupZoomFontStep` 真被既有 Dart 消费端接住；⑥ 窗口侧还原成真滚轮并走子窗/composition 两条既有输入路、消息真的接进 `HandleMessage`；⑦ 瞬态窗必须保持 `activatable_=false` + `WS_EX_NOACTIVATE`，不许靠抢焦点「顺手」解决）。另在 node harness `hibiki/test/lookup/global_lookup_host_test.mjs` 加了**行为级** W1：`handleGlobalWheel` 必须把 `ctrlKey`/`altKey` 以**显式 flag** 派发进命中的那一帧（包括 `bubbles`/`cancelable`/DOM 方向约定），未命中帧不收、缝隙不派发。
  **三条负向验证均已实跑**（“没有负向验证的守卫等于没有守卫”）：① 把 host JS 的 flag 写死成 `false` → W1 以“ctrlKey 必须显式带到 JS”报错；② 抽掉 `HandleGlobalWheel` 的分流分支 → Dart 守卫以“必须按有没有按 Ctrl/Alt 分流”转红；③ 去掉 delta 取负 → Dart 守卫以“不取负就把缩放做反了”转红；三次还原后均重新全绿。
  Win32 输入队列与 WebView2 那段仍只能靠源码守卫（Dart 跑不了），故两层并用。
- **备注**：native 改动，**待 Windows 真机复测**原始失败路径（galgame 会话中查词后滚轮滚卡片：卡片要能滚、游戏不许动、Ctrl 缩放仍在、游戏别处滚仍能正常操作游戏）。
  - **叙述上的诚实保留（不要为了让故事圆满而删掉）**：上面把根因归到「`WM_MOUSEWHEEL` 投给键盘焦点窗口」，但 Win10/11 的「悬停滚动非活动窗口」（`MouseWheelRouting`）**默认是开启的**，开启时滚轮本就路由到光标下的窗口（= 查词卡）而非焦点窗口——按这套叙述，用户报的症状本不该出现。所以真实成因要么是该选项被关，要么另有其因（例如引擎走 Raw Input / DirectInput 直读滚轮，见下条）。**吞掉滚轮在两种解释下都是必要且正确的一步**，故本修复不因此改变；但这意味着**真机复测是真门槛，不是走过场**——不能靠推导宣称修好。
  - **Shift+滚轮横滚未验证**：仅 Shift 的滚轮仍走原生 `PostMessage` 快路，其横滚（Shift→`deltaX`）依赖 Chromium 的 `GetKeyState`，同样可能在合成消息上失真，退化成普通竖滚。没有把它一起分流是因为：合成 `WheelEvent` 只能给出 `deltaY`，浏览器把 Shift 转成 `deltaX` 发生在**原生**层，绕到 JS 反而更差。真机复测时一并观察；若确认失真，正解是在 C++ 侧改投 `WM_MOUSEHWHEEL`（需真机确定符号方向），不要在 JS 里造 `deltaX`。
  - **已知边界**：低级钩子拦的是窗口消息输入流。若某引擎绕过消息、用 Raw Input / DirectInput 直读滚轮（Unity / SDL 系较常见，KiriKiri / Siglus / BGI 等主流 VN 引擎走窗口消息，本修复覆盖），则钩子层可能拦不住——真机复测时若仍有引擎会动，按引擎单独立项，走 `native/galgame_hook/` 的进程内过滤，不要在这里加特例。
  - **同族未修**：hook 台词浮窗（`floating_lyric_window.cpp`，BUG-1095 的滚动）同样是 NOACTIVATE 窗，滚它理论上也会穿到游戏。它不 arm 任何 LL 钩子，为它常驻装一个正是 BUG-1048 警告的形状，故本轮不顺手改；用户真遇到再单独立项。
