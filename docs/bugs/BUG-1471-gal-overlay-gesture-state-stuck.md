## BUG-1471 · galgame 浮窗跑久了失去点击响应：手势事务只认 WM_LBUTTONUP 一个终止条件
- **报告**：2026-08-09（用户：遠坂りん×2、只能逃跑了、哈吉千歳 —— 4 人独立复现，本批最高频）
  - 原话：持续 >10 分钟 / 过几句台词后浮窗就点不动，**台词内容仍在跟着更新**，
    即 UI 还活着但命中测试死了。
- **真实性**：✅ 真 bug（结构性缺陷，与 [[BUG-1286]] 是两条独立成因，症状同形）。
  - `fushi/windows/runner/floating_lyric_window.cpp` 的
    `pressed_` / `dragging_` / `press_was_text_` 是**一笔手势事务**，但清零点散在四处、
    各清一半：`SetLocked`、`SetPassThrough`、`WM_LBUTTONUP`、`DispatchControlAction("lock")`，
    而 `Hide()`（修复前 `:355`）**只清 `dragging_`、漏清 `pressed_`**，也不 `ReleaseCapture`。
  - 更根本的一条：全 `fushi/windows/runner/` **零 `WM_CAPTURECHANGED` 处理**
    （`grep` 结果为空）。这个 body 是 `WS_EX_NOACTIVATE` 的后台线程窗
    （建窗 flags 见 `floating_lyric_window.cpp:317`），MSDN 明写后台线程持有 capture 时
    **前台窗口一变 capture 即被系统释放** —— 而"游戏抢回前台 / 游戏弹对话框 / alt-tab"
    在 galgame 场景里是每局必然发生的事。capture 一没，这次 press 的 `WM_LBUTTONUP`
    再也不会到达，`pressed_` 永久卡 true。
  - 后果精确匹配"UI 活着、命中测试死了"：`MaybeHoverLookup`（`:1789` 修复前）
    在 `pressed_ || dragging_` 时直接 return ⇒ 悬停查词 / Shift-悬停查词从此永久静默；
    而台词更新走 platform channel，与手势状态无关，照常刷新。
  - 同款缺陷在 `hook_toolbar_window.cpp`（`SetCapture` 后只靠 LBUTTONUP 收尾）。
  - 另一处配对失衡：`global_lookup_window.cpp` 的 `ForgetDeadWindow()`（HWND 被外部
    销毁时走的路径）清掉了 hwnd/controller/webview 等一切，却**不解钩** —— 而
    `low_level_mouse_hook.cpp` 有 1 秒存活性重装定时器，于是那条指向死 HWND 的
    纯放行钩子会被**永久续命**，`foreground_hook_` 则彻底泄漏。
- **[x] ① 已修复** — 按**状态所有权**收敛，而不是再补一处清零：
  - `FloatingLyricWindow::CancelPointerGesture()` / `HookToolbarWindow::CancelPointerGesture()`
    成为手势事务的唯一终止函数（清三个标志 + 条件 `ReleaseCapture`），
    `Hide()` / `SetLocked` / `SetPassThrough` / `WM_LBUTTONUP` / `DispatchControlAction("lock")`
    全部改走它；设计上幂等（我们自己 `ReleaseCapture` 触发的 `WM_CAPTURECHANGED` 会再进一次）。
  - 两个窗口各补 `case WM_CAPTURECHANGED:` —— 这是修掉"capture 被系统收走"这条真实
    终止路径的关键，也是本 bug 与只改 `Hide()` 的区别。
  - `GlobalLookupWindow::ReleaseDismissHooks()` 抽出解钩三件套，
    `Hide()` / `ForgetDeadWindow()` / 析构三处共用，arm/disarm 在崩溃路径上重新配平。
- **[x] ② 已加自动化测试** — 源码扫描守卫
  `fushi/test/tools/gal_overlay_gesture_capture_guard_test.dart`：钉死
  「每个 `SetCapture(` 所在文件必须有 `WM_CAPTURECHANGED` 分支」「手势标志只有
  `CancelPointerGesture` 一个清零点」「`Hide()` 函数体内必须调用它」
  「`ForgetDeadWindow()` 必须调 `ReleaseDismissHooks()`」。已做变异实测。
  - 真行为（跨进程 capture 被抢）在 CI 无法真跑；`flutter build windows --debug` 已通过。
- **备注**：⚠️ **本条不能替代对 [[BUG-1286]] 的版本核对**。BUG-1286（`WH_MOUSE_LL` 被系统
  吊销）的用户原话与本条逐字同形，其修复 `db4a2f08b` 已在 develop，但那条 bug 自己
  记着**未做 Windows 真机构建验证**。若这 4 位用户跑的包早于 `db4a2f08b`，他们遇到的
  可能是 BUG-1286 的未上线态。两条都是真缺陷，各修各的，别互相顶替。
  - BUG-1286 存活性判据还有一处结构盲区（推测，未验证）：判据只证明「回调还在链上」
    （`g_callback_tick`），不证明**点击**事件真的到达我们。链上更靠前的钩子（同进程注入的
    Magpie 超分）若吞 click 而放行 move，判据恒真、永不重装，症状同形且不可自愈。
