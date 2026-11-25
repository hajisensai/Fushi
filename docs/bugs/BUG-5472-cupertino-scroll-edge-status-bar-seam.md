## BUG-5472 · cupertino-scroll-edge-status-bar-seam
- **报告**：2026-11-25（用户：Cupertino 音乐库页截图，深浅色「还是有这种分割线」，位置在状态栏下沿 / 顶栏上沿）
- **真实性**：✅ 真 bug，三处叠加：
  1. `fushi/lib/src/pages/implementations/home_page.dart` `_withAppleTopEdge`：Apple 下外壳在内容区顶（= 状态栏下沿）另贴一条 14px 不透明渐隐带，只有设置页豁免；库页 / 浏览 / 首页的 `FushiFloatingChromeOverlay` 自己已从窗口顶画整块 `FushiAppleScrollEdgeBackdrop`，两层叠出黑边。
  2. `fushi/lib/src/utils/components/fushi_floating_chrome.dart` `contentBleed` 只在桌面自绘标题行时生效：手机上底板铺进状态栏、内容层没铺进去，同一块模糊在状态栏段糊的是纯底色，上下两块观感不同。
  3. `fushi/lib/src/utils/components/fushi_masthead_scaffold.dart` `_buildAppleLargeTitle`：二级页正文与 scroll edge 只排在栏行下面，状态栏 + 栏行是无底的纯底色，接缝落在栏下沿。
- **[x] ① 已修复** — 挂浮动 chrome 的 tab 由 overlay 独占顶部 scroll edge（`homeTabOwnsTopScrollEdge`）；Apple 下内容层也铺到窗口顶；二级页大标题栏改为内容从窗口顶排、栏行叠在上面，底从窗口顶一整块铺到栏下沿。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/glass/apple_scroll_edge_status_bar_seam_test.dart`（深浅色库页 overlay 底与视口上沿 = 0、各 tab 归属、二级页底从 0 起盖住状态栏 + 栏行）。
- **备注**：外壳「谁画顶部 scroll edge」按 tab 列表判定，新增挂 overlay 的 tab 要同步 `homeTabOwnsTopScrollEdge`。
