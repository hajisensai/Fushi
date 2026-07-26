## BUG-1104 · 查词浮窗两条 WebView2 创建路径的 DPI 处理不一致（且无 WM_DPICHANGED）

- **报告**：2026-07-26（从 `docs/bugs/BUG-1098-popup-headword-furigana-clipped.md` 备注里拆出来的跟进项——
  那条备注明写「这是**放大器**不是根因……本轮不动，另开跟进」。编号避开 1098~1103（`origin/develop`
  上已被并发 PR 占用），落 1104。）
- **真实性**：✅ 真的不一致，但**不是**词头假名被裁的根因（根因是 BUG-1098 的 em 预留缺失，已在 PR#424 修掉）。
  沿真实代码路径核实（修复前）：
  - composition 路径 `hibiki/windows/runner/global_lookup_window.cpp:1055-1069`：QI
    `ICoreWebView2Controller3` 后设了 `put_BoundsMode(USE_RAW_PIXELS)` +
    `put_ShouldDetectMonitorScaleChanges(FALSE)` + `put_RasterizationScale(dpi/96)`。
  - windowed 回退路径 `:1126-1183`：**三项一个都没设**，任由 WebView2 自己探测 monitor scale。
  - 全文**没有** `WM_DPICHANGED` 处理。
  于是同一个窗口走哪条创建路径，位图缩放的真值来源不同：一个是我们按 `GetDpiForWindow(hwnd_)` 钉的，
  一个是 WebView2 自己探测的。而窗口坐标、shell 卡矩形（`ApplyRoundedRegion` 的圆角直径）、
  `commitLayerShift` 的 CSS px 换算**全部**按 `GetDpiForWindow(hwnd_)` 算。单屏 100% 时两者恰好相等，
  多屏 / 非 100% 缩放时可以差一档——差出来的就是被放大的亚像素取整误差。
  更麻烦的是 composition 路径关掉了自动探测**却没人负责跟随 DPI 变化**：这个窗是开机预热、整个 app
  会话只 `SW_HIDE` 不销毁的长命窗口，「建窗那一刻所在的那块屏」可能是几小时前的事，拖到另一块
  缩放不同的显示器后光栅缩放会一直停在旧值。
- **[x] ① 已修复** — 消除「两个真值来源」，而不是给 windowed 路径打补丁：
  - 新增单一入口 `GlobalLookupWindow::ApplyDpiScale()`（`hibiki/windows/runner/global_lookup_window.h:268-272`、
    `global_lookup_window.cpp:1196-1229`）：读 `GetDpiForWindow(hwnd_)`，一次性设齐 `put_BoundsMode` /
    `put_ShouldDetectMonitorScaleChanges(FALSE)` / `put_RasterizationScale(dpi/96)`。
    拿不到 `ICoreWebView2Controller3` 的老 runtime 整体返回，保持它自己的默认行为——绝不半套地只设一项。
  - composition 路径 `:1055-1059` 的内联代码替换成 `ApplyDpiScale()`；windowed 回退路径 `:1152-1158`
    在 `put_Bounds` 之前补上同一句。两条路径行为从此按构造相同。
  - 新增 `case WM_DPICHANGED`（`:1851-1886`）：照单全收 `lparam` 里系统按新 DPI 算好的建议矩形
    （`SWP_NOZORDER | SWP_NOACTIVATE`，且不带任何「显示窗口」标志，预热期的隐藏窗不会凭空出现在桌面），
    再 `ApplyDpiScale()` + `put_Bounds` + composition 的 `Commit()` / windowed 的 `ApplyRoundedRegion()`
    （圆角直径按 DPI 算，换屏必须重算）。关掉自动探测之后跟随 DPI 变化就是我们自己的责任，这一句补上了。
  - **BUG-693 自愈重建未受影响**：`RecoverDeadWebView` 走 `EnsureWebView` → 创建路径 → `ApplyDpiScale()`，
    重建出来的实例自动拿到一致的 DPI 设置；PR#425 的 `put_IsStatusBarEnabled(FALSE)`（BUG-1097）原样保留。
  - **向后兼容**：单屏 100% 缩放下 `dpi/96 == 1.0`，windowed 路径新设的值与 WebView2 自己探测出来的
    完全一致，渲染逐像素不变；只有多屏 / 非 100% 缩放才会看到差别，而那正是本条要修的场景。
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_dpi_scale_guard_test.dart`（4 例全绿，源码守卫）：
  ① `ApplyDpiScale()` 存在且三项设置齐全、真值来自 `GetDpiForWindow(hwnd_)`、老 runtime 整体返回；
  ② `put_RasterizationScale` / `put_ShouldDetectMonitorScaleChanges` 在全文**各只出现一次**（谁再自己设
  DPI 就红），且 `ApplyDpiScale();` 恰好三处调用（composition 创建 / windowed 创建 / `WM_DPICHANGED`）；
  ③ `WM_DPICHANGED` 收下建议矩形、不动 Z 序、**不含**任何显示窗口标志、并重算圆角区域；
  ④ BUG-693 自愈与 BUG-1097 状态栏关闭不被顺手改掉，且自愈仍复用创建路径。
- **备注**：C++ 无法在 Dart 测试里执行，守卫锁的是**源码结构**而非渲染结果。
  已用 `flutter build windows --debug` 真编译验证（exit 0）。
  **仍未做 / 已知风险**：
  - **多屏 + 不同缩放的真机验证未做**（本机当前无法构造该场景）。`WM_DPICHANGED` 的实际观感——
    拖过去之后卡片是否立刻按新缩放重绘、有没有一帧旧缩放的闪烁——只能真机看。
  - `WM_DPICHANGED` 里没有重建 WebView2 控制器，只改了光栅缩放与 bounds。这是刻意的：
    重建涉及控制器生命周期 + BUG-693 自愈状态机，风险远高于收益；WebView2 的
    `put_RasterizationScale` 本就是为运行时改缩放设计的，不需要重建。
  - DComp 视觉树在 DPI 切换时是否需要额外的 `SetTransform` 未验证（当前只 `Commit()`）。若真机
    发现 composition 路径换屏后有整体缩放偏差，从这里查。
