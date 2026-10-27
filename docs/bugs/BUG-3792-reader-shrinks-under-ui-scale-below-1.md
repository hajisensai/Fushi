## BUG-3792 · reader-shrinks-under-ui-scale-below-1
- **报告**：2026-10-26（用户：群里安卓用户截图「歌词模式用不了」，补充「点进去歌词模式和有声书都这样」；所有者平板 Xiaomi Pad 5 / Android 17 上自装的 Fushi 同样复现）
- **真实性**：✅ 真 bug。现象：阅读器（含有声书正文与歌词模式覆盖层）整页按「界面大小」比例 s 缩在左上角（平板 90% → 0.9、用户 80% → 0.8），右 / 下外圈露出路由层形状背景。真机 `dumpsys activity top`：`FlutterView` 2560×1600，而 Flutter 下发的 WebView 容器 `FlutterMutatorView` 只有 2304×1439，即 Flutter 侧整页按 0.9 倍布局。根因：
  - `fushi/lib/src/utils/components/shelf_cover_material.dart:840` `LibraryShapeBackdrop` 是不带 `fit` 的 `Stack`，经路由层 `FushiPageBackdrop`（`fushi/lib/src/utils/adaptive/fushi_page_backdrop.dart:29`，10-25 「背景整个应用都加」）垫在每一页外面后，页面从路由拿到的紧约束被放松成宽松约束。
  - 阅读器入口 `fushi/lib/src/media/sources/reader_fushi_source.dart:508` 外包 `FushiAppUiScaleNeutralizer`（`fushi/lib/src/utils/app_ui_scale.dart:186`），它的 `FittedBox` 外没有钉尺寸：宽松约束下 `RenderFittedBox` 缩成子树尺寸（真实视口 = 画布 × s），变换比例退化为 1，于是整页只画 canvas×s 大小、贴左上角（与 BUG-3773 修 `FushiAppUiScale` 的同一类坑）。s ≥ 1 时子树被 clamp 回画布，不显现，所以默认缩放的设备上看不到。
- **[x] ① 已修复** — `LibraryShapeBackdrop` 的 `Stack` 改 `StackFit.passthrough`，路由约束原样传给页面；`FushiAppUiScaleNeutralizer` 外层加 `SizedBox.fromSize(size: canvas)` 把自己钉成画布，不再依赖祖先给紧约束。
- **[x] ② 已加自动化测试** — `fushi/test/utils/app_ui_scale_neutralizer_test.dart`：宽松约束下中和层仍铺满窗口（0.8 / 0.9 / 1.25）+ 真实路由链（界面缩放 → `FushiPageBackdrop` → 中和层）约束保持紧、页面铺满。修复前 0.8 / 0.9 与路由链三条红（宽 900 / 1000、`isTight` false），修复后 7/7 绿。
- **备注**：真机验证：Xiaomi Pad 5（Android 17 / HyperOS 4）测试包 `app.fushi.reader.lyrtest`、界面缩放 90%，阅读器与歌词模式均铺满（修复前同机自装 3.0.1-debug.21417 复现 0.9 倍缩小）。同样包了中和层的页面（漫画阅读、网页浏览 / 网页漫画、查词页、Mihon 登录 / 验证页）走同一修复点，单测覆盖、未逐页真机验。修复发布前用户可把「界面大小」调回 100% 临时绕过。
