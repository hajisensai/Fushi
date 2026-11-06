## BUG-3564 · 复习模板预览：没有样例时的占位值 `(字段名)` 未转义，字段名里的 HTML 会在卡面 WebView 里生效
- **报告**：2026-10-19（PR #2366 审查遗留，协调要求修复）
- **真实性**：✅ 真 bug（沿代码路径确认）。修前模板编辑器 `fushi/lib/src/pages/implementations/srs/srs_template_editor_page.dart` 的 `_sampleFields` 与字段说明页 `fushi/lib/src/pages/implementations/srs/srs_field_info_page.dart` 的 `srsFieldSpotlightValues` 都把 `'(${f.name})'`（字段说明页还有 `'(${srsFieldDisplayName(f)})'`）原样当字段**内容**交给 `renderAnkiCard`，结果进卡面 WebView。字段名来自用户或导入的 Anki 牌组，形如 `<img src=x onerror=…>` 的名字会被当成标签渲染并执行。
- **[x] ① 已修复** — 统一 helper `srsFieldPlaceholderHtml`（`srs_template_editor_page.dart`）先 `HtmlEscape(HtmlEscapeMode.element)` 再加括号，两页三处占位全部改走它。内置字段目录的示例值（`srsKnownField(...).example`）是代码里写死的可信 HTML，保持原样。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_template_preview_placeholder_test.dart`：helper 输出、模板编辑器预览经真实 `renderAnkiCard` 后不含 `<img`、字段说明页高亮预览（别的字段 / 本字段无样例两种）都已转义。变异实测：helper 改回不转义，3 条全红；还原后绿。
- **备注**：卡面本身按 Anki 兼容会执行模板与字段内容里的脚本（`srs_card_face.dart`），这是既定信任模型；本修复只堵住「字段名被当成内容注入」这条本不该有的通道。
