## BUG-3075 · M3E 悬浮顶栏的栏下沿遮罩盖住胶囊投影
- **报告**：2026-10-07（合集详情移动端顶栏底边横线，CC 交接任务 7）
- **真实性**：✅ 真 bug。书架入口 `reader_fushi_history_page.dart:2294` 打开的网格合集页 `media_collection_grid_detail_page.dart:607,683` 使用普通 Scaffold；共享 `fushi/lib/src/utils/components/glass/fushi_glass_bars.dart:657` 把栏下沿 scrim 画在 AppBar 之后，不透明顶边盖住栏外阴影。恢复基线代码：共享测试 2 条均失败；真实网格合集页测试 1 条也命中阴影像素断言失败，均退出 1。
- **[x] ① 已修复** — `_buildFloating` 的两种 scrim 均在 `bar` 之前绘制；不改遮罩几何、滚动显隐与指针行为。提交 `74c92d86d2`。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/floating_app_bar_scrim_shadow_test.dart` 覆盖两种布局的绘制顺序与栏外阴影；`fushi/test/pages/collection_topbar_shadow_test.dart` 真 push 网格合集页、滚动并确认 scrim 从 0 淡入到 1，再验证返回圆栏外阴影。
- **备注**：视频合集 `media_collection_detail_page.dart:2503` 使用 `extendBodyBehindAppBar: true`，原本无此层次缺陷；不能把它与书架 / 漫画 / 游戏共用的 `MediaCollectionGridDetailPage` 混淆。前次仅核对视频合集的判断已纠正。设备验证结果见任务报告，widget 像素证据不等于设备 E2E。
- **验证**：真实网格合集回归及相邻顶栏套件 26/26、退出 0；加入实页回归后的全量 analyze 无问题、退出 0。Android 35 x64 独立模拟器运行生产网格合集页与合成成员，Tab/PageDown 焦点驱动滚动，1 条业务用例通过、driver 退出 0（日志另计 tearDownAll，显示 +2）；滚动偏移 1154.33、scrim opacity=1。首屏与滚后截图 `.codex-test/collection-topbar-edge/grid-collection-native-{top,scrolled}.png` 已目检：药丸阴影完整，无整宽截断。首次设备构建因固定版本 PDFium 下载超时退出 1、执行 0 条，补齐同版本缓存后重跑成功；临时包名、探针和生成文件均已还原或移出。
- **相邻证据**：Windows 视频合集像素夹具 1/1、退出 0，390×844 DPR2 首屏与滚动后截图位于 `.codex-test/collection-topbar-edge/04_legacy_full_mobile_{top,scrolled}_actual.png`，仅为相邻 behind-bar 布局证据。Android 验证使用真实页面和渲染，但未覆盖应用主入口导航或用户实际媒体库。
