## BUG-1689 · 点查词弹窗右下角 grip 把 Hibiki 主窗拉到前台
- **报告**：2026-08-16（用户：「点击剪切板弹窗右下角的时候会把 fushi 主界面拉到前台，删掉这个设定」）
- **真实性**：❓ 按用户字面描述**未复现**——真机两种去向下主窗都没有被拉到前台。最接近的真实行为是**悬浮面板去向下面板窗自己抢走前台/焦点**（现有刻意取舍，见下）。需用户确认是哪一种，再定修法。
- **[ ] ① 未修复** — 待用户确认现象后定；若确认是「面板抢焦点」，那是取舍变更不是 bug 修复（见「若要改，代价是什么」）
- **[ ] ② 未加自动化测试** — 真机行为，headless 测不到；守卫只能钉窗口 ex-style 契约
- **备注**：与 BUG-741（瞬态窗 owned → Z 序连带拉主窗，已改无 owner）、`SetTopmost` 缺 `SWP_NOOWNERZORDER`（真机症状=点图钉把主 app 拉到前台，已修）是同类症状的第三次报告，但那两个根因在本条路径上都已不成立。用户在跑的包是 2.1.1+11666（2026-08-15 构建），两处修复都已包含。

### 现象（用户描述）
Windows 桌面剪贴板查词，弹窗右下角是尺寸拖拽 grip。点它时 Hibiki 主界面被拉到前台。

### 代码路径（已全部走通）
- 弹窗右下角**唯一**可点元素是 resize grip：面板 `#global-lookup-panel-resize`、瞬态卡 `.global-lookup-resize-grip`（`fushi/assets/popup/global_lookup_host.js:563` / `:516`，创建于 `:722` / `:1060`）。mousedown 只 `postToHost('beginWindowResize')`，不查词、不走桥。
- native 收到后 `ReleaseCapture()` + `PostMessage(hwnd_, WM_NCLBUTTONDOWN, HTBOTTOMRIGHT, 0)` 进 DefWindowProc 模态 size 循环（`fushi/windows/runner/global_lookup_window.cpp:2129`）。
- 结束只有 `WM_EXITSIZEMOVE` 一条出口，只回报 rect、不动 Z 序（`:2680`）；Dart 侧收到只持久化 rect（`fushi/lib/src/lookup/clipboard_panel_controller.dart:562`），不调 show/focus。
- 全仓唯一能把主窗提前台的出口是 `DesktopLookupService.bringMainWindowToFront()`，调用点为词典页消费 `bringToFront` 策略、悬浮字幕点词、gal「打开工作台」——resize 路径一个都不经过。
- 窗口形态：面板 `SetActivatable(true)`（`flutter_window.cpp:1595`，实测 exStyle `0xC0008` = LAYERED|APPWINDOW|TOPMOST，**无** NOACTIVATE）；瞬态卡实测 exStyle `0x8000088`（**有** NOACTIVATE）。两者都无 owner（`flutter_window.cpp:1678`/`:1700` 传 nullptr）。

### 真机复现（2026-08-16，本机 Windows 11，3840x2160 @150%）
方法：本 worktree `flutter build windows --debug` 产物，构建期临时改 `Runner.rc` 的 CompanyName/ProductName 与单实例互斥体名，使验证实例拥有**独立数据目录**（`%APPDATA%\FushiGripProbe\`）、独立 WebView2 用户目录（`FUSHI_WEBVIEW2_USER_DATA_FOLDER`），**完全不碰用户生产库**、也不与用户正在运行的 2.1.1+11666 抢单实例。脚本 `grip_repro.ps1`：前台停在第三方窗口 → `Set-Clipboard` 日文 → 按 PID 找到本实例弹窗 → `WindowFromPoint` 确认 grip 像素归属 → `SendInput` 真实拖拽 → 读 `GetForegroundWindow`。

| 去向 | 弹窗 | 拖 grip 后 rect | 拖 grip 后前台 |
|---|---|---|---|
| `panel`（默认） | `Fushi 剪贴板查词`，可激活 | 180,180-750,1020 → 180,180-**810,1060**（生效） | **变成面板窗自己**；主窗不动 |
| `transient` | `Fushi Lookup`，NOACTIVATE | 0,0-1572,2038 → 0,0-**1632,2078**（生效） | **完全不变**（仍是第三方窗口） |

结论：**主窗在两种去向下都没有被拉到前台**。面板去向下被抢走前台的是面板窗本身——这是 2026 真机第 4 轮刻意选的取舍（`global_lookup_window.cpp:795` 注释：面板不带 NOACTIVATE，「点击面板时焦点落面板，滚轮不再穿到底下仍持焦点的游戏」）。

### 已证伪的候选修法
把 grip 的模态循环入口从 `WM_NCLBUTTONDOWN` 换成 `WM_SYSCOMMAND` + `SC_SIZE|WMSZ_BOTTOMRIGHT`（理由是 NC 按下带激活语义）。真机实测该版本 **resize 完全失效**（rect 一动不动）：这些窗口是 `WS_POPUP`，没有 `WS_THICKFRAME`/`WS_SIZEBOX`，DefWindowProc 直接忽略 `SC_SIZE`。已丢弃，未进任何提交。

同期写的三版最小 Win32 探针（`activation_probe*.ps1`）结论**全部作废**：它们的 `MOUSEINPUT` 结构多带两个填充字段，`Marshal.SizeOf` 算出 48 而非 40，`SendInput` 的 `cbSize` 不匹配被内核拒绝，合成点击从未落到目标窗口（同一个 bug 也让第一轮真机脚本的拖拽落空）。**不得引用那批输出。**

### 若要改，代价是什么
若用户确认现象就是「面板抢走焦点」：面板可激活是为了让滚轮落在面板上而不是穿透给底下仍持焦点的游戏。要让点 grip 不夺焦点，只能把面板改回 `WS_EX_NOACTIVATE`（滚轮穿透回归），或者给 chrome 区域单独做不激活的拖拽实现（自管 `SetCapture` + 鼠标跟踪，不进系统模态循环）。前者是取舍回退，后者是真改造，都需要用户先拍板。

### 待办
1. 请用户确认：跳到前面的是**主界面窗口**（书架/词典那个大窗），还是**查词面板自己**？
2. 若是主界面：要它的复现前提（去向设置、窗口置顶模式、是否 pin、主窗当时是否最小化），现有两种去向的默认组合都复现不出来。
