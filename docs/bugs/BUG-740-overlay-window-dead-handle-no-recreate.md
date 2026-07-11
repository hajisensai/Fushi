## BUG-740 · 覆盖窗HWND被外部销毁后悬垂hwnd_不重建·第二个弹窗出不来
- **报告**：2026-07-11（用户：手动关闭第一个弹窗/面板后，第二个弹窗出不来；有时"说出来了但不知道去哪里了"；不重启 app 不恢复）
- **真实性**：✅ 真 bug（根因 `hibiki/windows/runner/global_lookup_window.cpp:267`（旧 `ShowAt` 幂等守卫）+ `:626`（旧 `IsShowing`）+ `:200`（`hwnd_` 仅在析构置 null））
- **[x] ① 已修复** — `windows/runner/global_lookup_window.cpp` 新增 `OwnsLiveWindow()`/`ForgetDeadWindow()`；`ShowAt`/`PrewarmWebView`/`IsShowing` 改用之（commit 待填）
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_dead_window_recreate_guard_test.dart`（源码扫描守卫，6 用例，`flutter test` 绿）
- **备注**：

### 根因（数据结构缺陷）

app 外全局查词/剪贴板面板覆盖窗（`GlobalLookupWindow`，剪贴板面板与瞬态查词窗是同一 C++ 类的两个实例）的成员 `hwnd_` **只在析构函数才置 `nullptr`**（`:200-220`，运行期唯一的 `DestroyWindow` 也只在析构里）。当 HWND 被**外部**拆掉——WebView2 运行时后台更新/崩溃、owner 主窗 teardown 联动销毁 owned 瞬态窗、或任何外部 `DestroyWindow`——`hwnd_` 就变成**悬垂的非 null 句柄**，同时毒死两条本该自愈的路径：

1. `ShowAt` 的 `if (hwnd_ == nullptr)`（旧 `:267`）为假 → 走 else 分支对**死句柄** `SetWindowPos`（静默失败）→ **永不 `CreateWindowExW` 重建**。
2. `IsShowing()`（旧 `:626`）的 `hwnd_ != nullptr` 被悬垂/被回收句柄骗过（Windows 会把 HWND 数值回收给别的可见窗，`IsWindowVisible` 返 true）→ Dart 侧 `ClipboardPanelController.update()` / `GlobalLookupController` 的 `isShowing` 复检被绕过 → **跳过重建**、往不存在的窗口渲染，并记 `panel: updated` / `reveal(box)` **成功**。

于是 Dart 确信弹窗还在、日志一切正常，**用户屏幕上什么都没有，且不重启 app 永远回不来**。

### 实证（真机 glog + Win32 窗口探测）

- 20:54–21:08：`EnumWindows` 枚举 1788 个顶层窗，`HibikiGlobalLookupWindow` 类**零个**；同期 Dart 持续 `panel: updated "N chars"` / 热键路径 `showAt→overlaySize→reveal(box)` 全"成功"。
- 21:13:18 `start: called`（用户重启 app）→ 21:17 `panel: shown` 窗口全新重建、恢复正常。
- `Hide()`（`:588`）确认是 `SW_HIDE` 不销毁——排除"只是被隐藏"（隐藏窗 `EnumWindows` 仍枚举得到）。

### 修复（Linus 式消除"悬垂句柄"特殊情况：`hwnd_` 非空 ⟺ 存在属于我们的活窗）

- `OwnsLiveWindow()`：`hwnd_ != nullptr && IsWindow(hwnd_) && GetWindowLongPtr(hwnd_, GWLP_USERDATA) == this`——死句柄 `IsWindow` 假；句柄被回收给别的窗时 USERDATA≠this，双重防漏。
- `ForgetDeadWindow()`：非我方活窗时清 `hwnd_` + 释放死 `controller_/webview_/env_` COM 代理（照 `RecoverDeadWebView` 范式）+ 复位 `webview_ready_/visible_/revealed_`；并 `error_cb_` 记一行"发现死窗→重建"到设备日志（让销毁者可诊断，即 Layer A 取证）。
- `ShowAt` / `PrewarmWebView` 在创建/幂等守卫**前**先 `ForgetDeadWindow()` → 悬垂句柄触发**真正重建**。
- `IsShowing()` 改用 `OwnsLiveWindow()`。

对"到底谁销毁的（Layer A）"不敏感——让系统**自愈**：下一次复制/热键即重建覆盖窗，不再需要重启。若 `error_cb_` 日志证明是我们自己间接触发的销毁，再追加堵源头。

### 待验证

- Windows Release 真机：制造外部销毁（如 `taskkill` WebView2 msedgewebview2 进程树 / WebView2 运行时更新）后，下一次热键/复制应自动重建覆盖窗并弹出（设备日志出现"overlay window found destroyed — rebuilding"一行且随后 `reveal(box)` 有真窗）。
- 相邻回归：正常 open→close→reopen、面板拖动/×/Ctrl+Alt+D、瞬态窗连点，均不受影响（`ForgetDeadWindow` 仅在句柄非活时动作，活窗路径逐字节不变）。
