import 'anki_video_template.dart';
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
/// 脚本模板把字段声明为 `data-field` 数据源时，静态副本也不能证明最终渲染能力：
/// Kiku 发行版的 SSR 会先原样插入 Picture，hydration 后却只保留其中的 `<img>`。
/// 因此该字段交给脚本消费时按标准图片路径处理，不按模板名称或版本猜测能力。
bool noteTypeRendersSynchronizedClip({
  required AnkiNoteTypeDefinition definition,
  required Map<String, String> fieldMappings,
}) {
  final AnkiVideoTemplateOptions? videoOptions = readAnkiVideoTemplateOptions(
    definition,
  );
  if (fieldMappings.values.any(
    (String value) => value.contains('{card-video}'),
  )) {
    final String? audioField = AnkiHandlebarOptions.singleSentenceAudioField(
      fieldMappings,
    );
    return videoOptions != null &&
        audioField != null &&
        audioField != videoOptions.field &&
        definition.fields.contains(audioField) &&
        fieldMappings[videoOptions.field] == '{card-video}';
  }
  final List<String> imageFields = AnkiHandlebarOptions.cardImageFieldNames(
    fieldMappings,
  );
  if (imageFields.isEmpty) return false;
  final List<String> sides = <String>[
    for (final AnkiCardTemplate t in definition.templates) ...<String>[
      t.front,
      t.back,
    ],
  ];
  final List<String> visibleSides = sides.map(_visibleTemplateMarkup).toList();
  return imageFields.any(
    (String field) =>
        !sides.any((String side) => _hasScriptedFieldSource(side, field)) &&
        visibleSides.any(
          (String side) => _bareFieldReference(field).hasMatch(side),
        ),
  );
}

/// `data-field="字段"` 包装的裸字段是脚本输入，不是最终媒体容器。兼容旧版
/// 隐藏 div 和新版 template；只认真实标签及其字段内容，忽略注释/脚本文字。
bool _hasScriptedFieldSource(String html, String field) {
  final String withoutComments = html.replaceAll(_htmlComment, '');
  if (!_scriptTag.hasMatch(withoutComments)) return false;
  final String markup = withoutComments.replaceAll(_inertBlock, '');
  final RegExp reference = _bareFieldReference(field);
  return _fieldSourceElement.allMatches(markup).any((RegExpMatch element) {
    final RegExpMatch? attribute = _dataFieldAttribute.firstMatch(
      element.group(2)!,
    );
    final String? declaredField =
        attribute?.group(1) ?? attribute?.group(2) ?? attribute?.group(3);
    return declaredField == field && reference.hasMatch(element.group(3)!);
  });
}

final RegExp _htmlComment = RegExp(r'<!--.*?-->', dotAll: true);
final RegExp _scriptTag = RegExp(r'<script\b', caseSensitive: false);
final RegExp _fieldSourceElement = RegExp(
  r'<([a-z][a-z0-9-]*)(\s[^>]*\bdata-field\s*=[^>]*)>'
  r'(\s*\{\{[^{}]+\}\}\s*)</\1\s*>',
  caseSensitive: false,
);
final RegExp _dataFieldAttribute = RegExp(
  r'''\sdata-field\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''',
  caseSensitive: false,
);

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
