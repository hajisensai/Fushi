## BUG-5492 · 横屏手机：外壳按宽取档给了桌面页头 / 展开侧栏，快捷键页工具区挤没列表
- **报告**：2026-11-26（用户：Android 手机横屏，快捷键设置页切到手柄后几乎只剩工具区；要求其它页一并查空隙）
- **真实性**：✅ 真 bug。Android 模拟器横屏（914×411 dp）逐页截图复现：
  - 快捷键页：搜索 + 设备切换 + 手柄按钮样式 + 域筛选固定在顶部，加上页头，列表只剩约 60 dp。根因 `fushi/lib/src/pages/implementations/shortcut_settings/shortcut_browser.part.dart:781`（工具区恒固定，不看视口高度）。
  - 所有模块页 / 设置子页：横屏手机宽 914 落进 expanded 档，页头大字取桌面档（84 号），页头吃掉约三分之一高度。根因 `fushi/lib/src/utils/components/fushi_page_title_metrics.dart:132`（`isCompact` 只按宽）。
  - 主导航：同理按宽默认展开侧栏（占四分之一宽），竖向只摆得下四个目的地；顶部 64 号品牌图标再吃一截。根因 `fushi/lib/src/utils/adaptive/adaptive_navigation.dart:345`、`fushi/lib/src/utils/components/nav_rail_brand_button.dart:44`。
  - 玻璃设计：设置子页恒画 iOS 大标题行（导航行 + 大标题两行）。根因 `fushi/lib/src/settings/settings_kit_core.dart:1861`。
- **[x] ① 已修复** — 横屏矮窗口判据统一走 `isFushiCompactLandscapeWindow`（真实视口尺寸）：MD3 页头取手机档、Apple 保持单行内联标题；侧栏默认收起（用户手动展开仍生效），Apple 贴边侧栏改窄条；品牌图标收成 40；玻璃设置子页不出大标题行、标题常驻导航栏（同 iPhone 横屏）；快捷键页视口低于 560 时工具区并进结果滚动视图随列表滚走、分组标题照旧吸顶。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_compact_landscape_test.dart`（shell chrome on a landscape phone 组）、`fushi/test/shortcuts/shortcut_browser_test.dart`（short landscape viewport scrolls the toolbar with the list）。设备巡检脚本 `fushi/integration_test/landscape_phone_sweep_itest.dart`（MD3 + 玻璃各 18 帧）。
- **备注**：模拟器 Medium Phone API 37 横屏复测通过（修前 / 修后截图对照）。阅读器 / 视频播放器 / 有内容的库网格与详情页未在本轮巡检内（空库、无素材）。
