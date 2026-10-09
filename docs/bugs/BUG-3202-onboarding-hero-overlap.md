## BUG-3202 · 新手引导步骤 hero 压到页头进度条上
- **报告**：2026-10-08（仓库所有者，macOS 调试版截图：首页 hero 图标色块压在分段进度条上）
- **真实性**：✅ 真 bug，不限 macOS（任何有顶部 inset 的平台都会少让一段）。`FushiPageScaffold` 默认把正文铺到浮动页头底下，并在**正文的** MediaQuery 顶部 padding 里报「桌面标题行 + 页头（含进度条）」的让位高度；向导 `onboarding_wizard_page.dart`（`_OnboardingWizardPageState.build` 的 body）里的 `MediaQuery.removePadding(context: context, removeBottom: true)` 用的是页面 State 的 context——脚手架**外层**、只有标题行 32px 的那份 MediaQuery——于是把脚手架报的 padding 整个换回外层的，`_OnboardingStepList` 的顶部内边距只剩 `card + 32`，hero 落到进度条上。真实像素复现（与用户截图一致）：`.claude/preview/onboarding/onboarding_welcome_before.png`。
- **[x] ① 已修复** — 正文骨架抽成 `OnboardingWizardBody`（挂在脚手架 body 里），removePadding 读正文自己的 MediaQuery；页面 build 只装配。
- **[x] ② 已加自动化测试** — `fushi/test/onboarding/onboarding_wizard_layout_test.dart`（外层模拟 32px 标题行 inset，断言 hero 顶边 ≥ 进度条底边）；像素预览 `fushi/test/onboarding/onboarding_pixel_preview_test.dart`。
- **备注**：同仓其它 `MediaQuery.removePadding(context: context)` 调用逐个看过，都是在正文自身 widget 内或有意 `removeTop`，未见同类问题。
