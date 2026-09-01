## BUG-2006 · Windows 上视频最顶部有一条 1px 强调色线（窗口铺满屏幕时）
- **报告**：2026-09-01（用户：「视频最顶上有条线」，附 3840×2160 播放截图）
- **真实性**：✅ 真 bug，**已在用户真机的正式版上原地复现**。不是视频内容、不是解码 artifact，是 **Windows 自己画的窗口边框压在客户区第一行上**。
  - 截图像素取证：第 0 行整行 **3830/3840** 像素是同一个纯色 `RGB(110,140,131)`；四角各有一段 ~5px 圆角弧线同色，弧线外侧透出洋红 `RGB(143,47,153)`（桌面）；左/右/下边缘远离角落处**没有**这条线。
  - 身份确认：注册表 `HKCU\Software\Microsoft\Windows\DWM\AccentColor = 0xFF838C6E`（ABGR）→ `RGB(110,140,131)`，与线的像素值**逐位一致**；`ColorPrevalence=1`（"在标题栏和窗口边框上显示强调色"已开）。
  - **真机复现（用户正在运行的 `D:\APP\Hibiki\fushi.exe`，只读探针）**：`window L-8 T-1 R3848 B2168` / `client 0,0 3840x2160`（插框 `left=8 top=1 right=8 bottom=8`，客户区正好盖满显示器）、**`row0 强调色像素 = 3830/3840`**、角落 `(0,0)=143,47,153`。三项与用户截图逐位吻合。
  - **现场就是 `Win32Window::SetFullscreen` 的保边框巨窗态**（`showCmd=SHOWNORMAL IsZoomed=0` 是该路径的正常表现——进全屏前先 `SW_SHOWNORMAL` 解除最大化再放大）。**对照：真最大化态**（同一台机器只读实测 `showCmd=3 IsZoomed=1`、`window L-11 T-11 R3851 B2171`、插框 **11/11/11/11**）屏幕第 0 行是 `3840/3840` 应用表面色、**强调色 0 个**——边框全悬到屏外，**最大化没有这条线**。
  - 🔴 **决定成败的是插框不对称**：全屏态顶部插框只有 **1px**（window_manager hidden 标题栏的 `WM_NCCALCSIZE`），窗口顶边落在 `y=-1`，DWM 边框正好压在屏幕第 0 行；而左/右/下插框 8px 悬到屏外，所以**只有顶边这一条可见**。最大化态四向都是 11px，故全部悬出屏外。
  - 机制根因：`window_manager-0.5.1/windows/window_manager_plugin.cpp:172`（`title_bar_style_=="hidden"`）在 `WM_NCCALCSIZE` 里把客户区推到几乎贴满窗口矩形（Win11 分支 `top += IsWindows11OrGreater() ? 0 : 1`；上游注释自陈 `// on windows 10, if set to 0, there's a white line at the top of the app and I've yet to find a way to remove that.`）。这样一来 **DWM 画的 1px 边框与圆角落在客户区之上**——独立复现程序实测：照抄该 `WM_NCCALCSIZE` 的窗口，客户区填纯色后采屏，**顶行 600/600 像素是 chrome，左列/底行 0/600**。窗口一旦铺满屏幕，这行 chrome 就压在视频第一行上，四角的圆角裁切则透出桌面。
  - **为什么这个窗口态存在**（用户直接问了"不应该有这种全屏啊"）：Windows 端的全屏是 BUG-1933 / PR #1047 刻意选的**假全屏**——**不剥**边框风格，只把窗口放大到客户区盖满显示器、边框悬到屏外，再靠 `HWND_TOPMOST` 盖任务栏。原因是真全屏（window_manager `SetFullScreen` / media_kit `EnterNativeFullscreen`，均剥 `WS_CAPTION|WS_THICKFRAME` + `SWP_FRAMECHANGED`）会迫使 DWM 重建 frame visual、露一帧重定向表面（BUG-1933 的"闪一帧白"，实测进/出各 6/6 全露，保边框巨窗 0/6）。代价就是**在 Windows 眼里它仍是普通带边框窗口，DWM 照常画边框和圆角**——本 bug 即该设计的直接副作用。本 PR 取"保留巨窗但让 DWM 别画 chrome"，零几何改动、不回退闪白修复；若要改成真无边框全屏（专用 `WS_POPUP` 窗口）是另一项工程，需重验焦点/快捷键/media_kit 纹理。
  - ⚠️ **调查中一度把结论写反过**：`drive.exe` 假设「F11 = 进入全屏」，但用户 app 当时**本来就在全屏**，第一次 F11 是**退出**（退到最大化，故量到 `row0 = 0/3840`），被误记成「全屏态没有线」。靠 `IsZoomed/showCmd/插框` 三元组复核后推翻。**教训：只凭一次按键前后的几何差不能确定进/出方向，必须读窗口态本身。**
