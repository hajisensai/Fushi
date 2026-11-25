## BUG-4249 · 视频字幕列表 M3E 侧栏「全部 / 收藏」分段文字消失（横屏手机）
- **报告**：2026-11-09（应用内反馈 RMq4uXplRf，Android 3.3.0-debug.24478，OnePlus 横屏 792x363：字幕列表顶栏下方的分段控件两段只剩空胶囊）
- **真实性**：✅ 真 bug。widget 测试复现（MD3、792x363、240px 侧栏、zh-CN）：两段 `RenderParagraph.didExceedMaxLines == true`，标签被省略。
  根因 `fushi/lib/src/media/video/video_subtitle_jump_panel.dart:2654-2656`（修前，`_buildM3eHeader` 的分段行）：`Flexible(child: filter)` 与右侧收藏计数 `Expanded(...)` 同为 flex 1，`RenderFlex` 把剩余宽度对半分，分段最多只拿半行——「全部」档右侧是空的也让不出来。
  792 宽时侧栏 `autoWidth = 792 × 0.28` 被 clamp 到最小 240（`video_fushi/subtitle.part.dart:3755`），分段行可用 218，分段上限 (218 − 8) / 2 = 105，每段 ≈ 51.5，扣掉 24px 内边距只剩 ≈ 27.5，放不下 labelLarge 14px 的两个汉字（≈ 28），`maxLines: 1` + 省略号把标签吃成空胶囊。
  分诊里指向的 `:1949` 是 classic 布局（横向 `SingleChildScrollView` 内，宽度无界、不会截断），MD3 默认走的是 M3E 布局，不是那一处。
- **[x] ① 修复** — 分段行改为 `LayoutBuilder` + 非 flex 的 `ConstrainedBox`：分段按自身内容取宽，上限 = 整行 − 缝 − 导出按钮固定宽（收藏档有导出时），右侧计数 `Expanded` 只拿剩下的；真放不下时仍由分段自己按 `fushiSegmentWidths` 收窄、不右溢。导出按钮边长与缝提成常量 `_kFilterRowExportExtent` / `_kFilterRowGap`，与预留量同源。
- **[x] ② 自动化测试** — `fushi/test/media/video/video_subtitle_list_filter_labels_test.dart`：240px M3E 侧栏、两档（全部 / 收藏 + 导出按钮）断言两个标签都未被省略且画在段内、无布局异常；修前 2 例均红。
- **备注**：真机（792x363 横屏）肉眼复测未做。
