## BUG-5524 · home-apple-collapsed-title-covered
- **报告**：2026-11-26（用户：iPhone 录屏，Cupertino 首页滚动后「首页」小标题被右上按钮盖住，「应该要以某种形式收起」）
- **真实性**：✅ 真 bug。Apple 窄窗页头收起态（`fushi/lib/src/utils/components/fushi_floating_chrome.dart:2681` `_layoutApple`）小标题居中，只给动作组限宽到右半行，主按钮位（头像 + 「Default」配置胶囊约 170pt）不让位，动作组还保底一颗「⋯」，整排越过中线压住小标题。
- **[x] ① 已修复** — 新增通用 `FushiMastheadCollapseAway`（同一判据：Apple + 窄窗 + 收缩进度 ≥ 0.5）：收起时折叠让位（Offstage 保状态 + FushiAnimatedSize 动画），滚回顶部再展开；首页配置胶囊挂上它，收起态只剩「⋯」+ 头像。
- **[x] ② 已加自动化测试** — `apple_scroll_edge_status_bar_seam_test.dart`「首页形态」：静止 120 宽、收起后 0 宽且主按钮位在中线右侧、滚回顶部恢复。
- **备注**：收起态下切配置要先滚回顶部。未在 iOS 真机 / 模拟器复测。
