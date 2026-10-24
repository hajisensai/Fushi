## BUG-3770 · subtitle-delay-float-bar-blank-panel
- **报告**：2026-10-24（用户：视频页「收起面板调轴（看得到字幕）」后，顶部调轴浮条下面拖出一整块空白浅色大板，盖住大半个画面，附截图）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/pages/implementations/video_fushi/layout.part.dart` 的 `_buildSubtitleDelayBar`：`FushiAppUiScale` 包在 `Align` **里面**。视频页界面缩放 ≠ 1 时 `FushiAppUiScale`（`fushi/lib/src/utils/app_ui_scale.dart:110-133`）取 `constraints.biggest` 当画布、`SizedBox.fromSize(canvas)` 给子树**紧**约束；Align 下传的是整片画面的宽松约束，于是浮条表面被撑满（`ConstrainedBox(maxWidth: 720)` 也被紧约束覆盖），表现为顶部一行控件 + 下面的空白不透明大板。缩放 = 1 时 `FushiAppUiScale` 直接返回子树，不触发，所以只在缩放非 1 的设备上出现。
- **[x] ① 已修复** — 抽出 `VideoTopFloatBarLayer`（`fushi/lib/src/media/video/video_top_float_bar_layer.dart`），缩放层包在 `SafeArea`/`Align` 外面：画布 = 整片画面，Align 再给浮条宽松约束，表面按内容收缩。页面改用该层。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_subtitle_delay_float_bar_test.dart`「浮条层 scale=…」：scale 1.0 / 1.4 / 0.8 下在 1600×900 画面里断言浮条表面高度 < 画面 1/4、宽度 ≤ 720×scale、贴顶、水平居中。
- **备注**：
