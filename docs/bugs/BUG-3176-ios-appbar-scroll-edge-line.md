## BUG-3176 · iOS详情页下拉时顶栏下沿露出一条线
- **报告**：2026-10-09（用户 iOS 截图：作品资料页往下拉时顶栏下方露出一条横线）
- **真实性**：✅ 真 bug。Apple 设计系统的 `FushiAppBar`（`fushi/lib/src/utils/components/glass/fushi_glass_bars.dart` 的 `_AppleBarScrollEdge`）只在**栏下沿**画一条 20px「上实下透」的 scroll edge 带。作品详情页 `Scaffold(extendBodyBehindAppBar: true)` 把 hero 铺到透明顶栏下面；内容一滚到栏下，带的不透明上沿（页面底色）就紧贴着上方透明栏区里透出来的 hero 背景，两种颜色之间是一条硬线。
- **[x] ① 已修复**（`03bc68c7e7`）— `FushiAppleScrollEdge` 新增 `bandExtent`：盒子比渐隐带高时，靠边部分画与渐隐带最靠边处同色同不透明度的实色底（无接缝）。顶栏把 scroll edge 画在 AppBar **之下**、从栏顶铺到栏下沿再延伸 20px 渐隐带；正文排在栏下的普通页面观感不变（栏区本来就是页面底色）。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/ui_hit_area_consistency_test.dart`「Apple 顶栏 scroll edge」（实色区几何 + 不透明）与源码守卫「Apple 顶栏把 scroll edge 铺满整段栏区」。
- **备注**：iOS 真机未复测（本机无 iOS 真机会话）；PR 附组件级前后像素对比。
