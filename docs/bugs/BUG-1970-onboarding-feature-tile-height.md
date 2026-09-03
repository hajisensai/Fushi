## BUG-1970 · 新手引导功能选中态高度变化
- **报告**：2026-08-30（用户：截图反馈）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_material_components.dart:207-219` 的共享 `FushiListItem` 会在选中态切换标题/副标题字重；部分中文字体不同字重的垂直度量不同，使 `OnboardingFeatureTile` 的内容高度随勾选状态变化。
- **[x] ① 已修复** — `e047718403`：`OnboardingFeatureTile` 只覆盖标题和副标题的字重，继续继承选中态前景色；底色、描边和勾选图标仍提供选中反馈。
- **[x] ② 已加自动化测试** — `fushi/test/onboarding/onboarding_wizard_widgets_test.dart:52` 同时断言选中/未选中的文字字重和整行高度相同；按用户要求直接提 PR，本轮未等待重新执行该新增用例。
- **备注**：修复限定在新手引导，不改变共享列表在其它页面的选中态强调。
