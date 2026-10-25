## BUG-3773 · 小说阅读器里点应用内悬浮球会唤出顶栏 / 底栏
- **报告**：2026-10-25（用户：看小说的时候点击悬浮球会导致顶部底部栏浮起来；iOS 与 Windows 都有，估计全平台）
- **真实性**：✅ 真 bug。根因在 `fushi/lib/src/floating_ball/app_floating_ball_host.dart` 宿主 build 里包球的 `MouseRegion(opaque: false, hitTestBehavior: HitTestBehavior.deferToChild)`（BUG-3663 引入，用来写 `appFloatingBallPointerInside`）。`RenderMouseRegion.hitTest` 返回 `super.hitTest(...) && opaque`：`opaque: false` 时即便球被点中，宿主也向 `main.dart` 的根 Stack 报「没命中」，根 Stack 于是继续命中下面的页面。阅读器正文 WebView 因此收到同一下按下 / 抬起：Windows fork 的 `Listener` 把它转给 WebView2，iOS 上 `UiKitView` 被命中、手势放行给 WKWebView。JS 判为点空白 → `onTapEmpty` → `_handleFloatingChromeReveal`，栏被唤出（球本身也照常展开）。不是平台限制，与 BUG-2276 的 macOS 透明遮罩不是一回事。
- **[x] ① 已根因修复** — 去掉 `opaque: false`（保持默认 true）。`deferToChild` 保证空白处不命中，球 / 按钮以外的区域照样穿透到页面，悬停进出（`appFloatingBallPointerInside`）不受影响；球上方的下层 MouseRegion 不再收到悬停，这正是球盖着它们的语义。
- **[x] ② 已加自动化测试** — `fushi/test/floating_ball/app_floating_ball_host_test.dart`「BUG-3773：点球展开 / 收起，按下不落到底下页面」：底下页面用 `Listener` 计数（与 Windows fork 的 WebView 指针转发同形，不进手势竞技场），点球展开、再点收起都应为 0 次，对照点空白为 1 次。恢复 `opaque: false` 时该用例红（Actual 1），修复后绿。
- **备注**：只在 widget 层验证了 Flutter 命中链路，未在 iOS / Windows 真机上复测阅读器原始路径。
