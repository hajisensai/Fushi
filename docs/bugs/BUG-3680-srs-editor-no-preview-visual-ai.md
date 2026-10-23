## BUG-3680 · 编辑卡片缺预览与可视化编辑，字段名无翻译说明，编辑与模板无 AI
- **报告**：2026-10-23（来源：用户群反馈，报告人哈吉千歳）
- **现象**：编辑卡片没有预览、没有可视化编辑；字段名无翻译说明；编辑与模板编辑都没有 AI。
- **真实性**：✅ 真 bug。根因：功能缺失；新增 `srs_note_preview.dart`、`srs_field_label.dart`、`srs_html_text_parts.dart`、`srs_rich_format.dart`、`srs_field_ai_sheet.dart`、`ai_srs_field_assistant.dart`。
- **[x] ① 已修复** — `db0a9e6dd8`（分支 claude/fushi-srs-improvements-f158f4，PR hajisensai/Fushi#2464）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_note_editing_markup_test.dart、fushi/test/srs/srs_note_editor_preview_test.dart`
- **备注**：无。
