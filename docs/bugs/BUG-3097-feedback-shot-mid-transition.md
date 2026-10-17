## BUG-3097 · 反馈自动截图截到页面转场中途的半透明叠画
- **报告**：2026-10-09（用户：处理台反馈 m53uFSTe5O 的自动截图是反馈中心半透明叠在视频页上的画面）
- **真实性**：✅ 真 bug。截图确实在 push 反馈中心**之前**截（`fushi/lib/src/pages/implementations/feedback/feedback_common.dart` 旧 `openFeedbackCenter`：`await captureFeedbackScreenshot()` 后才 `Navigator.push`），但「之前」只保证不截到本次打开的进场动画，没保证截的那一帧已经静止，也没有防重入：
  - 悬浮球（`fushi/lib/src/floating_ball/app_floating_ball_host.dart` `_openFeedback`）浮在导航之上，任何时候都点得到。第一次点击截图 + 反馈中心淡入期间再点一次，第二次截到的就是「反馈中心半透明叠在视频页上」，并且又压了第二个反馈中心——用户随后在上面那个里提交，带的正是这张叠画。截图里反馈中心列表已有用户上一条反馈、底下是视频页，与此路径吻合。
  - 从反馈中心按返回，它淡出时已对下层放开点击（Flutter 退场中的路由 `IgnorePointer` 只挡自己），这时点首页按钮 / 悬浮球的反馈入口，同样截到转场帧。
  - 截图本身（`feedback_diagnostics.dart` `captureFeedbackScreenshot` → `RenderRepaintBoundary.toImage`）同步建场景、不晚于调用时刻，不是「异步晚了」。
- **[x] ① 已修复** — 新增 `fushi/lib/src/feedback/feedback_entry_gate.dart`：`RouteTransitionTracker`（挂在 `main.dart` 根导航的 navigatorObservers，记下栈上与退场中的路由）+ `FeedbackEntryGate`（入口单飞：反馈中心从打开到弹出期间忽略重复点击；截图前等所有进出场动画的状态事件走完、再等这一帧画完）。`openFeedbackCenter` 两个入口（首页按钮、悬浮球）都经它。等的是动画状态事件，不是定时延迟。
- **[x] ② 已加自动化测试** — `fushi/test/feedback/feedback_entry_gate_test.dart`：退场动画中途打开 → 动画走完前不截、截时退场页已摘掉；淡入中途重复点击 → 只截一张、只压一个，弹出后再开照常；静止时 push 前就截；源码守卫钉住两个入口都经入口闸、根导航挂着跟踪器。
- **备注**：只观察根导航；嵌套 Navigator 里的转场不在跟踪范围（目前反馈入口所在页面都在根导航上）。
