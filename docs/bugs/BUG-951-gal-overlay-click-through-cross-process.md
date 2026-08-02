## BUG-951 · Hook 浮窗鼠标穿透 HTTRANSPARENT 跨进程不生效存疑须真机验证
- **报告**：2026-07-21（PR#295 落地审查 H2，fable5）
- **真实性**：✅ 已确定性复现为真（2026-07-27）。最小跨进程 Win32 装置（两组对照，每组一对全新进程 + 一次真实 SendInput 点击）：体表 alpha=5/200 配 `HTTRANSPARENT` 时点击被完全吞掉（游戏和浮窗都收不到）；换 `WS_EX_TRANSPARENT` 后另一进程正常收到，与逐像素 alpha 无关。根因：`HTTRANSPARENT` 按 Win32 契约只在**同线程**窗口间下传，游戏是另一进程。
  - 一直没被发现的原因：旧代码只在「背景不透明度=0」时看起来能用，那是层窗口逐像素命中测试的功劳；点在不透明的文字笔画上照样被吞。
- **[ ] ① 已实现，未验收（implemented_unverified）** — 双窗设计（本轮，PR#481）。代码已落地但**没有任何一条真机验收跑过**，按本仓 galgame 硬规则不得记为已修复。
  - 修前：`hibiki/windows/runner/floating_lyric_window.cpp` 的 `WM_NCHITTEST` 在穿透态对正文返回 `HTTRANSPARENT`，跨进程无效。
  - 中途被否的一版（PR#460，已 revert）：按光标位置 16ms 轮询开关整窗 `WS_EX_TRANSPARENT`。它命中既有守卫 `interactivity is not driven by a hover timer`，且被证明**本质竞态**——定时器可被饿死，期间用户快速甩到工具条点一下会穿过去点进游戏，推进台词或选中分支破坏存档。
  - 本轮定案：**不再让一个窗口同时当两种东西**。
    - 正文窗（`FloatingLyricWindow`）在穿透态**静态**置 `WS_EX_TRANSPARENT`，纯视觉，整窗对鼠标不存在；`WM_NCHITTEST` 里的 `HTTRANSPARENT` 分支整块删除。
    - 工具条搬进独立顶层窗 `HookToolbarWindow`（`hibiki/windows/runner/hook_toolbar_window.{h,cpp}`），**永不**带 `WS_EX_TRANSPARENT`，因此永远可点。没有状态可翻转，也就没有竞态可输。
  - 关键不变量（写进代码而非只写文档）：`ApplyPassThroughExStyle()` 是唯一入口，**先**把工具条窗放上屏、**再**让正文停止接收点击；工具条建不出来就退回不进穿透并把 `pass_through_` 摁回 false（宁可忽略这次切换，也不把用户关在一个点不动的浮窗后面）。
  - 顺带收敛：8 个槽位的 action / 字形 / 高亮态收进共享表 `hook_toolbar::kSlotActions` + `SlotGlyph/SlotActive`，两个窗口同表索引，物理上无法对「第 3 个按钮是什么」产生分歧；按钮执行逻辑收进单一 `DispatchControlAction()`。
  - 行为差异（有意）：穿透态下正文窗不再自绘顶部工具条带与拖拽把手（它们已不接收鼠标，画出来就是骗人）；独立工具条在静止时以约 42% 不透明度常驻——它是唯一的退出口，隐形的退出口等于没有退出口。穿透态挡住游戏的死区从「整窗宽 × 约 34dip」缩小为「约 320dip × 40dip 的药丸」。
  - 非 hook 实例（有声书歌词条 / 剪贴板文本窗）完全不进这条分支，窗口样式与渲染逐像素不变。
- **[ ] ② 只有源码扫描守卫，缺运行时验证** — `hibiki/test/tools/gal_overlay_passthrough_dual_window_guard_test.dart`（新增，源码扫描守卫）：
  - `WS_EX_TRANSPARENT` 只允许在 `SetBodyExTransparent` 内被应用，且必须配 `SWP_FRAMECHANGED`；`SetBodyExTransparent` 只允许被 `ApplyPassThroughExStyle` 调用；
  - `return HTTRANSPARENT;` 在两个文件中都不得出现；**定时器不得翻转可交互性**（PR#460 回归门，判据见下方「PR#460 回归门的判据修正」）；
  - **顺序不变量**：`pass_through_toolbar_.Show(` 必须出现在 `SetBodyExTransparent(true)` 之前，且失败路径必须把 `pass_through_` 摁回 false；
  - 工具条窗建窗 flags 不含 `WS_EX_TRANSPARENT`、含 `WS_EX_NOACTIVATE` / `WS_EX_TOPMOST`，且全文件没有 `GWL_EXSTYLE` 改写；
  - 两窗共表（8 个 action 顺序逐个比对）、共字形、共派发、几何由正文窗单向下发；
  - `CMakeLists.txt` 真的编了新 TU。
  - 同时把 `hibiki/test/media/audiobook/floating_lyric_click_through_guard_test.dart` 里那条「禁止一切 `WS_EX_TRANSPARENT` 改写」的旧断言换成新契约：**保留**反定时器判据（那才是 PR#460 的真教训），把「禁用该位」换成「必须走唯一 applier + 必须有逃生工具条」。旧断言正是浮窗长期带着一个跨进程无效的穿透模式的原因，如实记录在测试注释里。
