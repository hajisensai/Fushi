## BUG-546 · 设置主题卡与下方配置项不等宽
- **报告**：2026-07-04（用户：）
- **真实性**：✅ 真 bug —
  - 根因 `hibiki/lib/src/media/audiobook/reader_quick_settings_sheet.dart:639`（旧 `_buildThemeSelectorSection`）：阅读器快捷设置「布局与显示」子页里，主题选择器卡是一个裸 `AdaptiveSettingsSection`，无任何横向内边距；而同一 Column 里下方的 layout schema 分组走 `MaterialSettingsRenderer.buildDetailContent`（`hibiki/lib/src/settings/material_settings_renderer.dart:120`），其正文额外套了 `fromLTRB(page+gap=24, gap, page=16, ...)` 的横向缩进。两块左右缩进来源不同 → 主题卡更宽、与配置行左右对不齐（仅 Material；Cupertino 的 `buildDetailContent` 本就无横向内边距，两块都齐，不受影响）。
- **[x] ① 已修复** — commit（见下）：抽出唯一真相源 `MaterialSettingsRenderer.detailHorizontalInsets(tokens)`（`material_settings_renderer.dart`，返回 `EdgeInsets.only(left: page+gap, right: page)`）；`buildDetailContent` 的横向缩进改为从该 helper 取（`horizontal.left/right`）；`_buildThemeSelectorSection` 在 Material 下用同一 helper `Padding` 包裹主题卡（Cupertino 保持无横向缩进，契约一致）。主题卡与配置行共享同一缩进来源，消除等宽特例。
- **[x] ② 已加自动化测试** — `hibiki/test/settings/reader_layout_theme_card_width_test.dart`：① 行为层 widget 测试断言用共享 insets 包裹的卡与用 `buildDetailContent` 同款横向表达式包裹的卡左/右/宽度像素级对齐；② 源码守卫锁 `buildDetailContent` 与主题选择器卡都从 `detailHorizontalInsets` 取横向缩进（任一退回硬编码 padding 即红）。
- **备注**：TODO-1135。
