## BUG-2637 · 游戏串流触屏无效且必须游戏在前台
- **报告**：2026-09-23（用户：「现在不能触屏操作而且一定要游戏在前台，看看能不能仅做成对窗口串流」）
- **真实性**：✅ 真 bug（代码路径验真，未在真机复现用户原始会话）。
  1. `fushi/windows/runner/game_stream_input.cpp` 的 `Send` 对除「抬起」外的所有键 / 指针事件都要求目标窗口是前台（`ValidateTarget(require_foreground=true)`），游戏一被别的窗口盖住或主机用户切走，触屏的 down/move 全部回 `window_not_foreground`。而输入走的是 `PostMessageW` 定向投递到绑定的 HWND，根本不会误投到别的窗口——这道门只拦住了正当使用。
  2. 开播时 `FushiGameStreamHost.start` 无条件 `GameStreamInputChannel.activate()`，激活被系统拒绝就整场开播失败——串流被迫依赖前台，而 WGC 采集本身支持被遮挡的窗口。
  3. 拒绝原因在主机侧丢失：runner 用 `Error("input_rejected", reason)`，Dart 只取 `error.code`，手机永远只看到固定文案「请切到前台」，SGRE 的 `unsupported_native_pointer`（该引擎本就不接受坐标触控）等真实原因看不见。
  4. 指针按下前不先发 `WM_MOUSEMOVE`（依赖悬停的按钮不响应）；按住标记在 `PostMessage` 成功前就置位。
- **[x] ① 已修复** — 输入新增 `inputFocus`：默认 `background`（仅对窗口串流：消息投递路径不再要求前台，身份 / 存活 / 最小化 / 隐藏校验保留），`foreground` 模式在按下前按需激活；开播只在 foreground 模式尝试激活且失败不致命；右键 / 中键 / 滚轮、按下前先 move、按住状态投递成功后才记；`gameStreamInputRejectionReason` 把 runner 的具体原因带回手机并本地化。SGRE 原生确认键路径保持原前台要求（其 DirectInput 适配本就只在前台采样），不属本次范围。提交 `ad4c4bd04cb`。
- **[x] ② 已加自动化测试** — `fushi/windows/runner/tests/game_stream_input_release_test.cpp`（clang 本机 119/119：后台模式非前台照样投递、隐藏 / 换进程仍拒、foreground 模式激活与失败原因、右键 / 中键 MK 标志、滚轮符号与屏幕坐标、先 move 后 down、投递失败不记按住）；`fushi/test/sync/game_stream_touch_test.dart`（直接 / 触控板两种触控手势）；`fushi/test/sync/game_stream_android_features_test.dart`（拒绝原因透传）。
- **备注**：后台窗口能否真正消费消息取决于引擎：靠 `GetAsyncKeyState` / DirectInput 轮询的引擎（如 SGRE）在后台仍会无视消息，这类游戏需在串流设置里切到「输入时切到前台」。真机未验。