- **PR#460 回归门的判据修正（2026-08-02）** — 上面两条守卫里的反定时器判据原本写成四个 token 禁令（`PollCursorInteractivity` / `ApplyInteractive` / `SetTimer(` / `KillTimer(`，双窗守卫里还有 `Timer(` / `WM_TIMER`）。**禁的是关键字，不是行为**，两个方向都错：
  - **漏真阳**：`SetCoalescableTimer`、给 `SetTimer` 传一个自己的 `TIMERPROC`、`SetWindowsHookEx` 都能原样重建 PR#460，却绕开 `SetTimer(` 这个字面量；
  - **报假阳**：PR#749 给台词浮窗加「按住 Shift 悬停查词」的 60ms 轮询时被误伤——那个定时器只读光标位置派发查词，全程碰不到任何可交互性状态，还专门写了 `if (pass_through_) { StopHoverLookupPolling(); return; }` 主动让位（`floating_lyric_window.cpp` `MaybeHoverLookup`），却让两条守卫同时转红并把红带进 develop。
  - 判据改为不变式本身，收进 `hibiki/test/helpers/win32_interactivity_guard.dart` 的 `expectTimerCannotFlipInteractivity()`：① 每次装表必须把 TIMERPROC 传 `nullptr`，保证 `case WM_TIMER:` 是唯一定时器回调入口（否则后面的分析不完整）；② 禁 `SetWindowsHookEx`（离线程轮询光标，源码扫描分析不了它的回调）；③ 从每个 `case WM_TIMER:` 出发沿真实调用图做**可达性闭包**，闭包里出现任何可交互性写操作（`GWL_EXSTYLE` / `WS_EX_TRANSPARENT` / `SWP_FRAMECHANGED` / `HTTRANSPARENT` / `EnableWindow(` / `SetBodyExTransparent(` / `ApplyPassThroughExStyle(` / `pass_through_ =`）即红。
  - 一句话语义：信息只许**单向**流动——穿透态 → 定时器（定时器可以读到 `pass_through_` 并把自己停掉），反向一律禁止。
  - 变异实测（8 次，每次改完跑守卫、再按反向替换还原并逐字节比对）：PR#460 换成无辜命名、两跳之外重建 → 红；给 `SetTimer` 传自己的 `TIMERPROC` 绕开分析 → 红；在 `case WM_TIMER:` 里直接翻位 → 红；在 `case WM_TIMER:` 里加一句与可交互性无关的 `RequestRender()` → **绿**（判据不误伤）。
  - **局限（如实说明）**：源码扫描锁的是接线，不是运行时行为。跨进程点击真的落到游戏、以及工具条在任意时刻都可点，仍需下面的 Windows 真机验收。C++ 进不了 Dart 单测；更强的 Windows itest 层因本机冒烟门长期红而受阻，属成本取舍，不是跳过。
- 🔴 **还差什么（这条 bug 未完成的全部原因）**：Windows 真机四条验收**一条都没做**。跨进程点击是否真的落到游戏、工具条是否在任意时刻都可点，源码扫描一个字也证明不了。四条如下，全部通过前本条保持未完成：
  1. 开穿透 → 点浮窗覆盖的游戏正文区 → **游戏推进台词**（这条是 BUG-951 本身，其余三条都是它的配套）；
  2. 穿透态下点工具条 `↗` → 立刻退出穿透（不需要精准时机、不需要连点）；
  3. 穿透态下拖工具条 → 整个浮窗跟着移动且**不跳位**，松手位置被记住（审查中已修一处锚点错位：工具条曾拿自己的窗矩形当正文窗原点，第一帧会把正文窗平移约 205dip 并把药丸甩出光标）；
  4. 关穿透 → 正文区恢复查词与拖拽。
- **备注**：核心特性验证项，列入 Windows 真机验收清单。