- **[x] ① 已修复** — 本提交。`fushi/windows/runner/win32_window.{h,cpp}` 新增单一策略点 `Win32Window::UpdateFrameChrome()`：当窗口 **① runner 全屏 `fullscreen_` / ② 已最大化 `IsZoomed` / ③ 客户区盖满显示器 `ClientCoversMonitor`** 三者任一成立时，置 `DWMWA_BORDER_COLOR = DWMWA_COLOR_NONE` + `DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_DONOTROUND`；否则还原 `DWMWA_COLOR_DEFAULT` / `DWMWCP_DEFAULT`。**这正是 Windows 自己对最大化窗口的做法**（最大化窗口不画边框、不圆角），自绘边框的窗口只是得自己开口要。调用点：`WM_SIZE`（每次几何变化重算）+ `SetFullscreen` 进入时（**在放大 `SetWindowPos` 之前**）与退出时（**在几何还原之后**）。带 `frame_chrome_suppressed_` 状态闩，**只在跨越边界时**下发 `DwmSetWindowAttribute`，拖拽缩放每帧只多一次比较（BUG-1917 节奏零影响）。**几何一行没动**，BUG-1933 的巨窗/置顶/快照/最大化还原逻辑零影响，也没有 1px 内容裁切。`dwmapi` 早已在 `fushi/windows/runner/CMakeLists.txt` 链入，无新依赖；两属性是 Windows 11 (22000+) 专有，旧系统 `DwmSetWindowAttribute` 失败即忽略（旧系统无圆角，且 window_manager 在 Win10 已保留 1px 顶边框）。
  - **归因实测**（独立复现程序，四阶段带阳性对照）：现状顶行非应用像素 600/600；只加 `DWMWCP_DONOTROUND` → 仍 600/600（**圆角不是线的成因**）；再加 `DWMWA_BORDER_COLOR=NONE` → **0/600**；还原默认 → **回到 600/600**。角落另测：现状与只加 `BORDER_COLOR=NONE` 时角落 8px 均 8/8 被裁，加 `DONOTROUND` 后 **0/8**。两个属性各修一个缺陷，无冗余设置。
  - **修复后真机 A/B/C**（worktree Debug 构建，隔离 `APPDATA`、走 `FUSHI_TEST_HIDDEN` 官方单实例绕过，**不碰用户正式版与生产 DB**；窗口激活态，判据用"客户区首行是否等于应用表面色"而非强调色，避免非激活窗口边框变灰导致对照失灵）：

    | 状态 | clientCoversMonitor | 客户区首行 | 判定 |
    |---|---|---|---|
    | A 普通窗口 `L613 T469` | 0 | 1/1513 与应用表面色 `245,250,253` 不同 | 边框在 ✅ |
    | B 客户区盖满屏 `L-8 T-1 R3848 B2168` | 1 | **3832/3832 = `245,250,253`**（与下方第 4 行一致）；四角同为应用内容 | 边框与圆角消失 ✅ |
    | C 还原普通窗口 | 0 | 回到 1/1513 | 边框恢复 ✅ |

    B 的窗口矩形与用户正式版被测到的**完全同一个**；同一矩形下正式版（无修复）是 `3830/3840` 强调色 + 角落 `143,47,153`，修复后是 `0/3840` + 角落应用内容。普通窗口边框保留且可恢复，**无永久性回归**。
- **[x] ② 已加自动化测试** — `fushi/test/build/win_fullscreen_flash_guard_test.dart` 新增 group `BUG-2006 edge-to-edge windows suppress the DWM frame chrome`（3 条源码扫描守卫，与既有 BUG-1933 的 9 条同文件共用 `maskComments` 基底，9 条无回归）：① 策略同时覆盖 `fullscreen_` / `IsZoomed(hwnd)` / `ClientCoversMonitor(hwnd)` 三条件并带 `frame_chrome_suppressed_` 状态闩；② `ApplyFrameChrome` 同时设 `DWMWA_BORDER_COLOR`(`NONE`/`DEFAULT`) 与 `DWMWA_WINDOW_CORNER_PREFERENCE`(`DONOTROUND`/`DEFAULT`)，且 `#include <dwmapi.h>` 在位；③ `WM_SIZE` 重算 + `SetFullscreen` 进入在 `HWND_TOPMOST` 之前、退出在 `HWND_NOTOPMOST` 之后。**变异实测 9/9 全红**（策略三个条件各删一个 / 删状态闩 / 边框色恒 DEFAULT / 圆角恒 DEFAULT / 删 WM_SIZE 调用 / 删 dwmapi include / 进入顺序倒置），每次以 sha256 校验精确还原原文件。
- **备注**：
  - **实测本机只有全屏态出线**（顶部插框 1px），**最大化态不出线**（四向插框 11px 全悬出屏外）。修复的策略仍覆盖「全屏 ∪ 最大化 ∪ 客户区盖满显示器」三种：插框是 `WM_NCCALCSIZE` 与 DPI/系统版本的函数（window_manager 的 `top += IsWindows11OrGreater() ? 0 : 1` 本身就分版本走），别的机器/缩放下最大化态一样可能把边框留在屏内；按「窗口是否铺到边」判定比按「哪个态」判定稳，且与 Windows 对最大化窗口的既有行为一致。多出来的两个条件在本机是无害 no-op（实测最大化态本来就没线），不是凭空加的特例分支。
  - 不选"把窗口再上移 1px"的几何方案：那会让客户区顶部 1px 落到屏幕外（左右下三边并无此损失），是用内容裁切换视觉，且要猜 DWM 边框在各 DPI 下的厚度；DWM 属性是系统正解，零几何副作用。
  - 复现/归因/验证程序留在 `C:\Users\wrds\.claude\jobs\d1db82fe\tmp\repro\`（`repro.cpp` 现状复现、`repro3.cpp` 四阶段阳性对照、`repro4.cpp` 角落归因、`verify.cpp` 真机 A/B/C）。
  - 过程记录：调查中曾用 `drive.exe` 向**用户正在运行的正式版**发过 F11（进/出全屏各一次，几何已原样还原、未碰数据）——探针后来改为按 exe 路径锁定进程，不再误触用户实例。
