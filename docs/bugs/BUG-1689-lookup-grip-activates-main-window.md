## BUG-1689 · 点剪贴板查词面板把 Hibiki 主界面抬到用户窗口之上
- **报告**：2026-08-16（用户：「点击剪切板弹窗右下角的时候会把 fushi 主界面拉到前台，删掉这个设定」；补充复现前提：「需要主窗口非最小化才行」）
- **真实性**：✅ 真 bug。根因在 `fushi/windows/runner/global_lookup_window.cpp` 的 `Reveal()`——面板是**可激活**窗口（`flutter_window.cpp:1595` `SetActivatable(true)`）而 runner 主窗一直是本线程的**活动窗口**，Windows 前台切换会先把活动窗口抬升再把激活交给被点的窗口。与右下角 grip 无关：点面板任何位置都复现。
- **[x] ① 已修复** — `Reveal()` 里对可激活实例调 `SetActiveWindow(hwnd_)`，让面板自己接管本线程活动窗口；被系统顺带抬升的对象变成面板（它本来就该在最上），主窗不再被牵动。真机前后对照见下。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/clipboard_panel_guard_test.dart` 新增「BUG-1689：可激活面板 Reveal 时接管本线程活动窗口」：钉 `SetActiveWindow(hwnd_)` 存在、且必须落在 `Reveal()` 的 `if (activatable_)` 分支内（无条件调用会让带 `WS_EX_NOACTIVATE` 的瞬态卡/gal 卡窗也去抢活动窗口）。断言走 `containsCodeLine`，避免被同文注释喂绿。**已变异实测**：删掉 `if (activatable_) { SetActiveWindow(hwnd_); }` 后该用例失败，还原后源码 sha256 与变异前逐字节一致。
- **备注**：与 BUG-741（瞬态窗 owned → Z 序连带）、`SetTopmost` 缺 `SWP_NOOWNERZORDER`（点图钉拉主窗）是同类症状第三次出现，但那两处根因在本条路径上都已不成立——用户跑的 2.1.1+11666 两个修复都含。

### 现象
Windows 桌面剪贴板查词，去向＝悬浮面板。用户在游戏/浏览器里复制词、面板弹出后点一下面板，Hibiki 主界面就浮到他正在用的窗口上面。**主窗最小化时看不见**（用户补充的前提），因为被抬升的是一个最小化窗口。

### 根因（真机插桩，主窗视角）
```
MAIN  WM_WINDOWPOSCHANGING  zorder-change  fg=FLUTTER_RUNNER_WIN32_WINDOW active=<main>
MAIN  WM_ACTIVATE           WA_INACTIVE    other=<面板 HWND>
POPUP WM_NCACTIVATE         active=1
POPUP WM_ACTIVATE           WA_CLICKACTIVE other=<main>
```
Z 序抬升发生在主窗收到「失活」之前，且当时前台已经是主窗自己：这一步是 **Windows 前台切换的中间态**——点击一个「所属进程不在前台」的可激活窗口时，系统先把该线程的活动窗口（runner 主窗）前台化并抬升，再把激活交给被点的窗口。本仓没有任何一行代码调用它：`grip` 只发 `beginWindowResize`；`WM_EXITSIZEMOVE` 只回报 rect；Dart 侧只持久化 rect；唯一能提前台的 `bringMainWindowToFront()` 在这条路径上没有调用点。

### 修复
`Reveal()` 中对 `activatable_` 实例调用 `SetActiveWindow(hwnd_)`。该 API 只改**本线程**的活动窗口，进程不在前台时不改变前台、不动 Z 序、不抢键盘焦点（面板仍 `SW_SHOWNOACTIVATE` 上屏），因此不动摇「面板可激活以避免滚轮穿透到底下游戏」这个 2026 真机第 4 轮的取舍。

### 真机验证（本机 Windows 11 / 3840x2160 @150%）
验证实例与用户环境完全隔离：构建期临时改 `Runner.rc` 的 CompanyName/ProductName 与单实例互斥体名，独立数据目录 `%APPDATA%\FushiGripProbe\`、独立 `FUSHI_WEBVIEW2_USER_DATA_FOLDER`，不碰生产库、不与用户运行中的 2.1.1+11666 抢单实例。脚本按 PID 找窗、`WindowFromPoint` 确认命中、`SendInput` 真实鼠标操作、按 `EnumWindows` 顺序读 Z 序名次（**只看 `GetForegroundWindow` 会漏判**：面板才是前台窗口，主窗是被抬升但没成为前台）。

| 操作 | 修复前 | 修复后 |
|---|---|---|
| 点面板正中（普通点击） | main **#9 → #7**，越过用户窗口(#7→#8) | main **#13 → #13**，用户窗口 #7 不变 |
| 拖右下角 grip | main **#17 → #7** | main **#13 → #13**；窗口尺寸 750→990 正常改变 |
| 瞬态卡去向拖 grip | 前台/Z 序均不变（`WS_EX_NOACTIVATE` 本就不参与激活） | 同左，未受影响 |

### 排查中被证伪的岔路（勿重走）
- **候选修法「grip 改走 `WM_SYSCOMMAND(SC_SIZE)`」**：真机实测 resize **完全失效**——这些窗口是 `WS_POPUP`、无 `WS_THICKFRAME`，DefWindowProc 忽略 `SC_SIZE`。已丢弃。
- **候选修法「主窗 `WM_WINDOWPOSCHANGING` 里 `SWP_NOZORDER` / 事后 `SetWindowPos` 推回」**：前者判据只能靠「鼠标键是否按下」，快速点击时读到的按键状态已复位，挡不住；后者真机实测系统给的插入位置与记录到的原前驱是同一个窗口，推回等于没动。两者都不是根因层。
- **三版最小 Win32 探针（`activation_probe*.ps1`）的结论全部作废**：`MOUSEINPUT` 结构多带两个填充字段，`Marshal.SizeOf` 得 48（应为 40），`SendInput` 的 `cbSize` 不匹配被内核拒绝，合成点击从未命中目标窗口——同一个 bug 也让第一轮真机脚本的拖拽落空、给出「未复现」的假象。任何"前台没变"的结论必须先确认输入真的送达（本次用 `GetCursorPos` 落点比对 + `WindowFromPoint` 归属双重确认）。
