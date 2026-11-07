## BUG-4227 · 滚动模式斜着滑（拇指弧线）正文不动、也不跨章
- **报告**：2026-11-06（用户反馈 R7k887yaJI，Android 3.3.0，Xiaomi 2407FRK8EC：「喜欢下滑读书，不灵敏；直线下滑可以，斜向上就不行；人手大拇指就是弧形斜向上滑」）
- **真实性**：✅ 真 bug，两层根因：
  1. **原生滚动被整段丢弃**：BUG-3482 给连续模式加的 `html, body { touch-action: pan-y | pan-x }`（develop `fushi/lib/src/reader/reader_content_styles.dart:1677`）只放行主轴。Chromium `components/input/touch_action_filter.cc` `ShouldSuppressScrolling`：GestureScrollBegin 的起手位移提示 |dx| > |dy| 且 touch-action 不含该轴时 `drop_scroll_events_ = true`，这一手势后续所有 scroll update 全丢。真 Chromium 实测（`tool/reader_pitch_headless/continuous_diagonal_pan_probe.mjs`，CDP 真触摸）：`pan-y` 下偏离主轴 50° 的上推 scrollTop = 0，`pan-x pan-y` 下 = 216；偏离 ≥ ~55° 时 Chromium 无论 touch-action 都按交叉轴锁存、正文不动（`auto` 也一样）。
  2. **边界跨章判轴 45° 一刀切**：触摸边界 IIFE `_bEnd`（develop `fushi/lib/src/reader/reader_pagination_scripts.dart:4676` / `:4679`）要求 `|主轴| >= |交叉轴|`，斜一点就既不滚也不跨章。
- **[x] ① 已修复** —
  - CSS：连续模式 touch-action 改 `pan-x pan-y`（两轴平移放行、只关缩放）。交叉轴仍由 `body { overflow-<交叉轴>: clip }` 顶住——BUG-3482 真 WebKit 实测「只加 body clip」手指就拖不动交叉轴，Chromium 本就尊重根元素 hidden；`reader_cross_axis_lock_itest.dart` 的程序化 / 越界块断言不变。
  - 连续 shell 触摸控制器重写（一文档只装一次、只在连续 shell 下动作）：判轴改角度阈值 65°（`ReaderPaginationScripts.continuousGestureDir`）；Chromium 原生不滚的偏交叉轴斜滑（原生自按下纹丝不动、过点击半径后观察 48 ms、起手 |交叉| > |主轴| 且在 65° 内）由 JS 按主轴分量接管滚动，松手按速度做指数衰减惯性（`continuousPanAssistShouldEngage` / `continuousPanAssistFlingVelocity`）；原生一旦也动了立即让出，绝不叠双份。
  - 同一 PR 顺带把「拉过章首 / 章末切章」做成三档阻尼设置（`ContinuousChapterTurnResistance`，标准档逐字保持 TODO-656 行为）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/reader/continuous_scroll_gesture_tuning_test.dart`：判轴 / 补位 / 惯性 / 跨章纯函数，设置落盘 → config / live patch，设置项只在滚动模式可见，shell 常量单一出处、旧 45° 判据已删、页面两处 config 构造都下发阻尼档。
  - `fushi/test/reader/reader_continuous_cross_axis_lock_test.dart`：滚动模式 touch-action 必须是 `pan-x pan-y`，不得回退单轴。
  - `fushi/test/reader/scroll_cross_chapter_try_scroll_test.dart`：TODO-656 语义改用 `continuousBoundaryCrossDir`。
  - 真 Chromium：`tool/reader_pitch_headless/continuous_touch_controller_probe.mjs`（完整引擎产物 + CDP 真触摸，横排 / 竖排 × 标准 / 低 / 高阻尼，20 条断言全过：60° 斜滑补位滚 ~220px、30° 斜滑原生滚不叠加、近横划不动、标准档同手势滚到底不跨章、低阻尼同手势继续推即跨、高阻尼 60px 不跨 / 140px 跨）。
- **备注**：没有在真机（Android WebView / iOS WKWebView）上复测，验证停在桌面 Chromium 真触摸这一层。iOS 上 WebKit 对偏交叉轴手势是否锁存未实测；补位只在「原生确实没动」时接管，原生在滚就让出，所以不会在 WebKit 上叠成双份。
