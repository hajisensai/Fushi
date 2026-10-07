## BUG-3069 · M3E 悬浮顶栏的栏下沿遮罩盖住胶囊投影
- **报告**：2026-10-07（合集详情移动端顶栏底边横线，CC 交接任务 7）
- **真实性**：✅ 共享组件真 bug。`fushi/lib/src/utils/components/glass/fushi_glass_bars.dart:657` 的普通 Scaffold 分支把栏下沿 scrim 画在 AppBar 之后；scrim 的不透明顶边盖住栏外阴影。恢复基线代码运行新增测试，执行 2 条、失败 2 条、退出码 1，分别命中层次和像素断言。
- **[x] ① 已修复** — `_buildFloating` 的两种 scrim 均在 `bar` 之前绘制；不改遮罩几何、滚动显隐与指针行为。提交 `74c92d86d2`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/floating_app_bar_scrim_shadow_test.dart`，两种 `extendBodyBehindAppBar` 布局分别验证绘制顺序、滚动后返回圆在栏外的真实像素阴影。
- **备注**：当前 `media_collection_detail_page.dart:2503` 已使用 `extendBodyBehindAppBar: true`，其 scrim 原本就在栏下，不能把普通 Scaffold 的复现直接视为当前合集页原始报告的复现。保留这项共享层修复并补测该分支；生产合集页 widget 截图与验证结果见任务报告。设备原始页面肉眼复测待补，widget 像素证据不等于设备 E2E；未扩大声称原始设备问题已修好。
- **验证**：新回归及相邻顶栏套件 25/25、退出 0；全量 analyze 无问题、退出 0。Windows 生产合集页像素夹具 1/1、退出 0，390×844 DPR2 首屏与滚动后截图位于 `.codex-test/collection-topbar-edge/04_legacy_full_mobile_{top,scrolled}_actual.png`，药丸下缘没有整宽切线；夹具部分字体/图标使用占位符，截图仅证明布局。临时夹具不入库。
