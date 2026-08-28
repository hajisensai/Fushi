## BUG-1916 · 窗口缩放时露出深青底色层
- **报告**：2026-08-28（用户：「fushi缩放有层底色修复一下。并且让缩放变流畅」）
- **真实性**：✅ 真 bug。根因 `fushi/windows/runner/win32_window.cpp:150`（TODO-959 / `fa81438573` 给 `WNDCLASS.hbrBackground` 挂了深青 `#1F4959` 画刷）+ `win32_window.cpp:211`（主窗 `CreateWindowEx` 无 `WS_CLIPCHILDREN`）。机制（2026-08-28 Debug 隔离实例 + 像素探针实测）：Flutter 子窗是 DWM 里独立的合成层，盖在主窗自己的重定向表面之上；每次缩放（`CS_HREDRAW|CS_VREDRAW` 整客户区失效）系统都用类画刷把整块表面——含子窗底下——擦成深青，平时被子窗盖住看不见，但**最大化/还原/全屏/DPI 切换**这类过渡里 DWM 动画的是表面而非子窗层：修复前第一次最大化第 43ms 那一帧整窗 **100%** 深青（2,721,488 px），就是用户看到的「底色层」。交互式拖边缩放时抓不到深青（引擎同步缩放先 present 再返回 `WM_SIZE`）；hello-world stock runner 同样零深青，因其无画刷。
- **[x] ① 已修复** — `16bbb3dc11`（PR #1036）：画刷从窗口类收归 `Win32Window` 实例（`backdrop_brush_`，初值仍是 splash 深青，TODO-959 冷启动首帧前不黑的保证不变：实测启动 0~1.3s 客户区深青 97.9%→加载页 55.8%→0）；主窗加 `WS_CLIPCHILDREN`（`WM_PAINT` 擦背景不再碰子窗底下）；新增 `FillSurfaceBackdrop()` 用不裁子窗的 `GetDCEx(DCX_CACHE)` 把表面整块刷成当前色，在 `SetBackdropColor` 换色时和每次 `WM_SIZE`（`MoveWindow(child)` 阻塞前）调用；`WM_ERASEBKGND` 用实例画刷并 `return 1`；Dart 每次主题变化推 `setCaptionColors(caption: cs.surface)` → `FlutterWindow::ApplyCaptionColors → SetBackdropColor`。修复后最大化/还原各两轮 **0%** 深青（两次独立运行）；只换画刷不重刷表面时残留 2.4%（表面底下留着启动期的深青），故 `FillSurfaceBackdrop` 是必要的。交互缩放节奏（放大 ~46ms/步、缩小 ~31ms/步）与 hello-world 完全一致，是 Flutter Windows 引擎同步缩放的固有成本，不在本修复范围。
- **[x] ② 已加自动化测试** — `16bbb3dc11`：`fushi/test/build/win_resize_backdrop_guard_test.dart`（源码扫描守卫 7 条：Dart 侧 `main.dart` 必须以 `caption: cs.surface` 推色 / 类无画刷 / `WS_CLIPCHILDREN` / `WM_SIZE` 先 `FillSurfaceBackdrop` 再 `MoveWindow`（剥注释后判序）/ `FillSurfaceBackdrop` 必须 `GetDCEx(DCX_CACHE)` 不裁子窗 / `WM_ERASEBKGND` 用实例画刷并 `return 1` / 画刷初值 splash 色、换色即重刷、`ApplyCaptionColors` 驱动；9 条变异全部被抓红（含把 Dart 侧改成 `cs.primary`））。
- **合入时的集成事故（2026-08-28 批量合并）**：本修复合进 `develop` 后**一度彻底失效**，
  由它自己那条 Dart 侧守卫当场拓红。两条 PR 语义撞车：PR #1032 的 `3c4a5960f8`
  「refactor(windows): make the app-frame latch honest and drop the dead fallback」
  把 `main.dart` 里那句 `WindowCaptionChannel.setCaptionColors(...)` 删了——**就 caption
  而言它的推理完全正确**：Windows 已改用自绘 app frame（`TitleBarStyle.hidden`），
  原生 caption 不存在了，给它上色是不可达分支。但本条修复把同一个通道**复用成了
  窗口表面背景刷的驱动**（`ApplyCaptionColors → SetBackdropColor`），而表面是活的。
  两者分开看都对，合起来的结果是：画刷永远停在启动期深青，最大化照样闪——
  原症状原样回来，而原生侧 6 条守卫全部依旧绿。
  - **修复**（本次合并 commit）：在 `main.dart` 的 builder 里**无条件**重新推色，并把理由
    写死在注释里——这不是复活 `3c4a5960f8` 删掉的那条「主题化原生标题栏兜底」死分支
    （那条确实该删，不得回滚），而是一个**同体异目**的新用途：`DwmSetWindowAttribute`
    那半在隐藏 caption 下是无害 no-op，通道又对相同值去重，成本可忽。
  - **教训**：名字欺骗了两侧。通道叫 `setCaptionColors`，于是删它的人只审了 caption
    语义。真正将它拦下的不是代码审查也不是定向测试（两条 PR 各自都绿），而是
    #1036 特意写的那条「原生链再对，Dart 不喂就白搭」跨层守卫。**复用一个名字已经
    不准确的通道时，跨层守卫是唯一能拓出并发撞车的东西。** 后续清理候选：把通道
    改名成同时表达 caption + surface 两个职责的名字（需 Dart 与 runner 同 PR 两侧同改）。
- **备注**：取证方法：`FUSHI_TEST_HIDDEN=1 FUSHI_TEST_ONSCREEN=1 FUSHI_TEST_ROOT=<tmp>` 起隔离实例，`PostMessage(WM_SYSCOMMAND, SC_MAXIMIZE/SC_RESTORE)` 后 700ms 内每 ~8ms BitBlt 窗口区域数 `#1F4959±4` 像素。**探针陷阱**：`GetWindowRect` 含 Win11 不可见缩放边框（~11 物理 px），缩放中途帧的右/底「透明边带」是边框不是内容空洞，别据此推「DWM 先按新尺寸合成」。
