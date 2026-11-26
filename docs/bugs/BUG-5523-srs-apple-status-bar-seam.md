## BUG-5523 · srs-apple-status-bar-seam
- **报告**：2026-11-26（用户：iPhone 截图，Cupertino 复习页滚动后状态栏下沿一条白条，「每个模块顶部都要统一」）
- **真实性**：✅ 真 bug。复习页 Apple 版页头是 `FushiStaticMasthead`，`FushiPageScaffold` 把它挂进 `FushiFloatingChromeOverlay(masthead: true)`，与库页一样从窗口顶自画整块 scroll edge；但外壳 `homeTabOwnsTopScrollEdge`（`fushi/lib/src/pages/implementations/home_page.dart:5002`）把 `HomeTab.srs` 判成 false，`_withAppleTopEdge` 又在内容区顶部（= 状态栏下沿）叠一条不透明页面底色 soft 带，横在页头底板中间。
- **[x] ① 已修复** — `homeTabOwnsTopScrollEdge` 改成按 tab 穷举的 switch：重设计外壳下复习页与首页一样自带顶部 scroll edge；新增 tab 必须显式表态，不再靠白名单漏项。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/apple_scroll_edge_status_bar_seam_test.dart`：判据单测（srs redesign=true 为真）+ 复习页形态（ShellStageTopBleed + SafeArea + FushiPageScaffold(header: FushiStaticMasthead)）滚动后底与正文都从窗口顶起（深浅色）。
- **备注**：查词页页头排在 Column 里（iOS 不画页头），正文不铺进状态栏，仍由外壳画内容区顶部渐隐。未在 iOS 真机 / 模拟器复测。
