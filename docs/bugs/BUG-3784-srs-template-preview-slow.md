## BUG-3784 · srs-template-preview-slow
- **报告**：2026-10-26（用户：笔记类型 › 字段 / 卡片模板编辑「这个预览怎么加载这么慢」）
- **真实性**：✅ 真 bug，多处叠加：
  1. 模板编辑页 / 笔记编辑预览在「模板出错 / 正面为空 / 正常」三种状态间换不同子组件（`srs_template_editor_page.dart` `_buildPreview`、`srs_note_preview.dart` `_face`），打字经过半截模板（`{{Expr`）时 WebView 被销毁、改好再冷建（Windows 冷建约 1 s，见 BUG-3579）。
  2. 笔记编辑预览按「模板 + 正反面」换 `KeyedSubtree` key（`srs_note_preview.dart` 原 318 行），每翻一次面都冷建一个新 WebView，绕过了 `SrsWebCardFace` 原地换内容的设计。
  3. 字段说明页取样本时 `noteIdsOfType(type.id)` 没带 `limit`（`srs_field_info_page.dart` 原 128 行），把整个类型的笔记 id 全读回来；且示例卡在 `build()` 里渲染，说明框每敲一个字就把整份 Lapis / Fushi 卡模板重新解析渲染一遍。
  4. 模板编辑页对没改过的内置 Fushi 卡片也整面 WebView 渲染，与复习页（原生混合渲染）不是同一张卡面。
- **[x] ① 已修复** — 新增 `SrsStablePreviewFace`（`srs_note_preview.dart`）：卡面视图常驻，出错 / 为空只盖提示层；去掉翻面换 key；字段说明页 `limit: 1` 且示例卡载入时算一次；模板编辑页对与代码一致的 Fushi 卡片走 `srsNotePreviewNativeFushiCard`。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_note_types_pages_test.dart`（计数卡面 builder：模板改出语法错误再改回，卡面 State 不重建）。
- **备注**：进页面时「先读库再建 WebView」的串行仍在（约 1 s 的冷建本身没有消掉）；要再快需要跨页面预热卡面 WebView，须先在 Windows 离屏 runner 实测冷建占比再做，未在本次范围。未在真机上量化前后耗时。
