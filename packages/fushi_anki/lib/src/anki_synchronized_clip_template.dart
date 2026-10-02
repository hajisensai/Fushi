import 'anki_models.dart';
import 'anki_note_type_definition.dart';

/// 目标笔记类型能否承载**音画同步片段**卡（`VideoMiningImageMode.videoClip`）。
///
/// 同步片段把画面放进卡片图片字段：WebM 是 `<video>`（`inlineVideoCoverHtml`），MP4
/// 是重播按钮（`synchronizedVideoReplayHtml`）；句子音频字段只剩重播按钮 + 隐藏
/// `<audio>` 或 `[sound:]` 片段，不再有单独的 `<img>` 封面。这套表示只在模板**原样
/// 渲染**图片字段的 HTML 时成立（Lapis：`<div class="image">{{Picture}}</div>`）。
///
/// 反例 Kiku：所有字段都写在 `<template data-field="Picture">{{Picture}}</template>`
/// 里，由卡片脚本二次解析，图片字段**只取 `<img>`**——`<video>` / 按钮整段丢弃，卡上既
/// 没有画面也没有能播的句子音频。这类模板必须改用标准媒体（`<img>` 动图 + `[sound:]`
/// 句子音频）。
///
/// 判据：映射里消费卡片图片的任一字段，在任一卡片模板（正面或背面）里以裸 `{{字段}}`
/// 出现在 `<template>` / `<script>` / HTML 注释之外。`{{text:字段}}` 等过滤器会剥掉
/// HTML，`{{#字段}}` / `{{/字段}}` / `{{^字段}}` 只是条件段，都不算渲染。
bool noteTypeRendersSynchronizedClip({
  required AnkiNoteTypeDefinition definition,
  required Map<String, String> fieldMappings,
}) {
  final List<String> imageFields = AnkiHandlebarOptions.cardImageFieldNames(
    fieldMappings,
  );
  if (imageFields.isEmpty) return false;
  final List<String> visibleSides = <String>[
    for (final AnkiCardTemplate t in definition.templates) ...<String>[
      _visibleTemplateMarkup(t.front),
      _visibleTemplateMarkup(t.back),
    ],
  ];
  return imageFields.any(
    (String field) => visibleSides.any(
      (String side) => _bareFieldReference(field).hasMatch(side),
    ),
  );
}

RegExp _bareFieldReference(String field) =>
    RegExp(r'\{\{\s*' + RegExp.escape(field.trim()) + r'\s*\}\}');

final RegExp _inertBlock = RegExp(
  r'<!--.*?-->|<script\b[^>]*>.*?</script\s*>',
  caseSensitive: false,
  dotAll: true,
);

// 标签名后必须是空白 / `/` / `>`：`\b` 会把 `<template-card>` 这类自定义元素也当成
// template。
final RegExp _templateTag = RegExp(
  r'<(/?)template(?=[\s/>])[^>]*>',
  caseSensitive: false,
);

/// 去掉浏览器不会直接渲染的部分：注释、`<script>`、`<template>`（可嵌套，Kiku 外层
/// `<template id="anki-fields">` 里再套每个字段一个 `<template>`）。带
/// `shadowrootmode` 的声明式 Shadow DOM 也一并剥掉：Anki 用 innerHTML 注入卡面，
/// innerHTML 不解析声明式 Shadow DOM，那里面同样是惰性内容。
String _visibleTemplateMarkup(String html) {
  final String withoutScripts = html.replaceAll(_inertBlock, '');
  final StringBuffer visible = StringBuffer();
  int depth = 0;
  int cursor = 0;
  for (final RegExpMatch tag in _templateTag.allMatches(withoutScripts)) {
    if (depth == 0) visible.write(withoutScripts.substring(cursor, tag.start));
    final bool closing = tag.group(1)!.isNotEmpty;
    depth = closing ? (depth > 0 ? depth - 1 : 0) : depth + 1;
    cursor = tag.end;
  }
  if (depth == 0) visible.write(withoutScripts.substring(cursor));
  return visible.toString();
}
