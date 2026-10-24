## BUG-3770 · subtitle-delay-float-bar-blank-panel
- **报告**：2026-10-24（用户：视频页「收起面板调轴（看得到字幕）」后，顶部调轴浮条下面拖出一整块空白浅色大板，盖住大半个画面，附截图）
- **真实性**：✅ 真 bug，两层叠加：
  1. `fushi/lib/src/utils/app_ui_scale.dart:110-133`：`FushiAppUiScale` 在缩放 ≠ 1 时取 `constraints.biggest` 当 view、按 `view/s` 建画布，再用 `FittedBox(BoxFit.fill)` 放大回去。**宽松约束**下 `RenderFittedBox` 把自己缩成子树尺寸（= canvas），变换比例退化成 1——画布反算了却没放大回去，层既不缩放、又被撑成 `view/s` 大小。截图里大板宽 ≈ 2000/1.4、高 ≈ 1125/1.4 即此。既有调用点（侧栏 `StackFit.expand`、主导航、弹窗词典 builder）都是紧约束，没暴露。
  2. `fushi/lib/src/pages/implementations/video_fushi/layout.part.dart` 的 `_buildSubtitleDelayBar`：缩放层包在 `Align` **里面**，正好给它宽松约束；且画布用紧约束传给子树，`ConstrainedBox(maxWidth: 720)` 被覆盖，不透明浮条表面铺满整张画布。
- **[x] ① 已修复** — ① `FushiAppUiScale` 外包 `SizedBox.fromSize(view)`，宽松约束下也恒占满 view、真缩放（紧约束调用点不变）；② 抽出 `VideoTopFloatBarLayer`（`fushi/lib/src/media/video/video_top_float_bar_layer.dart`），缩放层放在 `SafeArea`/`Align` 外面，浮条表面按内容收缩，页面改用该层。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/app_ui_scale_test.dart`「宽松约束下照样按 scale 缩放、层占满 view」；`fushi/test/media/video/video_subtitle_delay_float_bar_test.dart`「浮条层 scale=…」：scale 1.0 / 1.4 / 0.8 下在 1600×900 画面里断言浮条表面高度 < 画面 1/4、宽度 ≤ 720×scale、贴顶、水平居中（修 ① 之前 scale=1.4 实测红：中心落在 571 = 800/1.4）。
- **备注**：
