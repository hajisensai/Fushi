## BUG-556 · iOS 视频顶部功能栏偶发位置不准
- **报告**：2026-07-05（用户：）
- **真实性**：✅ 真 bug。根因：`hibiki/lib/src/pages/implementations/video_hibiki_page.dart:4107` 的 `_videoTopBarMargin()` 只把 `MediaQuery.padding` 交给 `videoTopBarMargin`；iOS 横竖屏切换 / 系统栏临时显隐时 `padding.top` 可能带着过渡态旧值，导致顶部功能栏偶发下沉或贴边不准。
- **[x] ① 根因修复** — `hibiki/lib/src/media/video/video_subtitle_style.dart:437` 改为同时接收 `padding`、`viewPadding` 与 `_systemBarsVisible`：顶部 inset 只在系统栏真实可见时使用 `viewPadding.top`，隐栏时归零；左右 cutout 仍逐边取安全区最大值。提交：本提交。
- **[x] ② 自动化测试** — `hibiki/test/pages/video_topbar_safe_inset_guard_test.dart` 守住 host 接线必须读取 `padding`/`viewPadding` 并传 `_systemBarsVisible`；`hibiki/test/media/video/video_subtitle_style_test.dart` 覆盖“隐栏但 padding.top 有过渡值时 top=0”和“系统栏可见时 top=viewPadding.top”。验证：`fvm flutter test --no-pub test/pages/video_topbar_safe_inset_guard_test.dart test/media/video/video_subtitle_style_test.dart`。
- **备注**：真机侧无法从 `devicectl` 直接注入任意触摸/系统栏拖拽路径，最终仍需在 iPhone 上切换唤出/隐藏系统栏与旋转场景复看顶部栏位置。
